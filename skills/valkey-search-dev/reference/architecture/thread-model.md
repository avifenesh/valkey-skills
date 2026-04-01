# Thread Model

Use when understanding the concurrency architecture, TimeSlicedMRMWMutex behavior, fork suspension, writer resumption, or main thread vs background thread responsibilities.

Source: `src/valkey_search.cc`, `src/server_events.cc`, `src/index_schema.cc`, `vmsdk/src/time_sliced_mrmw_mutex.h`

## Contents

- [Thread Architecture](#thread-architecture)
- [Main Thread Responsibilities](#main-thread-responsibilities)
- [Reader Thread Pool](#reader-thread-pool)
- [Writer Thread Pool](#writer-thread-pool)
- [Utility Thread Pool](#utility-thread-pool)
- [gRPC Coordinator Thread](#grpc-coordinator-thread)
- [TimeSlicedMRMWMutex](#timeslicedmrmwmutex)
- [Fork Handling](#fork-handling)
- [Writer Suspension and Resumption](#writer-suspension-and-resumption)
- [Server Cron Maintenance](#server-cron-maintenance)
- [Thread Safety Annotations](#thread-safety-annotations)
- [See Also](#see-also)

## Thread Architecture

valkey-search operates across four thread contexts:

```
Main Thread (Valkey event loop)
  |-- Receives commands (FT.CREATE, FT.SEARCH, etc.)
  |-- Handles keyspace notifications
  |-- Runs server cron callbacks
  |-- Manages backfill scan
  |
Reader Thread Pool (N threads, default = CPU cores)
  |-- Executes query operations (FT.SEARCH, FT.AGGREGATE)
  |-- Acquires TimeSlicedMRMWMutex in read phase
  |
Writer Thread Pool (N threads, default = CPU cores)
  |-- Processes index mutations (add/modify/remove records)
  |-- Acquires TimeSlicedMRMWMutex in write phase
  |
Utility Thread Pool (1 thread by default)
  |-- Search result cleanup
  |-- Low-priority background tasks
  |
gRPC Server Thread (optional, cluster mode only)
  |-- coordinator::Server for cross-node communication
  |-- Handles SearchIndexPartition and GetGlobalMetadata RPCs
```

All pools are created during `ValkeySearch::Startup()`:

```cpp
reader_thread_pool_ = make_unique<vmsdk::ThreadPool>(
    "read-worker-", options::GetReaderThreadCount().GetValue(),
    options::GetThreadPoolWaitTimeSamples().GetValue());
writer_thread_pool_ = make_unique<vmsdk::ThreadPool>(
    "write-worker-", options::GetWriterThreadCount().GetValue(),
    options::GetThreadPoolWaitTimeSamples().GetValue());
utility_thread_pool_ = make_unique<vmsdk::ThreadPool>(
    "utility-worker-", options::GetUtilityThreadCount().GetValue(),
    options::GetThreadPoolWaitTimeSamples().GetValue());
```

Each pool receives a third argument - the wait-time sample queue size (default 100, configurable via `thread-pool-wait-time-samples`) for tracking task queue latency.

## Main Thread Responsibilities

The main thread (Valkey's event loop) handles all operations that require single-threaded access to Valkey's keyspace: command parsing, keyspace notifications, backfill scanning (`ValkeyModule_Scan`), `UpdateDbInfoKey` writes, FlushDB/SwapDB events, RDB save/load, and MULTI/EXEC queue processing.

`vmsdk::MainThreadAccessGuard<T>` wraps data that must only be accessed on the main thread, with debug assertions in non-release builds. Key guarded fields:

- `IndexSchema::db_key_info_` - database-side key mutation tracking
- `IndexSchema::backfill_job_` - backfill scan cursor and progress
- `IndexSchema::multi_mutations_keys_` - pending MULTI/EXEC mutations
- `SchemaManager::staged_db_to_index_schemas_` - replication staging

## Reader Thread Pool

Reader threads execute query operations dispatched from FT.SEARCH and FT.AGGREGATE. Each query:

1. Is parsed on the main thread.
2. If the reader pool has threads, the client is blocked and the query is dispatched to a reader worker.
3. The reader acquires the `TimeSlicedMRMWMutex` in **read phase**.
4. Multiple readers execute concurrently during the read phase.
5. Results are merged and the blocked client is unblocked on the main thread.

The reader pool supports priority scheduling and wait-time sampling. `SupportParallelQueries()` returns false if the reader pool has zero threads, in which case queries execute synchronously on the main thread.

`query_queue_size` (visible in `FT.INFO`) tracks how many queries are waiting in the reader pool's queue. `used_read_cpu` reports the average CPU utilization of reader threads.

## Writer Thread Pool

Writer threads process index mutations (adds, modifies, deletes) dispatched from keyspace notifications and backfill:

1. Main thread receives a keyspace notification.
2. Mutation data is extracted and tracked in `tracked_mutated_records_`.
3. A task is scheduled on the writer pool.
4. The writer acquires the `TimeSlicedMRMWMutex` in **write phase**.
5. Multiple writers execute concurrently on different keys.
6. Exclusion between writers on the same key is provided by `mutated_records_mutex_`.

Priority levels control mutation ordering:

| Priority | Source | Effect |
|----------|--------|--------|
| `kHigh` | Real-time keyspace events | Processed before backfill |
| `kLow` | Backfill scan | Yields to real-time mutations |

The `high-priority-weight` config (default 100, range 0-100) controls the scheduling ratio between high and low priority tasks. At 100, backfill tasks only execute when no real-time mutations are queued.

The writer pool is the one suspended during fork operations (see Fork Handling below). `writer_queue_size` and `used_write_cpu` are reported in INFO.

## Utility Thread Pool

The utility pool handles low-priority tasks that should not compete with queries or mutations:

```cpp
void ScheduleUtilityTask(absl::AnyInvocable<void()> task) {
    if (utility_thread_pool_) {
        utility_thread_pool_->Schedule(std::move(task),
                                       vmsdk::ThreadPool::Priority::kLow);
    } else {
        task();
    }
}
```

Primary use: `ScheduleSearchResultCleanup()` offloads destruction of large search result objects. This prevents query latency spikes from deallocation. Controlled by the `search-result-background-cleanup` config (default false).

If the utility pool is unavailable, tasks execute synchronously in the caller's context.

## gRPC Coordinator Thread

In cluster mode (`use-coordinator=true` and cluster enabled), a gRPC server is started:

```cpp
coordinator_ = coordinator::ServerImpl::Create(
    ctx, reader_thread_pool_.get(), coordinator_port);
```

The coordinator listens on `valkey_port + 20294` and handles:

- **GetGlobalMetadata** - returns cluster-wide index metadata for consistency
- **SearchIndexPartition** - executes a query on the local node's partition and returns results for fanout

CPU usage of coordinator threads is tracked via `vmsdk::ThreadGroupCPUMonitor` and reported in the `coordinator_threads_cpu_time_sec` INFO field.

The gRPC server is suspended during fork operations alongside the thread pools via `coordinator::GRPCSuspender`.

## TimeSlicedMRMWMutex

The core concurrency primitive is `vmsdk::TimeSlicedMRMWMutex`, which allows either multiple concurrent readers OR multiple concurrent writers, but never both simultaneously. Each `IndexSchema` owns one instance.

### Modes

```
[Read Phase]  <-- queries execute here (multiple concurrent readers)
     |
     v  (switch when write quota exceeded or read inactivity)
[Write Phase] <-- mutations execute here (multiple concurrent writers)
     |
     v  (switch when read quota exceeded or write inactivity)
[Read Phase]  ...
```

### Time quotas

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `read_quota_duration` | 10ms | Max read phase when writers are waiting |
| `read_switch_grace_period` | 1ms | Read inactivity before switching to write |
| `write_quota_duration` | 1ms | Max write phase when readers are waiting |
| `write_switch_grace_period` | 200us | Write inactivity before switching to read |

The 10:1 ratio (read 10ms vs write 1ms) prioritizes query latency. Writes get short bursts to process mutations, then yield back to readers.

### Lock acquisition

```cpp
// Query thread
vmsdk::ReaderMutexLock lock(&time_sliced_mutex_, may_prolong, ignore_quota);

// Writer thread
vmsdk::WriterMutexLock lock(&time_sliced_mutex_, may_prolong, ignore_quota);
```

- `may_prolong` - indicates the holder may need to extend the phase (prevents premature switch).
- `ignore_time_quota` - used for critical operations that cannot be interrupted (e.g., MULTI/EXEC batch flush uses `ignore_quota=true`).

### Global statistics

The mutex tracks cumulative statistics via `TimeSlicedMRMWStats`:

| Stat | Meaning |
|------|---------|
| `read_periods` | Number of read phase activations |
| `read_time_microseconds` | Total time in read phases |
| `write_periods` | Number of write phase activations |
| `write_time_microseconds` | Total time in write phases |

These appear under the `time_slice_mutex` INFO section alongside `time_slice_queries`, `time_slice_upserts`, and `time_slice_deletes` counters from `Metrics`.

## Fork Handling

Fork events (RDB save, replication) are critical because only the main thread survives in the child process. Background threads are terminated, potentially leaving data structures in inconsistent states.

### AtForkPrepare (pre-fork)

Registered via `pthread_atfork(AtForkPrepare, AfterForkParent, nullptr)` in `server_events.cc`:

1. Increment `worker_thread_pool_suspend_cnt`.
2. Suspend all three thread pools: writer, reader, utility.
3. Suspend the gRPC server via `GRPCSuspender`.

`SuspendWorkers()` blocks until all in-progress tasks complete, then prevents new tasks from starting. This guarantees no thread is mutating index data when the fork happens.

### AfterForkParent (post-fork, parent)

After the fork returns in the parent process:

1. Resume the **reader** thread pool immediately - queries can resume.
2. Resume the **utility** thread pool immediately.
3. Start the writer suspension timer (`writer_thread_pool_suspend_watch_`).
4. Resume the gRPC server via `GRPCSuspender`.

The writer pool is NOT immediately resumed. This is intentional - writer threads cause page faults that lead to copy-on-write overhead, increasing memory pressure while the child process is still running.

### Why writers stay suspended

When a child process (RDB save or replication) is alive, any writes to shared pages trigger copy-on-write. Vector index mutations are particularly expensive because they modify large contiguous memory regions. Keeping writers suspended reduces dirty pages and OOM risk.

## Writer Suspension and Resumption

The writer thread pool resumes based on the `max-worker-suspension-secs` config (default: 60 seconds):

### max-worker-suspension-secs > 0 (default behavior)

Writers resume on whichever comes first:

1. **Fork child dies** - `OnForkChildCallback` with `SUBEVENT_FORK_CHILD_DIED` triggers `ResumeWriterThreadPool(ctx, false)`.
2. **Timeout** - `OnServerCronCallback` checks `writer_thread_pool_suspend_watch_` duration. If it exceeds the config value, calls `ResumeWriterThreadPool(ctx, true)` and increments `writer_suspension_expired_cnt`.

### max-worker-suspension-secs <= 0

Writers resume on any fork child event (born or died). The code does not check the subevent type - in case the config was modified mid-fork, it resumes on both events to avoid stuck workers.

### ResumeWriterThreadPool

```cpp
void ResumeWriterThreadPool(ValkeyModuleCtx *ctx, bool is_expired) {
    writer_thread_pool_->ResumeWorkers();
    // ... logging and metrics ...
    writer_thread_pool_suspend_watch_ = std::nullopt;
}
```

Clears the suspension watch so cron stops checking. Metrics tracked:

| Metric | Meaning |
|--------|---------|
| `worker_pool_suspend_cnt` | Total fork-triggered suspensions |
| `writer_resumed_cnt` | Total writer pool resumptions |
| `reader_resumed_cnt` | Total reader pool resumptions |
| `writer_suspension_expired_cnt` | Resumptions due to timeout (not child death) |

## Server Cron Maintenance

`ValkeySearch::OnServerCronCallback()` runs on every server cron tick (10 times per second by default):

1. **Join terminated workers** - calls `JoinTerminatedWorkers()` on all three pools to clean up threads that exited but were not joined.
2. **Writer suspension timeout** - checks if the writer pool has been suspended too long and resumes if needed.
3. **Cluster map refresh** - in cluster mode with coordinator, calls `GetOrRefreshClusterMap()` if the map is stale or inconsistent.

`SchemaManager::OnServerCronCallback()` also runs on each tick and drives backfill processing across all indexes. Additionally, if `MetadataManager` is initialized, its `OnServerCronCallback` runs for cluster metadata maintenance.

## Thread Safety Annotations

The codebase uses Clang's thread safety analysis annotations extensively:

| Annotation | Meaning |
|------------|---------|
| `ABSL_GUARDED_BY(mutex)` | Field protected by the named mutex |
| `ABSL_LOCKS_EXCLUDED(mutex)` | Function must not hold the named mutex |
| `ABSL_EXCLUSIVE_LOCKS_REQUIRED(mutex)` | Function requires exclusive lock |
| `ABSL_SHARED_LOCKS_REQUIRED(mutex)` | Function requires shared lock |
| `ABSL_LOCKABLE` | Class can be used as a lock |
| `ABSL_SHARED_LOCK_FUNCTION()` | Function acquires shared lock |
| `ABSL_UNLOCK_FUNCTION()` | Function releases a lock |

These annotations enable compile-time verification of lock discipline. When modifying concurrent code, ensure annotations are updated to match the actual locking protocol.

## See Also

- [module-overview](module-overview.md) - Thread pool creation and configuration
- [index-schema](index-schema.md) - Mutation pipeline using the time-sliced mutex
- [schema-manager](schema-manager.md) - Backfill orchestration from server cron
- [execution](../query/execution.md) - Query dispatch to reader threads
- [hnsw](../indexes/hnsw.md) - Vector index mutations that drive COW overhead
- [metrics](../cluster/metrics.md) - Thread pool and suspension metrics
