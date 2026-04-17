# Thread model

Use when reasoning about concurrency, `TimeSlicedMRMWMutex`, fork suspension, writer resumption, or main-thread vs background-thread split.

Source: `src/valkey_search.cc`, `src/server_events.cc`, `src/index_schema.cc`, `vmsdk/src/time_sliced_mrmw_mutex.h`.

## Thread contexts

| Thread(s) | Default size | Workload |
|-----------|--------------|----------|
| Main (Valkey event loop) | 1 | Command parsing, keyspace notifications, cron, backfill scan, RDB load/save, MULTI/EXEC queue |
| Reader pool | CPU cores | FT.SEARCH / FT.AGGREGATE - `TimeSlicedMRMWMutex` read phase |
| Writer pool | CPU cores | Index mutations (add/modify/remove) - write phase |
| Utility pool | 1 | Search-result cleanup, low-priority work |
| gRPC server | optional | Cluster mode only - `coordinator::Server` for cross-node RPCs |

Pools created in `ValkeySearch::Startup()` via `vmsdk::ThreadPool(name_prefix, size, wait_time_samples)`. Wait-time sample queue default 100, controlled by `thread-pool-wait-time-samples`.

## Main-thread-only state

`vmsdk::MainThreadAccessGuard<T>` wraps data with debug assertions. Key guarded fields:

- `IndexSchema::db_key_info_` - DB-side key mutation tracking
- `IndexSchema::backfill_job_` - scan cursor + progress
- `IndexSchema::multi_mutations_keys_` - pending MULTI/EXEC mutations
- `SchemaManager::staged_db_to_index_schemas_` - replication staging

## Reader pool

Flow: main parses, blocks client, dispatches to reader worker. Worker acquires `ReaderMutexLock(time_sliced_mutex_)` (read phase). Multiple readers concurrent. Results merged on main, client unblocked.

`SupportParallelQueries()` false if reader pool has 0 threads -> queries run synchronously on main.

INFO fields: `query_queue_size` (pending queries), `used_read_cpu`.

## Writer pool

Flow: main gets notification, tracks mutation in `tracked_mutated_records_`, schedules task. Worker acquires `WriterMutexLock(time_sliced_mutex_)` (write phase). Multiple writers concurrent on different keys; `mutated_records_mutex_` arbitrates same-key writers.

Priorities:

| Priority | Source | Effect |
|----------|--------|--------|
| `kHigh` | real-time keyspace events | processed before backfill |
| `kLow` | backfill scan | yields to real-time |

`high-priority-weight` (default 100, range 0-100) sets scheduling ratio. 100 = backfill only runs when real-time queue empty.

Writer pool is **suspended across fork** (see below). INFO: `writer_queue_size`, `used_write_cpu`.

## Utility pool

```cpp
void ScheduleUtilityTask(absl::AnyInvocable<void()> task) {
    if (utility_thread_pool_) utility_thread_pool_->Schedule(std::move(task), Priority::kLow);
    else                      task();  // sync fallback
}
```

Main use: `ScheduleSearchResultCleanup()` - offload destruction of large result sets to avoid query-path latency spikes. Gated by `search-result-background-cleanup` (default false).

## gRPC coordinator (cluster mode)

`use-coordinator=true` + cluster enabled:

```cpp
coordinator_ = coordinator::ServerImpl::Create(ctx, reader_thread_pool_.get(), coordinator_port);
```

Port = `valkey_port + 20294`. RPCs: `GetGlobalMetadata`, `SearchIndexPartition`. CPU tracked via `vmsdk::ThreadGroupCPUMonitor` -> `coordinator_threads_cpu_time_sec`. Suspended during fork via `coordinator::GRPCSuspender`.

## `TimeSlicedMRMWMutex`

Per-`IndexSchema`. Either multiple concurrent readers OR multiple concurrent writers, never both.

Quotas (10:1 read:write - prioritize query latency):

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `read_quota_duration` | 10 ms | max read phase when writers are waiting |
| `read_switch_grace_period` | 1 ms | read inactivity before switching to write |
| `write_quota_duration` | 1 ms | max write phase when readers are waiting |
| `write_switch_grace_period` | 200 us | write inactivity before switching to read |

Lock construction:

```cpp
vmsdk::ReaderMutexLock lock(&time_sliced_mutex_, may_prolong, ignore_quota);
vmsdk::WriterMutexLock lock(&time_sliced_mutex_, may_prolong, ignore_quota);
```

- `may_prolong` - holder may need to extend phase (prevents premature switch).
- `ignore_time_quota` - critical sections (MULTI/EXEC batch flush uses `ignore_quota=true`).

INFO (`time_slice_mutex` section): `read_periods`, `read_time_microseconds`, `write_periods`, `write_time_microseconds`, plus `Metrics` counters `time_slice_queries` / `_upserts` / `_deletes`.

## Fork handling

`pthread_atfork(AtForkPrepare, AfterForkParent, nullptr)` registered in `server_events.cc`.

### `AtForkPrepare` (pre-fork)

1. Increment `worker_thread_pool_suspend_cnt`.
2. Suspend writer + reader + utility pools via `SuspendWorkers()` - blocks until in-progress tasks complete.
3. Suspend gRPC server via `GRPCSuspender`.

Guarantees no thread is mid-mutation when the fork happens.

### `AfterForkParent`

1. Resume **reader** + **utility** pools immediately - queries can continue.
2. Start `writer_thread_pool_suspend_watch_` timer.
3. Resume gRPC server.

Writer pool intentionally NOT resumed. Writer threads dirty pages -> copy-on-write -> memory pressure while the child (RDB save / replication) is alive. Vector mutations modify large contiguous regions - especially expensive under COW.

## Writer resume policy

`max-worker-suspension-secs` (default 60):

**`> 0`**: writers resume at the earlier of:

- Fork child dies - `OnForkChildCallback(SUBEVENT_FORK_CHILD_DIED)` -> `ResumeWriterThreadPool(ctx, /*is_expired=*/false)`.
- Timeout - `OnServerCronCallback` checks `writer_thread_pool_suspend_watch_`; exceeded -> `ResumeWriterThreadPool(ctx, true)` + bump `writer_suspension_expired_cnt`.

**`<= 0`**: resume on any fork child event (born or died). Doesn't check subevent - protects against config changes mid-fork leaving workers stuck.

`ResumeWriterThreadPool()` calls `writer_thread_pool_->ResumeWorkers()` and clears `writer_thread_pool_suspend_watch_`.

Metrics: `worker_pool_suspend_cnt`, `writer_resumed_cnt`, `reader_resumed_cnt`, `writer_suspension_expired_cnt`.

## Server cron

`ValkeySearch::OnServerCronCallback()` each tick (default 10 Hz):

1. `JoinTerminatedWorkers()` on all three pools.
2. Check writer suspension timeout and resume if needed.
3. Cluster mode + coordinator: `GetOrRefreshClusterMap()` when stale / inconsistent.

`SchemaManager::OnServerCronCallback()` drives backfill across all indexes per tick. `MetadataManager::OnServerCronCallback()` runs cluster metadata maintenance.

## Thread-safety annotations (Clang)

| Annotation | Meaning |
|------------|---------|
| `ABSL_GUARDED_BY(m)` | field protected by mutex `m` |
| `ABSL_LOCKS_EXCLUDED(m)` | function must NOT hold `m` |
| `ABSL_EXCLUSIVE_LOCKS_REQUIRED(m)` | function requires exclusive lock |
| `ABSL_SHARED_LOCKS_REQUIRED(m)` | function requires shared lock |
| `ABSL_LOCKABLE` | type usable as lock |
| `ABSL_SHARED_LOCK_FUNCTION()` | function acquires shared lock |
| `ABSL_UNLOCK_FUNCTION()` | function releases lock |

Compile-time lock-discipline verification. Keep annotations in sync when modifying concurrent code.
