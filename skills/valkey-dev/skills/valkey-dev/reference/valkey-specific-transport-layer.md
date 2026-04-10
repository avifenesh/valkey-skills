# Transport Layer - Pluggable Connection Type Framework

Use when you need to understand how Valkey supports multiple transport
protocols (TCP, TLS, Unix, RDMA) through a single abstraction, or when
adding a new connection type.

Source: `src/connection.c`, `src/connection.h`, `src/socket.c`

## Contents

- What This Is (line 25)
- ConnectionType Vtable (line 38)
- Connection Base Struct (line 102)
- Registration (line 145)
- Dispatch Functions (line 168)
- Socket Implementation (Reference) (line 195)
- Listener Configuration (line 220)
- Pending Data (IO Threads Support) (line 240)
- How to Add a New Connection Type (line 257)
- Cached Type Lookups (line 266)

---

## What This Is

Valkey uses a pluggable connection type framework where each transport
protocol (socket, TLS, Unix domain socket, RDMA) registers as a
`ConnectionType` with a vtable of function pointers. All server code
interacts with connections through the abstract `connection` struct and
inline dispatch functions. This design was introduced as part of the
Valkey fork - Redis had a simpler, less extensible connection abstraction.

The key innovation is that RDMA (and potentially future transports) can be
added without modifying any calling code. The vtable pattern enables
transparent protocol substitution.

## ConnectionType Vtable

```c
typedef struct ConnectionType {
    // Identity
    int (*get_type)(void);

    // Lifecycle
    void (*init)(void);
    void (*cleanup)(void);
    int (*configure)(void *priv, int reconfigure);

    // Event loop & accept
    void (*ae_handler)(struct aeEventLoop *el, int fd, void *clientData, int mask);
    aeFileProc *accept_handler;
    int (*addr)(connection *conn, char *ip, size_t ip_len, int *port, int remote);
    int (*is_local)(connection *conn);
    int (*listen)(connListener *listener);
    void (*closeListener)(connListener *listener);

    // Connection creation
    connection *(*conn_create)(void);
    connection *(*conn_create_accepted)(int fd, void *priv);
    void (*shutdown)(struct connection *conn);
    void (*close)(struct connection *conn);

    // Connect & accept
    int (*connect)(struct connection *conn, const char *addr, int port,
                   const char *source_addr, int multipath,
                   ConnectionCallbackFunc connect_handler);
    int (*blocking_connect)(struct connection *conn, const char *addr,
                            int port, long long timeout);
    int (*accept)(struct connection *conn, ConnectionCallbackFunc accept_handler);

    // I/O
    int (*write)(struct connection *conn, const void *data, size_t data_len);
    int (*writev)(struct connection *conn, const struct iovec *iov, int iovcnt);
    int (*read)(struct connection *conn, void *buf, size_t buf_len);
    int (*set_write_handler)(struct connection *conn, ConnectionCallbackFunc handler,
                             int barrier);
    int (*set_read_handler)(struct connection *conn, ConnectionCallbackFunc handler);
    const char *(*get_last_error)(struct connection *conn);
    ssize_t (*sync_write)(struct connection *conn, char *ptr, ssize_t size,
                          long long timeout);
    ssize_t (*sync_read)(struct connection *conn, char *ptr, ssize_t size,
                         long long timeout);
    ssize_t (*sync_readline)(struct connection *conn, char *ptr, ssize_t size,
                             long long timeout);

    // Pending data (for IO threads / TLS)
    int (*has_pending_data)(void);
    int (*process_pending_data)(void);
    void (*postpone_update_state)(struct connection *conn, int);
    void (*update_state)(struct connection *conn);

    // TLS-specific
    sds (*get_peer_cert)(struct connection *conn);
    struct user *(*get_peer_user)(connection *conn, sds *cert_username);

    // Integrity
    int (*connIntegrityChecked)(void);
} ConnectionType;
```

## Connection Base Struct

```c
struct connection {
    ConnectionType *type;
    ConnectionState state;
    int last_errno;
    int fd;
    short int flags;
    short int refs;
    unsigned short int iovcnt;
    void *private_data;
    ConnectionCallbackFunc conn_handler;
    ConnectionCallbackFunc write_handler;
    ConnectionCallbackFunc read_handler;
};
```

Connection states:

```c
typedef enum {
    CONN_STATE_NONE = 0,
    CONN_STATE_CONNECTING,
    CONN_STATE_ACCEPTING,
    CONN_STATE_CONNECTED,
    CONN_STATE_CLOSED,
    CONN_STATE_ERROR
} ConnectionState;
```

Connection type IDs:

```c
typedef enum {
    CONN_TYPE_SOCKET,
    CONN_TYPE_UNIX,
    CONN_TYPE_TLS,
    CONN_TYPE_RDMA,
    CONN_TYPE_MAX,
} ConnectionTypeId;
```

## Registration

```c
static ConnectionType *connTypes[CONN_TYPE_MAX];

int connTypeRegister(ConnectionType *ct);
```

Registration happens at startup in `connTypeInitialize()`:

```c
int connTypeInitialize(void) {
    RedisRegisterConnectionTypeSocket();  // Always required
    RedisRegisterConnectionTypeUnix();    // Always required
    RedisRegisterConnectionTypeTLS();     // May fail without BUILD_TLS
    RegisterConnectionTypeRdma();         // May fail without BUILD_RDMA
    return C_OK;
}
```

Socket and Unix are mandatory. TLS and RDMA are optional and fail silently
if not compiled in.

## Dispatch Functions

All I/O goes through inline dispatch functions in `connection.h`:

```c
static inline int connWrite(connection *conn, const void *data, size_t data_len) {
    return conn->type->write(conn, data, data_len);
}

static inline int connRead(connection *conn, void *buf, size_t buf_len) {
    return conn->type->read(conn, buf, buf_len);
}

static inline int connAccept(connection *conn, ConnectionCallbackFunc accept_handler) {
    return conn->type->accept(conn, accept_handler);
}

static inline int connConnect(connection *conn, const char *addr, int port,
                              const char *src_addr, int multipath,
                              ConnectionCallbackFunc connect_handler) {
    return conn->type->connect(conn, addr, port, src_addr, multipath, connect_handler);
}
```

All server code uses `connRead`/`connWrite` regardless of whether the
underlying transport is TCP, TLS, or RDMA.

## Socket Implementation (Reference)

The socket type in `src/socket.c` provides the baseline implementation:

```c
static ConnectionType CT_Socket = {
    .get_type       = connSocketGetType,
    .ae_handler     = connSocketEventHandler,
    .accept_handler = connSocketAcceptHandler,
    .conn_create    = connCreateSocket,
    .write          = connSocketWrite,
    .writev         = connSocketWritev,
    .read           = connSocketRead,
    // ...
};
```

Key design points in the socket event handler:

- Read handler fires before write handler by default.
- `CONN_FLAG_WRITE_BARRIER` inverts this order (write before read) - used
  for fsync-before-reply patterns.
- Connection handler fires on first writable event after connect, then is
  cleared.

## Listener Configuration

```c
struct connListener {
    int fd[CONFIG_BINDADDR_MAX];  // Up to 16 listening fds
    int count;
    char **bindaddr;
    int bindaddr_count;
    int port;
    ConnectionType *ct;
    void *priv;                   // Connection-type-specific data
};
```

The server maintains an array of listeners:

```c
connListener listeners[CONN_TYPE_MAX];
```

## Pending Data (IO Threads Support)

The `has_pending_data` and `process_pending_data` callbacks enable
connection types to buffer data that needs processing outside the normal
event loop cycle. This is used by TLS (buffered SSL reads) and RDMA
(completion queue processing).

```c
int connTypeHasPendingData(void);      // Walk all types
int connTypeProcessPendingData(void);  // Process all pending
```

The `postpone_update_state` / `update_state` pair coordinates with IO
threads. When IO threads handle a connection, they must not modify event
loop registrations directly. Instead, state changes are postponed and
applied by the main thread via `update_state`.

## How to Add a New Connection Type

1. Define a `ConnectionType` struct with all required vtable entries.
2. Create a `conn_create` function that allocates your connection struct
   (which must embed `connection` as its first field).
3. Implement the I/O functions (`read`, `write`, etc.).
4. Register via `connTypeRegister` in `connTypeInitialize`.
5. The rest of the server code will work transparently.

## Cached Type Lookups

Frequently-used connection types are cached to avoid repeated lookups:

```c
ConnectionType *connectionTypeTcp(void);   // Cached CONN_TYPE_SOCKET
ConnectionType *connectionTypeTls(void);   // Cached CONN_TYPE_TLS (may be NULL)
ConnectionType *connectionTypeUnix(void);  // Cached CONN_TYPE_UNIX
```

These use static variables initialized on first call.
