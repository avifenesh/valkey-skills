# Networking Layer

Use when you need to understand client connections, read/write buffers, or the reply delivery mechanism.

Standard event-driven networking with RESP parsing, two-level reply buffers (16 KB static + dynamic list), and connection lifecycle. See Redis/Valkey networking docs for basics.

## Valkey-Specific Changes

- **I/O threading overhaul**: `io-threads > 1` offloads read, write, and even `epoll_wait` to a thread pool. Main thread dispatches via `postponeClientRead()` / `trySendWriteToIOThreads()` / `trySendPollJobToIOThreads()`. Thread count is dynamically adjusted by `adjustIOThreadsByEventLoad()` in `afterSleep()`.
- **Per-client I/O state tracking**: `io_read_state`, `io_write_state`, `cur_tid` fields on the client struct coordinate thread-safe read/write offloading.
- **Thread-local shared query buffer**: `thread_shared_qb` reduces allocation overhead for small reads across I/O threads.
- **Command queue**: `cmd_queue` field on the client struct holds pre-parsed pipelined commands.
- **RDMA transport**: Connection abstraction (`conn->type`) supports TCP, TLS, Unix, and RDMA.

Source: `src/networking.c`, `src/io_threads.c`
