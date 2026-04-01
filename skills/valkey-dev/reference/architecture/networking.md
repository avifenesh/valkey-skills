# Networking Layer

Use when you need to understand client connections, read/write buffers, or the reply delivery mechanism.

## Contents

- Client Connection Lifecycle (line 18)
- The client Struct (`server.h:1332`) (line 43)
- Reading: readQueryFromClient (`networking.c:4202`) (line 103)
- Writing: The Two-Level Reply Buffer (line 134)
- Connection Acceptance (`networking.c:1792`) (line 195)
- Client Cleanup: freeClient (`networking.c:2048`) (line 221)
- I/O Threading (line 233)
- See Also (line 243)

---

## Client Connection Lifecycle

```
TCP SYN arrives
  |
  v
Listener accept callback (registered by initListeners)
  +-- acceptCommonHandler()          # networking.c:1792
       +-- Check maxclients limit
       +-- createClient(conn)        # Allocate client struct, register read handler
       +-- connAccept()              # Complete TLS handshake if needed
  |
  v
Client is active: reads trigger readQueryFromClient()
  |
  v
Client disconnects or error
  +-- freeClient()                   # networking.c:2048
       +-- Wait for pending I/O threads
       +-- Module disconnect hooks
       +-- Cleanup query buffer, reply buffer, blocking state
       +-- Remove from all tracking structures
       +-- Close connection
```

## The client Struct (`server.h:1332`)

Each connected client is represented by a `client` struct. Key fields grouped by function:

### Identity and Connection

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `uint64_t` | Unique incrementing client ID |
| `conn` | `connection *` | Connection abstraction (TCP, TLS, Unix, RDMA) - see [transport-layer.md](../valkey-specific/transport-layer.md) |
| `ctime` | `time_t` | Creation time |
| `last_interaction` | `time_t` | Last activity time (for timeout) |
| `db` | `serverDb *` | Currently SELECTed database |
| `user` | `user *` | ACL user associated with connection |
| `resp` | `uint8_t` | RESP protocol version (2 or 3) |
| `name` | `robj *` | Client name set by CLIENT SETNAME |

### Input Buffer and Parsing

| Field | Type | Purpose |
|-------|------|---------|
| `querybuf` | `sds` | Input buffer for incoming data |
| `qb_pos` | `size_t` | Current read position in querybuf |
| `reqtype` | `int` | `PROTO_REQ_INLINE` (1) or `PROTO_REQ_MULTIBULK` (2) |
| `argc` | `int` | Number of arguments in current command |
| `argv` | `robj **` | Argument array for current command |
| `multibulklen` | `int` | Remaining bulk strings to read |
| `bulklen` | `long` | Length of current bulk argument |
| `cmd_queue` | `cmdQueue` | Pre-parsed pipelined commands |

### Command State

| Field | Type | Purpose |
|-------|------|---------|
| `cmd` | `struct serverCommand *` | Current command being executed |
| `lastcmd` | `struct serverCommand *` | Previous command executed |
| `realcmd` | `struct serverCommand *` | Original command (before rewrite) |
| `flag` | `struct ClientFlags` | Bitfield: `multi`, `blocked`, `replica`, `primary`, etc. |
| `duration` | `long` | Current command duration in microseconds |

### Output Buffer

| Field | Type | Purpose |
|-------|------|---------|
| `buf` | `char *` | Static output buffer (default 16 KB) |
| `bufpos` | `size_t` | Bytes used in static buffer |
| `buf_usable_size` | `size_t` | Usable size of static buffer |
| `reply` | `list *` | Dynamic reply list (overflow from static buffer) |
| `reply_bytes` | `unsigned long long` | Total bytes in reply list |

### I/O Threading

| Field | Type | Purpose |
|-------|------|---------|
| `io_read_state` | `volatile uint8_t` | `CLIENT_IDLE`, `CLIENT_PENDING_IO`, `CLIENT_COMPLETED_IO` |
| `io_write_state` | `volatile uint8_t` | Same states for write |
| `cur_tid` | `uint8_t` | I/O thread currently handling this client |
| `nread` | `int` | Bytes from last read |
| `nwritten` | `int` | Bytes from last write |

## Reading: readQueryFromClient (`networking.c:4202`)

This is the file event callback registered on every client's fd:

```c
void readQueryFromClient(connection *conn) {
    client *c = connGetPrivateData(conn);
    if (postponeClientRead(c)) return;  /* Offload to I/O thread */

    do {
        bool full_read = readToQueryBuf(c);       /* Read into querybuf */
        if (handleReadResult(c) == C_OK) {
            if (processInputBuffer(c) == C_ERR) return;
            trimCommandQueue(c);
        }
        /* Replicas: keep reading if buffer was full */
        repeat = (c->flag.primary && full_read && ...);
    } while (repeat);
}
```

**readToQueryBuf** (`networking.c:4119`): Allocates or grows the query buffer, reads via `connRead()`. Default read size is `PROTO_IOBUF_LEN` (16 KB). For large bulk arguments (>32 KB), reads exactly the remaining bytes to avoid unnecessary copying.

[NOTE] Clients share a thread-local query buffer (`thread_shared_qb`) for small reads to reduce allocation overhead. The buffer is "detached" from the shared pool before command processing to avoid interference.

### Query Buffer Limits

- Default max: `client-query-buffer-limit` config (default 1 GB)
- Unauthenticated clients: capped at 1 MB
- Exceeding the limit disconnects the client

## Writing: The Two-Level Reply Buffer

Valkey uses a two-level buffer strategy for replies:

### Level 1: Static Buffer

Every client has a pre-allocated `char *buf` of `PROTO_REPLY_CHUNK_BYTES` (16 KB). Small replies go here first via `_addReplyToBuffer()`. This avoids allocation for most commands.

### Level 2: Reply List

When the static buffer is full, additional reply data goes into `client->reply`, a linked list of `clientReplyBlock` nodes. Each node defaults to 16 KB. The list grows as needed.

```
addReply(c, obj)
  +-- prepareClientToWrite(c)
  |     +-- If no pending replies, add client to clients_pending_write
  +-- _addReplyToBufferOrList(c, data, len)
       +-- Try _addReplyToBuffer() into c->buf
       +-- If overflow, _addReplyProtoToList() into c->reply
```

### prepareClientToWrite (`networking.c:438`)

Gatekeeper for all reply writes. Returns `C_ERR` (skip writing) for:
- Lua/module fake clients
- Clients marked `close_asap`
- Clients with `reply_off` or `reply_skip`
- Primary clients (unless `primary_force_reply`)

If the client has no pending output yet, it's added to `server.clients_pending_write`.

### Flushing: handleClientsWithPendingWrites

Called from `beforeSleep()`. For each client in `clients_pending_write`:

1. Try direct `writeToClient()` from the main thread
2. If not fully written, install a write handler (`sendReplyToClient`) as a file event
3. Or offload to an I/O thread for threaded writes

### writeToClient (`networking.c:2951`)

```c
int writeToClient(client *c) {
    if (c->io_write_state != CLIENT_IDLE || c->io_read_state != CLIENT_IDLE)
        return C_OK;
    /* Dispatch to _writeToClient() or writeToReplica() */
    return postWriteToClient(c);
}
```

Writes from the static buffer first, then from the reply list. After writing, `postWriteToClient()` handles:
- Removing the write handler if all data sent
- Checking output buffer limits
- Closing the client if `close_after_reply` is set

### Output Buffer Limits

Clients have configurable output buffer limits per client type (normal, replica, pubsub). Two thresholds:
- **Hard limit**: Immediate disconnect
- **Soft limit + time**: Disconnect if over the soft limit for a sustained period

## Connection Acceptance (`networking.c:1792`)

```c
void acceptCommonHandler(connection *conn, struct ClientFlags flags, char *ip) {
    /* Check maxclients */
    if (listLength(server.clients) + getClusterConnectionsCount() >= server.maxclients) {
        connWrite(conn, "-ERR max number of clients reached\r\n", ...);
        connClose(conn);
        return;
    }
    /* Create client, initiate TLS handshake */
    client *c = createClient(conn);
    connAccept(conn, clientAcceptHandler);
}
```

### createClient (`networking.c:279`)

Allocates and initializes a `client` struct:
- Allocates 16 KB static reply buffer
- Sets `resp = 2` (RESP2 default)
- Selects DB 0
- Assigns unique incrementing `client_id`
- Registers `readQueryFromClient` as the read handler
- Links client into `server.clients` list and `server.clients_index` radix tree

## Client Cleanup: freeClient (`networking.c:2048`)

Handles all disconnect scenarios:
- Waits for any in-flight I/O thread operations
- Fires module disconnect events
- For primary clients: caches state for partial resync (`replicationCachePrimary`)
- Frees query buffer, reply list, blocking state, pub/sub subscriptions
- Removes from all tracking structures (client list, timeout table, pending write list)
- Closes the underlying connection

[NOTE] Protected clients and those in I/O thread processing use `freeClientAsync()` instead, which adds them to `server.clients_to_close` for cleanup in `beforeSleep()`.

## I/O Threading

When `io-threads > 1`, the main thread can offload read and write operations to a pool of I/O threads:

- **Read offloading**: `postponeClientRead()` moves the client to `clients_pending_io_read` instead of reading immediately
- **Write offloading**: `trySendWriteToIOThreads()` dispatches the write to an I/O thread
- **Poll offloading**: `trySendPollJobToIOThreads()` can offload the `epoll_wait` itself

The main thread processes results via `processIOThreadsReadDone()` and `processIOThreadsWriteDone()` in `beforeSleep()`. Thread count is dynamically adjusted by `adjustIOThreadsByEventLoad()` in `afterSleep()`.
