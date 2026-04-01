# RDMA Transport Protocol Support

Use when you need to understand how Valkey implements RDMA (Remote Direct
Memory Access) as an alternative transport to TCP, or when working on
connection-layer code.

Source: `src/rdma.c` (1,932 lines)

## Contents

- What This Is (line 24)
- Protocol Design (line 40)
- Key Structs (line 58)
- Memory Management (line 106)
- Configuration (line 140)
- Connection Lifecycle (line 154)
- Event Handling (line 166)
- Pending Write List (line 190)
- ConnectionType Registration (line 197)
- See Also (line 221)

---

## What This Is

Valkey supports RDMA as a first-class connection type alongside TCP, TLS, and
Unix sockets. RDMA enables zero-copy, kernel-bypass networking with
significantly lower latency than TCP. This is a Valkey-specific feature not
present in Redis.

The implementation is Linux-only, gated behind compile-time flags:

```c
#if defined __linux__ && defined USE_RDMA
```

RDMA can be built statically (`USE_RDMA=1`) or as a loadable module
(`USE_RDMA=2`).

## Protocol Design

The RDMA transport uses a custom command protocol over InfiniBand verbs:

```c
typedef enum ValkeyRdmaOpcode {
    GetServerFeature    = 0,  // Client requests server capabilities
    SetClientFeature    = 1,  // Client reports its capabilities
    Keepalive           = 2,  // Heartbeat (RDMA has no transport-level keepalive)
    RegisterXferMemory  = 3,  // Register a transfer buffer for RDMA writes
} ValkeyRdmaOpcode;
```

The protocol negotiates features, then exchanges memory regions for
one-sided RDMA writes. Data transfer uses `IBV_WR_RDMA_WRITE_WITH_IMM` -
the sender writes directly into the receiver's pre-registered buffer and
signals completion via an immediate value carrying the byte count.

## Key Structs

```c
typedef struct rdma_connection {
    connection c;                    // Base connection (embeds ConnectionType)
    struct rdma_cm_id *cm_id;        // RDMA CM connection identifier
    int flags;
    int last_errno;
    listNode *pending_list_node;     // Position in pending write list
} rdma_connection;

typedef struct RdmaXfer {
    struct ibv_mr *mr;     // Memory region registration
    char *addr;            // Local buffer address
    uint32_t length;       // Buffer size
    uint32_t offset;       // Consumed position
    uint32_t pos;          // Current read position
} RdmaXfer;

typedef struct RdmaContext {
    connection *conn;
    char *ip;
    int port;
    long long keepalive_te;            // Timer event for keepalive
    struct ibv_pd *pd;                 // Protection domain
    struct rdma_event_channel *cm_channel;
    struct ibv_comp_channel *comp_channel;
    struct ibv_cq *cq;                 // Completion queue
    RdmaXfer tx;                       // Local TX buffer
    char *tx_addr;                     // Remote TX buffer address
    uint32_t tx_key;                   // Remote buffer rkey
    uint32_t tx_length;
    uint32_t tx_offset;
    uint32_t tx_ops;
    RdmaXfer rx;                       // Local RX buffer
    ValkeyRdmaCmd *cmd_buf;            // Command buffer (send + recv)
    struct ibv_mr *cmd_mr;             // MR for command buffer
} RdmaContext;

typedef struct ValkeyRdmaMemory {
    uint16_t opcode;                   // RegisterXferMemory
    uint8_t rsvd[14];
    uint64_t addr;                     // Remote RX buffer address
    uint32_t length;                   // RX buffer length
    uint32_t key;                      // RDMA remote key
} ValkeyRdmaMemory;
```

## Memory Management

RDMA requires page-aligned, RDMA-registered memory regions. The
implementation uses raw `mmap` with guard pages to prevent accidental
access and to be fork-safe:

```c
static void *rdmaMemoryAlloc(size_t size) {
    size_t aligned_size = (size + page_size - 1) & (~(page_size - 1));
    size_t real_size = aligned_size + 2 * page_size;
    uint8_t *ptr = mmap(NULL, real_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    madvise(ptr, real_size, MADV_DONTDUMP);
    mprotect(ptr, page_size, PROT_NONE);                      // Top guard
    mprotect(ptr + size + page_size, page_size, PROT_NONE);   // Bottom guard
    return ptr + page_size;
}
```

The `MADV_DONTDUMP` flag excludes these regions from core dumps. Guard pages
protect against buffer overflows in both directions.

RDMA memory regions are NOT accessible in child processes (fork). The code
explicitly checks `server.in_fork_child` before any RDMA operation:

```c
static inline int connRdmaAllowCommand(void) {
    if (server.in_fork_child != CHILD_TYPE_NONE) {
        return C_ERR;
    }
    return C_OK;
}
```

## Configuration

```c
#define VALKEY_RDMA_MAX_WQE         1024
#define VALKEY_RDMA_DEFAULT_RX_SIZE (1024 * 1024)     // 1MB default
#define VALKEY_RDMA_MIN_RX_SIZE     (64 * 1024)       // 64KB minimum
#define VALKEY_RDMA_MAX_RX_SIZE     (16 * 1024 * 1024) // 16MB maximum
#define VALKEY_RDMA_KEEPALIVE_MS    3000               // 3-second heartbeat
```

RX buffer size is configurable via `rdma_config->rx_size`. The completion
vector (which CPU to interrupt) is configurable and defaults to random
selection among available vectors.

## Connection Lifecycle

1. Server listens via `rdma_listen` on CM (Connection Manager) channel.
2. Client resolves address, creates CM channel, calls `rdma_resolve_addr`.
3. Route resolution triggers `rdma_resolve_route`.
4. Client calls `rdma_connect` with QP (Queue Pair) parameters.
5. Server receives `RDMA_CM_EVENT_CONNECT_REQUEST`, creates RDMA resources
   (PD, CQ, QP, buffers), calls `rdma_accept`.
6. Both sides receive `RDMA_CM_EVENT_ESTABLISHED`.
7. Server registers its RX buffer by sending `RegisterXferMemory` command.
8. Data flows via one-sided RDMA writes with immediate data.

## Event Handling

RDMA connections use the completion channel fd for event loop integration.
Unlike TCP where POLLIN/POLLOUT drive read/write handlers separately, RDMA
only generates POLLIN events on the completion channel. The event handler
polls the CQ and dispatches:

```c
// In connRdmaEventHandler:
connRdmaHandleCq(rdma_conn);    // Process all CQ entries
// Then trigger read handler while data is available
while (ctx->rx.pos < ctx->rx.offset) {
    callHandler(conn, conn->read_handler);
}
// Re-register RX buffer when full
if (ctx->rx.pos == ctx->rx.length) {
    connRdmaRegisterRx(ctx, cm_id);
}
// Trigger write handler (RDMA has no POLLOUT equivalent)
if (ctx->tx.offset < ctx->tx.length && conn->write_handler) {
    callHandler(conn, conn->write_handler);
}
```

## Pending Write List

Since RDMA connections are always writable (no POLLOUT event), a
`pending_list` tracks connections with outstanding write handlers. This
list is processed to drive write callbacks that TCP would handle via
POLLOUT.

## ConnectionType Registration

```c
static ConnectionType CT_RDMA = {
    .get_type = connRdmaGetType,     // returns CONN_TYPE_RDMA
    .init = rdmaInit,
    .ae_handler = connRdmaEventHandler,
    .accept_handler = connRdmaAcceptHandler,
    .conn_create = connCreateRdma,
    .conn_create_accepted = connCreateAcceptedRdma,
    .write = connRdmaWrite,
    .read = connRdmaRead,
    .has_pending_data = rdmaHasPendingData,
    .process_pending_data = rdmaProcessPendingData,
    .postpone_update_state = postPoneUpdateRdmaState,
    .update_state = updateRdmaState,
    // ... full vtable
};
```

Note that RDMA implements `postpone_update_state` / `update_state` to
coordinate with IO threads - the IO threads must not modify event loop
state directly.
