# Event Loop, I/O Threads, BIO, Prefetch

Concurrency and scheduling surface. The `ae` reactor in `src/ae.c` and the `aeCreateFileEvent` / `aeCreateTimeEvent` / `aeSetBeforeSleepProc` / `aeSetAfterSleepProc` API are unchanged from Redis. Everything below is Valkey-specific scaffolding.

## `ae` reactor additions

| Field / flag | Purpose |
|--------------|---------|
| `custompoll` (`aeCustomPollProc *`) | Replaces `aeApiPoll` when set, so I/O threads can drive polling. Installed with `aeSetCustomPollProc`. |
| `poll_mutex` (`pthread_mutex_t`) + `AE_PROTECT_POLL` flag | `AE_LOCK` / `AE_UNLOCK` macros in `ae.c` hold it during poll when the flag is set. Required any time an I/O thread can be in the poll path. |

- Any new code path that can reach `aeApiPoll` from an I/O thread must set `AE_PROTECT_POLL` or install a `custompoll`. A second thread in `epoll_wait` without the mutex corrupts the reactor's internal fired-event buffer.
- Use `getMonotonicUs()` (TSC-backed where available) for event timing, not `gettimeofday`.
- The `ae` event loop starts via `aeMain` only after `initServer` / `clusterInit` return. Code running during cluster init can assume the event loop is not yet processing; guards added there for a feared event-loop race are dead code.

## `beforeSleep` / `afterSleep` integration with I/O threads

`server.c:beforeSleep` calls `IOThreadsBeforeSleep(current_time)` (commits queued I/O jobs, handles `io-threads-always-active` debug mode).

`server.c:afterSleep` calls `IOThreadsAfterSleep(numevents)` - runs the Ignition/Cooldown scaling policy. The model: it samples main-thread CPU via `RUSAGE_THREAD` and compares against thresholds, NOT event counts. When main-thread CPU exceeds thresholds long enough, more workers are woken; when idle, extras are parked by locking their per-thread mutex. Re-read `io_threads.c` for the current constants.

- The deprecated `events-per-io-thread` and `io-threads-do-reads` configs are still silently accepted (in `deprecated_configs[]` in `src/config.c`) and are no-ops. Do not assume the scaling decision is event-count based when you see them referenced.
- Main-thread utilisation is measured via `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`, not wall clock. With I/O threads active the main thread busy-spins `beforeSleep -> epoll_wait(timeout=0) -> afterSleep`, so wall-clock sampling reports ~100% regardless of real load. New observability code must use the CPU clock.
- `ProcessingEventsWhileBlocked` is true during RDB load, AOF load, full-sync load, long scripts, long module commands. Active expire / timer work executed in this state must NOT set `el_iteration_active` or bump `stat_active_time` - the outer caller already counts.
- An inactive I/O thread parked in `pthread_mutex_lock(io_threads_mutex[id])` is not doing work. Its active-time counter must NOT advance during that interval. Pattern: store `prev_work_start_time`, re-sample `work_start_time = getMonotonicUs()` at the top of each cycle, `atomic_fetch_add_explicit` only the delta between successful work loops.

## Main/IO ownership invariants

| Field | Owner | Handoff fence |
|-------|-------|---------------|
| `c->flags` | main only | none - never cross-boundary |
| `c->read_flags` | guarded by `io_read_state` | `io_read_state` transitions with acquire/release |
| `c->write_flags` | guarded by `io_write_state` | `io_write_state` transitions |
| keyspace, cluster state, `server.*` globals | main only | none - never cross-boundary |
| reply-block payload | main until push, IO during `CLIENT_PENDING_IO`, main after `COMPLETED_IO` reset | `io_*_state` + `memory_order_acquire` spin |

- Main thread owns dispatch, keyspace, cluster state, all `server.*` globals. I/O threads do ONLY socket I/O (`read`/`writev`/`poll`/TLS `accept`) and object free. ACL evaluation, command-table lookup, key prefetch, and `processCommand` run on main only.
- `io_*_state` transitions: main `IDLE -> PENDING_IO`, worker `PENDING_IO -> COMPLETED_IO`, main `COMPLETED_IO -> IDLE`. Between `COMPLETED_IO` and the main-thread reset, neither side may touch the client.
- `waitForClientIO(c)` spins on `io_*_state` with `memory_order_acquire` - that is the ownership handoff barrier. Do not replace the spin with a mutex without re-deriving latency impact; spinning is correct because IO threads are only active under load.
- `c->flags` is NOT shared across main/IO. Only `read_flags` / `write_flags` (guarded by `io_*_state`) are. New cross-boundary features encode into reply-block headers, not `c->flags`.
- `io_read_state` / `io_write_state` are deliberately `volatile`, NOT `_Atomic` - atomic ops in the main hot-path sanity checks would measurably slow the main loop. Correctness relies on IO threads being active only under load and on explicit fences at the state transitions. Do not "upgrade" these to `_Atomic` without redoing the microbenchmark.
- Any code that mutates shared structures read by I/O threads - replacing / removing command-table entries, rewriting shared RESP string objects bound to command responses - must first call `drainIOThreadsQueue()`. Precedent: `moduleUnregisterCommands`. `blocked_clients == 0` is NOT sufficient.
- Lazyfree work is NOT routed through the I/O thread drain mechanism. Module unload must call `drainIOThreadsQueue()` AND `bioDrainWorker(BIO_LAZY_FREE)` before `dlclose`.
- If an IO-thread enqueue can fail (bounded queue full), every client-side field mutated before the enqueue must be fully rolled back - including non-obvious fields like `last_header` and `buf_encoded`. Partial rollback that restores `io_write_state` + `write_flags` but leaves `last_header == NULL` corrupts the next write.
- Dynamic `io-threads` resize must drain all IO-thread queues and reset `active_io_threads_num = 1` before growing or shrinking. Otherwise the main thread can publish an id range into per-thread state while a worker is still initializing - tripping the `id > 0 && id < server.io_threads_num` assertion.
- Going from `io-threads=1` to `io-threads>1` at runtime must still invoke `prefetchCommandsBatchInit`. `initIOThreads` short-circuits at threads==1 and silently skips prefetch setup.
- `io_threads_mutex[]` is NOT a shared-queue mutex. It is per-thread and taken only to park/unpark workers. Queues between main and IO are SPSC lock-free (`spscEnqueue` / `spscDequeueBatch`).

## Atomic usage and memory ordering

- `memory_order_relaxed` is correct only for uniqueness-only counters (`fetch_add` where atomicity is the point). Synchronization flags - `replica_bio_disk_save_state`, `replica_bio_abort_save`, pending-context pointers, TLS-reload pending - need explicit acquire / release. Spraying relaxed erodes reasoning about which vars are sync points.
- On 32-bit targets, plain `long long` and `double` are 4-byte aligned; adding `_Atomic` bumps to 8. Cross-thread lock-free fields (e.g. `server.fsynced_reploff_pending`) must be declared `_Atomic(long long)` - the parenthesized form - or the compiler may emit a non-atomic load/store pair.
- `_Atomic` is a correctness marker for actually-shared values. Config values set once in argument parsing and only read thereafter stay plain `int`; only fields mutated by one thread and observed by another belong in `_Atomic`.
- Benchmark / rate-limiter counters under a thread pool should be CAS loops on the shared timestamp (`memory_order_release` on success, `memory_order_relaxed` on retry reads), not mutex-guarded critical sections.

## Lazyfree and BIO job ordering

- Lazyfree accounting: producer `atomic_fetch_add_explicit(&lazyfree_objects, ..., memory_order_relaxed)` before `bioCreateLazyFreeJob`. BIO worker `atomic_fetch_sub_explicit(&lazyfree_objects, ...)` + `atomic_fetch_add_explicit(&lazyfreed_objects, ...)` after the actual free. Flipping the order means the worker can decrement before the producer incremented - the counter goes negative (unsigned wraps to huge).
- Handing a list / buffer to a BIO async-free job and nulling the main-thread pointer is NOT enough: the BIO thread still holds the pointer. Any main-thread write that mutates the list contents before the BIO job runs is a UAF / data race.
- BIO jobs may still access job-owned memory after the caller logically releases it. Teardown must call `bioDrainWorker` before freeing, or order the free strictly after the drain returns. A sequence "free name -> bioDrainWorker" is a bug.
- TLS material reload runs on a BIO worker (`BIO_TLS_RELOAD`, Valkey-only addition). Shared state between main and BIO (pending SSL contexts, `tls_reload_pending`) must be `_Atomic` with explicit acquire/release. Plain pointer stores can be reordered across the flag by compiler or CPU.
- Before enqueuing a new BIO job that writes into a shared pending slot, the producer must check whether a previous job is still pending. Otherwise the queue holds duplicate jobs that race to overwrite the pending result.
- BIO workers own the connection for the lifetime of the job (e.g. dual-channel RDB download). Main must not read / write that connection while the BIO job is in flight - L5 / TLS transports like OpenSSL can break even if the kernel supports full-duplex.
- Replica bulk-payload transfer from a BIO thread must use `connRecvTimeout` on the BIO side. The main thread's busy-wait has no independent watchdog; the socket timeout bounds the BIO stall so `shouldAbortSave` can act.
- Busy-waiting on the main thread for a BIO worker (`bioPendingJobsOfType`) mirrors `waitForClientIO` and is the accepted pattern. A raw `bioDrainWorker` from the main thread is a hazard unless the worker has a read timeout guaranteeing termination.
- BIO worker identity must derive from a bounds-checked index into `bio_workers`. `bioWorkerNum(bwd)` is UB outside `[bio_workers, bio_worker_end)`. Pointer comparison outside the same array is itself UB in C; the bounds assertion must precede the subtraction.
- BIO queue is `mutexQueue` (mutex + condvar FIFO), NOT lock-free. `mutexQueuePeek` is unsafe under multiple readers (a second reader can pop the peeked item). BIO uses push/pop plus a per-worker static tracking pointer so valgrind can still see the in-flight job.

## Shutdown, teardown, signal handlers

- IO-threads shutdown uses cooperative stop-flag polling (`memory_order_relaxed` atomic read inside the worker loop), NEVER `PTHREAD_CANCEL_ASYNCHRONOUS`. Async cancel kills the thread mid-`malloc`/`free` or while holding internal locks.
- `pthread_cancel()` does NOT take `io_threads_mutex[id]`. The shutdown path must unlock the mutex for `id >= server.active_io_threads_num` before `pthread_cancel + pthread_join`. Holding the mutex during cancel deadlocks (`makeThreadKillable()` was removed to fix jemalloc teardown, creating this constraint).
- IO-threads are NOT asynchronously cancellable after `makeThreadKillable()` removal. `pthread_cancel()` only lands at explicit `pthread_testcancel()` points in `IOThreadMain`. The worker loop must contain a cancellation point or `pthread_join` hangs forever.
- Module unload waits for IO threads AND BIO lazyfree drain. `drainIOThreadsQueue()` + `bioDrainWorker(BIO_LAZY_FREE)` before `dlclose`, or module-spawned threads use-after-unload.
- Crash-handler stack traces run in a signal handler. Only async-signal-safe work inline. `malloc`-dependent symbolization (libbacktrace) must fork a child (fork is async-signal-safe). Parent wait is `waitpid(WNOHANG)` loop handling `EINTR`, with SIGKILL fallback on timeout.
- Lua VM is single-threaded. `FUNCTION FLUSH ASYNC` + `FUNCTION LOAD` races require the BIO worker to own its own `lua_State` (for `lua_close`) and main to have a freshly-created one. Sharing one `lua_State` across teardown and load is a crash.

## Batch key prefetching (`src/memory_prefetch.c`)

Valkey-original. Interleaves CPU prefetch instructions across multiple keys so one key's memory access overlaps with another's. Two callers run the SAME logic on DIFFERENT code paths - the IO-thread batch (`processClientsCommandsBatch`) and the pipelined single-client path (`prefetchCommandQueueKeys` in `networking.c`). A change to prefetch semantics in only one of the two is almost always a bug.

- Prefetch, command lookup, and `processCommand` run on the MAIN thread only. IO threads run read/parse only (`ioThreadReadQueryFromClient -> parseCommand -> processMultibulkBuffer`). Prefetching on IO threads races with main-thread kvstore mutation.
- Value-prefetch is skipped when copy-avoidance is active (threads >= `min-io-threads-avoid-copy-reply`, default 7). The IO thread writes directly from the value; prefetching into the main thread's L1 would miss.
- Both callers use `hashtableIncrementalFindStep` (one memory access per call, round-robin across keys). A new caller must also use the incremental form - a blocking `hashtableFind` defeats the interleaving.
- `onMaxBatchSizeChange` reallocates the static `PrefetchCommandsBatch` only when no work is in flight. Config mutation during active batch is a corruption source.

## Event-loop / client-state invariants

- All `blockInUse` API entry points (mutating bstate dict, `server.blocked_clients` counters, `server.unblocked_clients`, `inuse_key_to_clients`) run on main only. Background threads that finish work on a key must POST a completion event to the main event loop - never call `unblockClientsInUseOnKey()` directly.
- `BLOCKED_INUSE` clients have their read handler detached from the event loop - EOF is no longer detected there. The crontab path (`clientsCronTcpIsClosing`) must probe the fd via a connection-type-specific `is_closing` hook (TCP_INFO-based `getsockopt` on Linux/macOS). Connection types without `is_closing` (Unix sockets, RDMA, non-Linux TCP without TCP_INFO) cannot reap zombies this way.
- Failover `disconnectOrRedirectAllBlockedClients` must NOT unblock `BLOCKED_INUSE` clients. The `bgIterator` owner is responsible for `unblockClientsInUseOnKey` on failover; `BLOCKED_INUSE` has no timeout and sending an error mid-command is unsafe.
- `c->flag.reprocessing_command` must be set/cleared symmetrically around unblock-driven re-execution. The reprocessing branch in `processCommand` must test this explicit flag, NOT infer from `c->cmd != NULL`. With IO-threaded parsing, `c->cmd` is pre-populated from `c->io_parsed_cmd`, so `c->cmd != NULL` no longer means "this is a re-execution".
- `evictClients` within a single iteration can re-observe the same client because `freeClient` returning 0 (async close) leaves it in place with `CLIENT_CLOSE_ASAP`. Eviction accounting must track already-counted clients explicitly - a simple `close_asap` check re-counts the pending-freed set every call.
- Bulk key deletion on main (slot purge on migration failure, `FLUSHSLOT`) must be offloaded to lazyfree. Blocking main on per-key unlink during slot ops is a latency regression and must be gated on cluster version so both sides agree on the replicated flush primitive.
- Cluster bus must not rely on synchronous socket I/O on main for any message exchange during steady-state failover/migration. Blocking in `receiveSynchronousResponse()` during `REPL_STATE_RECEIVE_PING_REPLY` stalls the event loop up to `repl_syncio_timeout` (default 5s).
