# Networking, Command Dispatch, Transports

Byte flow: socket -> `readQueryFromClient` -> `parseInputBuffer` -> `processInputBuffer` -> `processCommand` -> `call` -> `cmd->proc`. Entry points in `src/networking.c` and `src/server.c`.

## Client fields for I/O-thread offload (`struct client`, `src/server.h`)

| Field | Meaning |
|-------|---------|
| `io_read_state`, `io_write_state` | `CLIENT_IDLE` -> `CLIENT_PENDING_IO` -> `CLIENT_COMPLETED_IO`. Main transitions IDLE -> PENDING before sending; worker transitions PENDING -> COMPLETED; main resets COMPLETED -> IDLE. `volatile`, NOT `_Atomic` - deliberate. Fence is placed AFTER the state update; reordering it earlier breaks the MPSC handoff. |
| `cur_tid` (`uint8_t`) | ID of the I/O thread currently owning this client. |
| `cmd_queue` / `io_parsed_cmd` (`cmdQueue`) | Parsed pipelined commands waiting for dispatch. Per-command state (`read_flags`, input bytes) lives on the queue entry, not on `c`. |
| `read_flags`, `write_flags` | The ONLY client fields safe to cross the main/IO boundary. `write_flags` is guarded by `io_write_state` (PENDING = IO owns, otherwise main owns). |

Once `io_*_state == CLIENT_COMPLETED_IO`, the worker has released but main has not reclaimed - don't touch from either side. Only transition back to `IDLE` from the main thread.

`waitForClientIO(c)` spins on `io_*_state == CLIENT_PENDING_IO` with `memory_order_acquire` until the worker hands back ownership.

## Shared query buffer - aliasing gotcha

`thread_shared_qb` is a `_Thread_local sds` in `src/networking.c`. On short reads, `c->querybuf` aliases this buffer until `resetSharedQueryBuf(c)` detaches it. Code that holds `c->querybuf` across `processCommand` or `processEventsWhileBlocked` must detach first or another client on the same I/O thread will mutate it.

## I/O-thread dispatch (`src/io_threads.c`)

| Function | Role |
|----------|------|
| `postponeClientRead(c)` | returns 1 and queues read for an I/O thread; 0 to read inline |
| `trySendWriteToIOThreads(c)` | offloads `writev`; snapshots `io_last_reply_block` / `io_last_bufpos` to cap what the worker writes (prevents racing data appended after dispatch) |
| `trySendPollJobToIOThreads()` | hands `aeApiPoll` to a worker when Ignition is active |
| `trySendAcceptToIOThreads(conn)` | TLS accept offload when `CONN_FLAG_ALLOW_ACCEPT_OFFLOAD` is set |

## Command table uses `hashtable`, not `dict`

`server.commands` and `server.orig_commands` are `hashtable *` - created by `hashtableCreate(&commandSetType)`. Command struct: `struct serverCommand`, not `struct redisCommand`. JSON metadata in `src/commands/`; generator `utils/generate-command-code.py` emits the C tables (CI validates no diff). Runtime-renamed commands keep both `fullname` (original) and `current_name` - logs, NOPERM errors, LATENCY output, and internal comparisons depend on the original. Agents trained on Redis will reach for `dictFind` / `dictAdd` here - wrong.

When a hashtable stores `robj *` values with an embedded key via `objectSetKeyAndExpire`, `hashFunction` / `keyCompare` callbacks must derive the key via `objectGetKey()`, not `objectGetVal()`. Passing a DB value `robj` to `lookupKeyRead` reads its value payload as the name - silent corruption.

## `-REDIRECT` during coordinated failover

During `CLUSTER FAILOVER` with `server.failover_state == FAILOVER_IN_PROGRESS`, `processCommand` (and the blocked-client path in `src/blocked.c`) reply `-REDIRECT <primary_host>:<primary_port>` to clients that advertised redirect capability. `EXEC` gets `discardTransaction`; other commands get `flagTransaction` + `rejected_calls++`. Clients without redirect capability get `blockPostponeClient` so they resume when the replica is promoted. This is the only path that returns a reply with a `-` prefix baked into the error payload rather than via `addReplyError`.

## Command dispatch invariants

- Command execution stays on the main thread. I/O workers only do `read()` + parse, `writev()`, `aeApiPoll`, TLS `SSL_accept`, object free. Anything that touches keyspace, replies, cluster state, or `server.*` globals runs from the main thread.
- Reply-ordering: type-check + `lookupKeyRead` / `lookupKeyWrite` must happen BEFORE `addReplyArrayLen` / `addReplyMapLen` / `addReplyPushLen` or any other length-prefix helper. Emitting the header then an error (`addReplyError` WRONGTYPE) desyncs the client - they read the header and expect N elements that never arrive. HPERSIST is the canonical example. Any new length-prefix helper has the same constraint.
- Error replies keep the wire stream synchronised. Never emit an array / map header then conditionally switch to error. `debugServerAssert` in debug builds enforces this. A follow-up request must still parse and respond correctly after any error path.
- `-` prefix errors go through `addReplyError`, never baked into payload. `-REDIRECT` is the single documented exception.
- Write-path five-step ordering: (1) AOF/replica propagation (as `DEL` if key was removed), (2) `signalModifiedKey` for WATCH + client-tracking invalidation, (3) `notifyKeyspaceEvent`, (4) `server.dirty++`, (5) use `shared.czero` / `shared.cone` for integer replies. Missing any silently breaks WATCH, tracking, notifications, or BGSAVE triggers - not the command result.
- `signalModifiedKey` + `notifyKeyspaceEvent` fire BEFORE `addReply*`. `addReply*` calls `prepareClientToWrite`, which installs the client on the pending-write queue and arms the write handler. A module that blocks on a keyspace notification must transition into blocked state before any reply byte is queued.
- Use `initDeferredReplyBuffer` when replying first, notifying second is unavoidable. No-op when no module subscribes, so zero cost on the hot path.
- `LOOKUP_NOTOUCH` reads `server.current_client->flag.no_touch`, NOT `server.executing_client`. `executing_client` is NULL when `handleClientsBlockedOnKeys` re-executes an unblocked client's command. Reversing this leaks LRU/LFU updates.
- Command JSON `WRITE` flag is per-command, not per-invocation. Set `WRITE` if ANY optional arg can mutate state - HGETEX is WRITE because of its EX/PX/EXAT/PXAT/PERSIST options.
- Keyspec flags (`RM`, `ACCESS`, `DELETE`, `RW`) are orthogonal to command flags (`WRITE`, `READONLY`) and describe per-key effect. A key used as a condition to decide write vs no-write (e.g. `SETNX`, `DELIFEQ`) is NOT `ACCESS` - `ACCESS` requires that stored user data is returned, copied, or exposed. Miscategorising changes client-tracking invalidation scope. The dispatcher does not evaluate key-specs; correctness relies on command flags matching the JSON specs.
- `server.dirty` delta after `call()` is a reliable read/write classifier. Zero delta = read path. Post-hoc assertion, not dispatch logic.

## I/O-thread offload invariants

- `c->flags` is NOT thread-safe across main/IO boundary. Only `read_flags` / `write_flags` (guarded by `io_*_state`) are. New IO-thread-visible features go in `read_flags` / `write_flags` or a reply-block header byte - never `c->flags` or a new client flag.
- Decisions needing both a live config value and per-client state are made on the main thread at `addReply` time. Encode the decision into the reply block header (reserved flag byte); IO thread reads the encoded flag from payload, not from config or `c->flags`. Deciding later in the IO thread races `CONFIG SET`.
- `io_read_state` / `io_write_state` are `volatile`, NOT `_Atomic`. Atomics measurably slow the main hot-path. Memory fence is placed AFTER the state update - reordering it earlier creates a window where main sees the updated state but not the updated `read_flags`, breaking MPSC signalling.
- Parsed-command queue carries per-command state. `read_flags` on the queue entry records the parse outcome (`READ_FLAGS_PREFETCHED`, `READ_FLAGS_BAD_ARITY`, parse errors, per-command input byte counts). Main reads from the queue entry, not re-derived from `c->cmd`. Unchecked bad-arity flag silently executes the command with undefined keys.
- Key prefetch and command lookup run ONLY on the main thread. IO-thread path is `ioThreadReadQueryFromClient` -> `parseCommand` -> `processMultibulkBuffer`. Main path picks up in `processIOThreadsReadDone` -> `processPendingCommandAndInputBuffer` -> `processCommandAndResetClient` -> `processInputBuffer`. When main falls through to parse more input (e.g. first command was AUTH), it must re-check `canParseCommand` / `canProcessCommand` - the loop must not assume all queued commands are executable.
- Any mutation of shared structures read by IO threads must `drainIOThreadsQueue()` first. Precedent: `moduleUnregisterCommands`. Swapping shared RESP string objects, replacing command-table entries, or any runtime rebind follows the same ordering.
- COB SDS length is main-thread read. IO thread must not dereference queued reply SDS to measure length - races main-thread mutation. Accounting that needs the length is done BEFORE handoff, or via an atomic counter written inside the IO thread.
- Outbound main-thread clients (replicationAuth, cluster MIGRATE source link) must not block on synchronous `connRead` / `connWrite` while main serves traffic. Complex request/response over outbound connections belongs in an async handler.
- Cross-thread allocator locality: allocate+free on one thread, pass only sds bytes. Allocating on main and freeing on IO (or vice versa) breaks per-thread allocator locality - silent regression. Deviations need an explicit comment.
- IO-thread enqueue is a commit point. If the bounded queue is full, roll back every field touched before the enqueue call - `block->last_header`, `buf_encoded`, `write_flags`, `io_write_state`. Partial rollback corrupts the next write (header-reuse fast path breaks).
- Any `addReply*` installs the client on the pending-write queue via `prepareClientToWrite`; idempotent but not free.
- ACL evaluation is main-thread-only. IO thread captures raw identity material (TLS peer cert CN) into a connection/client field; `clientAcceptHandler` on main does the ACL lookup once handshake completes.

## Key prefetching

`prefetchCommandQueueKeys(c)` in `src/networking.c` warms CPU cache for queued commands' keys using `hashtableIncrementalFindState`. Config: `prefetch-batch-max-size` (default 16, range 0-128; 0 or 1 disables). The IO-thread-path equivalent lives in `src/memory_prefetch.c`. Going from `io-threads=1` to `io-threads>1` at runtime must still invoke `prefetchCommandsBatchInit`; `initIOThreads` short-circuits at threads==1, but prefetch init must not be gated on `threads > 1`.

## Transport layer invariants (`src/connection.c` / `.h`)

Valkey abstracts transports as a vtable. Server code calls `connRead` / `connWrite` / `connAccept` / `connConnect` - inline wrappers that dispatch through `conn->type->op`. Registered types: `CONN_TYPE_SOCKET`, `CONN_TYPE_UNIX`, `CONN_TYPE_TLS`, `CONN_TYPE_RDMA`. Socket and Unix always register in `connTypeInitialize()`; TLS and RDMA depend on build (`BUILD_TLS`, `BUILD_RDMA`). Instances at `connTypes[CONN_TYPE_MAX]` with cached accessors `connectionTypeTcp()` / `connectionTypeTls()` / `connectionTypeUnix()`.

- New transport: `connection` base must be the first field of `struct foo_connection`. The base pointer must be castable. Never dereference type-specific fields outside the `CT_<name>` implementation.
- IO-thread-aware transports must implement `postpone_update_state` + `update_state`. IO threads must not touch `ae*` state directly - queue via `postpone_update_state`, apply from main via `update_state`.
- `CONN_FLAG_WRITE_BARRIER` inverts read-before-write for fsync-before-reply in AOF `always` mode. Custom `ae_handler` implementations must honor the flag (reference: `connSocketEventHandler` in `src/socket.c`).
- TCP_NODELAY + SO_KEEPALIVE go on BOTH accept-side and connect-side sockets that participate in cluster-bus or replication traffic. Replication uses `connConnect` (client-side) to dial the primary; cluster bus also initiates outbound connections. Applying these only in the generic accept handler leaves outbound sockets Nagled. Valkey does not use Nagle's algorithm anywhere.
- `CLUSTER SLOTS` and `MOVED` / `ASK` return TCP vs TLS ports from the originating client's connection type. These are the ONLY two ports gossiped. RDMA gossips as the TCP port, so `rdma-port must equal tcp-port` in cluster mode - otherwise MOVED steers clients to a TCP port with no RDMA listener (silent connection failures). Propagating a separate rdma-port would require a new cluster-bus gossip field.
- Non-obvious vtable slots: `has_pending_data` / `process_pending_data` (TLS buffered reads, RDMA completion queue) called via `connTypeHasPendingData` / `connTypeProcessPendingData` outside the normal event loop; `get_peer_cert` / `get_peer_user` (TLS only, backs `tls-auth-clients-user`); `connIntegrityChecked` (TLS = 1, plain socket = 0).
- Adding a new transport: (1) `static ConnectionType CT_Foo = { ... }`; (2) `struct foo_connection { connection c; /* fields */ }` - `connection` first field; (3) implement `read`, `write`, `accept`, `connect`, `addr`, `listen`; (4) guard registration with the compile-time flag, add to `connTypeInitialize()`.

## RDMA transport (`src/rdma.c`)

Linux-only, gated by `USE_RDMA` (`#if defined __linux__ && defined USE_RDMA`). Build: `USE_RDMA=1` (linked) or `USE_RDMA=2` (loadable module).

- Not fork-safe. `connRdmaAllowCommand` returns `C_ERR` when `server.in_fork_child != CHILD_TYPE_NONE`. Any RDMA call from a fork child is a bug.
- No POLLOUT equivalent. The completion-channel fd drives POLLIN only. `connRdmaEventHandler` must poll the CQ, dispatch results, call read handlers while `rx.pos < rx.offset`, re-register RX buffer when full (`connRdmaRegisterRx`), and manually invoke write handlers. Global `pending_list` tracks connections with outstanding write handlers - walk it to drive write callbacks that TCP would handle via the normal event loop.
- RDMA cannot coexist with MPTCP on the same outbound connection. Current policy is assert.
- MPTCP negotiation is asymmetric. `repl-mptcp yes` on replica + `mptcp yes` on primary -> MPTCP; any other combination falls back to TCP. `repl-mptcp` is immutable at runtime - changing it after the replication link is established has no effect until reconnect.
