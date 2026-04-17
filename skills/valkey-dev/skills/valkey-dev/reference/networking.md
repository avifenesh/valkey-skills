# Networking, Command Dispatch, Transports

Byte flow: socket → `readQueryFromClient` → `parseInputBuffer` → `processInputBuffer` → `processCommand` → `call` → `cmd->proc`. All entry-points in `src/networking.c` and `src/server.c` - shape matches Redis.

## Client fields for I/O-thread offload (`struct client`, `src/server.h`)

| Field | Meaning |
|-------|---------|
| `io_read_state`, `io_write_state` | `CLIENT_IDLE` → `CLIENT_PENDING_IO` → `CLIENT_COMPLETED_IO`. Main thread transitions IDLE → PENDING before sending; worker transitions PENDING → COMPLETED; main thread resets COMPLETED → IDLE. |
| `cur_tid` (`uint8_t`) | ID of the I/O thread currently owning this client. |
| `cmd_queue` (`cmdQueue`) | Parsed pipelined commands waiting for dispatch - populated by `parseInputBuffer`, drained by `processInputBuffer`. |

**Ownership rule**: once `io_*_state == CLIENT_COMPLETED_IO`, the worker has released but the main thread hasn't reclaimed - don't touch from either side. Only transition back to `IDLE` from the main thread.

## Shared query buffer - aliasing gotcha

`thread_shared_qb` is a `_Thread_local sds` in `src/networking.c`. On short reads, `c->querybuf` **aliases** this buffer until `resetSharedQueryBuf(c)` detaches it. Code that holds `c->querybuf` across `processCommand` or `processEventsWhileBlocked` must detach first or another client on the same I/O thread will mutate it.

## I/O-thread dispatch (`src/io_threads.c`)

| Function | Role |
|----------|------|
| `postponeClientRead(c)` | returns 1 and queues read for an I/O thread; 0 to read inline |
| `trySendWriteToIOThreads(c)` | offloads `writev`; snapshots `io_last_reply_block`/`io_last_bufpos` to cap what the worker writes (prevents racing data appended after dispatch) |
| `trySendPollJobToIOThreads()` | hands `aeApiPoll` to a worker when Ignition is active |
| `trySendAcceptToIOThreads(conn)` | TLS accept offload when `CONN_FLAG_ALLOW_ACCEPT_OFFLOAD` is set |

`waitForClientIO(c)` spins on `io_*_state == CLIENT_PENDING_IO` with `memory_order_acquire` until the worker hands back ownership.

## Command table uses `hashtable`, not `dict`

`server.commands` and `server.orig_commands` are `hashtable *` - created by `hashtableCreate(&commandSetType)`. Command struct: `struct serverCommand`. JSON metadata in `src/commands/`; generator `utils/generate-command-code.py` emits the C tables (CI validates no diff - see `devex.md`).

## `-REDIRECT` during coordinated failover

During `CLUSTER FAILOVER` with `server.failover_state == FAILOVER_IN_PROGRESS`, `processCommand` (and the blocked-client path in `src/blocked.c`) reply:

```
-REDIRECT <primary_host>:<primary_port>
```

to clients that advertised redirect capability. Inside the branch: `EXEC` gets `discardTransaction`; other commands get `flagTransaction` + `rejected_calls++`. Clients without redirect capability get `blockPostponeClient` so they resume when the replica is promoted. This is the only path that returns a reply with a `-` prefix baked into the error payload rather than via `addReplyError`.

## Key prefetching

`prefetchCommandQueueKeys(c)` in `src/networking.c` warms CPU cache for queued commands' keys using `hashtableIncrementalFindState`. Config: `prefetch-batch-max-size` (default 16, range 0-128; 0 or 1 disables). The I/O-thread-path equivalent lives in `src/memory_prefetch.c` - see `event-loop.md`. Logic is intentionally duplicated (TODO on top of both).

## RESP protocol

Wire format, parser (`parseMultibulkBuffer`, `parseInlineBuffer`), buffer constants (`PROTO_IOBUF_LEN`, `PROTO_REPLY_CHUNK_BYTES`, `PROTO_INLINE_MAX_SIZE`, `PROTO_MBULK_BIG_ARG`), and RESP3-aware `addReply*` helpers are **unchanged from Redis**. `HELLO` is `helloCommand` in `src/networking.c`, `c->resp` tracks the version. If you're here because of a push/notification issue, see `monitoring.md` (tracking) and `client-commands.md` (pub/sub) for the Valkey-specific consumers of `server.pending_push_messages`.

## Transport layer: pluggable `ConnectionType`

`src/connection.c` / `.h`. Valkey abstracts transports as a vtable. All server code calls `connRead`/`connWrite`/`connAccept`/`connConnect` - inline wrappers that dispatch through `conn->type->op`. Never dereference type-specific fields outside the `CT_<name>` implementations.

### Registered types

`CONN_TYPE_SOCKET`, `CONN_TYPE_UNIX`, `CONN_TYPE_TLS`, `CONN_TYPE_RDMA`. Socket and Unix always register in `connTypeInitialize()`; TLS and RDMA depend on build (`BUILD_TLS`, `BUILD_RDMA`). Instances at `connTypes[CONN_TYPE_MAX]` plus cached accessors `connectionTypeTcp()` / `connectionTypeTls()` / `connectionTypeUnix()`. Implementations: `src/socket.c`, `src/unix.c`, `src/tls.c`, `src/rdma.c`.

### Non-obvious vtable slots

| Slot | Who needs it |
|------|--------------|
| `has_pending_data` / `process_pending_data` | TLS (buffered SSL reads), RDMA (completion queue). Called via `connTypeHasPendingData` / `connTypeProcessPendingData` outside the normal event loop. |
| `postpone_update_state` / `update_state` | RDMA (and any I/O-thread-aware transport). I/O threads must not touch ae state directly - queue via `postpone_update_state`, apply from main thread via `update_state`. |
| `get_peer_cert` / `get_peer_user` | TLS only - backs `tls-auth-clients-user` (see `security.md`). |
| `connIntegrityChecked` | Transport-level integrity flag (TLS = 1, plain socket = 0). |

### Listeners

`connListener listeners[CONN_TYPE_MAX]`. Each has up to `CONFIG_BINDADDR_MAX = 16` fds, a port, and transport-specific `priv` data.

### Adding a new transport

1. `static ConnectionType CT_Foo = { ... }` with vtable.
2. `struct foo_connection { connection c; /* fields */ }` - **`connection` must be first field** so the base pointer is castable.
3. Implement `read`, `write`, `accept`, `connect`, `addr`, `listen`, etc.
4. Guard registration with your compile-time flag, add to `connTypeInitialize()`.
5. Existing `connRead`/`connWrite` sites work unchanged.

### `CONN_FLAG_WRITE_BARRIER`

Inverts default read-before-write order; used for fsync-before-reply in AOF `always` mode. If you implement `ae_handler`, check the flag and order callbacks accordingly (reference: `connSocketEventHandler` in `src/socket.c`).

## RDMA transport

`src/rdma.c`. Linux-only, gated by `USE_RDMA` (`#if defined __linux__ && defined USE_RDMA`). Build: `USE_RDMA=1` (linked) or `USE_RDMA=2` (loadable module).

### Protocol

Custom 4-opcode command protocol over IB verbs (enum `ValkeyRdmaOpcode`):

| Opcode | Purpose |
|--------|---------|
| `GetServerFeature` | Client queries server capabilities |
| `SetClientFeature` | Client reports its capabilities |
| `Keepalive` | Heartbeat - IB has no transport-level keepalive; `VALKEY_RDMA_KEEPALIVE_MS = 3000` |
| `RegisterXferMemory` | Register RX buffer for peer's RDMA writes |

Data path: `IBV_WR_RDMA_WRITE_WITH_IMM` - sender writes into the receiver's pre-registered buffer and signals byte count via the immediate.

### Memory

Page-aligned, `mmap(MAP_ANONYMOUS)` + `madvise(MADV_DONTDUMP)` + `mprotect(PROT_NONE)` guard pages. **Not fork-safe** - `connRdmaAllowCommand` returns `C_ERR` when `server.in_fork_child != CHILD_TYPE_NONE`. Any RDMA call from a fork child is a bug.

### Sizing

| Constant | Value |
|----------|-------|
| `VALKEY_RDMA_MAX_WQE` | 1024 |
| `VALKEY_RDMA_MIN_RX_SIZE` | 64 KB |
| `VALKEY_RDMA_DEFAULT_RX_SIZE` | 1 MB |
| `VALKEY_RDMA_MAX_RX_SIZE` | 16 MB |

### Event loop integration

**No POLLOUT equivalent.** The completion-channel fd drives POLLIN only. `connRdmaEventHandler`:

1. Poll the CQ and dispatch results.
2. Call read handlers while `rx.pos < rx.offset`.
3. Re-register RX buffer when full (`connRdmaRegisterRx`).
4. Manually invoke write handlers (POLLOUT never fires).

Global `pending_list` tracks connections with outstanding write handlers; walk it to drive write callbacks that TCP would handle via the normal event loop.
