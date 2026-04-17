# Event Loop, I/O Threads, BIO, Prefetch

Concurrency and scheduling surface. The `ae` reactor in `src/ae.c` and the `aeCreateFileEvent` / `aeCreateTimeEvent` / `aeSetBeforeSleepProc` / `aeSetAfterSleepProc` API are unchanged from Redis. Everything below is Valkey-specific scaffolding.

## Added to `aeEventLoop`

| Field / flag | Purpose |
|--------------|---------|
| `custompoll` (`aeCustomPollProc *`) | Replaces `aeApiPoll` when set, so I/O threads can drive polling. Installed with `aeSetCustomPollProc`. |
| `poll_mutex` (`pthread_mutex_t`) + `AE_PROTECT_POLL` flag | `AE_LOCK` / `AE_UNLOCK` macros in `ae.c` hold it during poll when the flag is set. Required any time an I/O thread can be in the poll path. |

## `beforeSleep` / `afterSleep` integration with I/O threads

`server.c:beforeSleep` calls `IOThreadsBeforeSleep(current_time)` (commits queued I/O jobs, handles `io-threads-always-active` debug mode).

`server.c:afterSleep` calls `IOThreadsAfterSleep(numevents)` - runs the **Ignition/Cooldown** scaling policy. It's **not** a pure event-count heuristic; it samples main-thread CPU via `RUSAGE_THREAD` and compares against constants (in `io_threads.c`):

- `IO_IGNITION_EVENTS` = 4
- `IO_IGNITION_CPU_SYS` = 30%
- `IO_IGNITION_CPU_USER` = 50%
- `IO_COOLDOWN_MS` = 1000
- `IO_SAMPLE_RATE_MS` = 10

When main-thread CPU exceeds the thresholds long enough, more workers are woken; when idle, extras are parked by locking their per-thread mutex.

Don't call `gettimeofday` for event timing - use `getMonotonicUs()` (TSC-backed where available).

## I/O threads (`src/io_threads.c`)

**Command execution stays on the main thread.** Workers only do socket read/write/poll/accept and object free.

### Data structures to grep

| Symbol | What/where |
|--------|------------|
| `io_threads[IO_THREADS_MAX_NUM]` | pthread handles; `IO_THREADS_MAX_NUM = 256` (`src/config.h`) |
| `io_threads_mutex[]` | per-thread mutex used to park workers |
| `io_private_inbox[]` | per-thread `spscQueue` (type in `src/queues.h`) |
| `io_jobs_submitted` / `io_jobs_finished` | submit counter + atomic finish counter |
| `server.active_io_threads_num` | current active count (1 = main only) |

Queue is single-producer / single-consumer (`spscEnqueue`, `spscDequeueBatch`, `spscCommit`, `spscIsEmpty`, `spscIsFull`). No shared-queue mutex; `io_threads_mutex[tid]` is only taken to park/unpark workers.

### Thread selection

```c
tid = (c->id % (active_io_threads - 1)) + 1;
```

Deterministic per-client affinity (for a given `active_io_threads_num`). If a client has a pending write on a different thread, the read is routed to the same thread to prevent concurrent access.

### Dispatch entry points

| Function | Offloads |
|----------|----------|
| `trySendReadToIOThreads(c)` | `read()` + parse |
| `trySendWriteToIOThreads(c)` | `writev()` - snapshots `io_last_reply_block`/`io_last_bufpos` before push |
| `trySendPollJobToIOThreads()` | `aeApiPoll`; installs `custompoll` |
| `trySendAcceptToIOThreads(conn)` | TLS accept when `CONN_FLAG_ALLOW_ACCEPT_OFFLOAD` is set |
| `tryOffloadFreeObjToIOThreads(o)` / `tryOffloadFreeArgvToIOThreads` | object free |

`waitForClientIO(c)` spins on `io_*_state == CLIENT_PENDING_IO` with `memory_order_acquire` until the worker hands back ownership.

### Config

| Config | Default | Notes |
|--------|---------|-------|
| `io-threads` | 1 | Total including main (8 = 7 workers). Range 1 to `IO_THREADS_MAX_NUM` (256). `DEBUG_CONFIG`. |
| `io-threads-always-active` | no | HIDDEN debug config - keep configured workers warm regardless of load |
| `min-io-threads-avoid-copy-reply` | 7 | HIDDEN - threshold at which reply-copy-avoidance activates |

**Deprecated** (silently accepted, no-op - in `deprecated_configs[]` in `src/config.c`): `events-per-io-thread` (Ignition/Cooldown replaced the event-count heuristic), `io-threads-do-reads` (reads always offloaded when I/O threads active).

## BIO (background I/O)

`src/bio.c`. Fixed set of worker threads, one per logical job type. Queue is `mutexQueue` (mutex + condvar), FIFO. `bioDrainWorker()` spin-waits for a specific worker's queue to empty.

| Worker | Job types |
|--------|-----------|
| 0 | `BIO_CLOSE_FILE` |
| 1 | `BIO_AOF_FSYNC`, `BIO_CLOSE_AOF` (serialized on the same thread by design) |
| 2 | `BIO_LAZY_FREE` |
| 3 | `BIO_RDB_SAVE` |
| 4 | `BIO_TLS_RELOAD` **(Valkey-only)** - background TLS cert re-parsing for `tls-auto-reload-interval` |

## Batch key prefetching (`src/memory_prefetch.c`)

Valkey-original. Interleaves CPU prefetch instructions across multiple keys so one key's memory access overlaps with another's.

### Two callers

- **I/O-thread batch path**: `processClientsCommandsBatch` handles N clients per I/O-thread boundary.
- **Pipelined single-client path**: `prefetchCommandQueueKeys` in `src/networking.c` handles one client's queued commands. Logic is duplicated between the two paths (TODO noted at top of `prefetchCommandQueueKeys`).

Both use `hashtableIncrementalFindStep` (one memory access per call, round-robin across keys) for the core interleaving.

### Phases (per batch)

1. Collect keys from each client's parsed command via `getKeysFromCommand`, plus the main `hashtable *` for each via `kvstoreGetHashtable`.
2. Prefetch: argv robjs → argv SDS payloads → hashtable entries (round-robin incremental find) → optionally value payloads.
3. Execute: `processPendingCommandAndInputBuffer` per client.

**Value-prefetch skipped** when copy-avoidance is active (threads ≥ `min-io-threads-avoid-copy-reply`, default 7) - the I/O thread writes directly from the value, prefetching into the main thread's L1 would miss.

### Config & stats

- `prefetch-batch-max-size` - default **16**, range **0-128**. `0` or `1` disables.
- `onMaxBatchSizeChange` reallocates the static `PrefetchCommandsBatch` if no work is in flight.
- INFO stats (under `stats` section): `io_threaded_total_prefetch_batches`, `io_threaded_total_prefetch_entries`. Backed by `server.stat_total_prefetch_batches` / `server.stat_total_prefetch_entries`.
