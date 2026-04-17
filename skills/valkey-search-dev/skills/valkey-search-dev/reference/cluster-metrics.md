# Metrics, FT.INFO, FT._DEBUG

Use when reasoning about observability, the `Metrics` singleton, FT.INFO fanout, or FT._DEBUG diagnostics.

Source: `src/metrics.h`, `src/commands/ft_info.{cc,_parser.h}`, `src/commands/ft_debug.cc`.

## `Metrics` singleton

Meyers pattern (`static Metrics instance` in `GetInstance()`). Nested `Stats` struct holds counters and samplers. Access:

```cpp
Metrics::GetStats().some_counter++;
```

`Stats` is mutable on the const singleton reference. Per-counter thread safety: atomics for background-thread counters; non-atomic counters are main-thread-only.

## Counter groups

### Query (main thread unless noted)

- `query_{successful,failed}_requests_cnt` - overall query outcomes
- `query_result_record_dropped_cnt` - records dropped during processing
- `query_hybrid_requests_cnt` - hybrid (vector + filter) queries
- `query_{nonvector,vector,text}_requests_cnt` (atomic) - per query-type
- `query_{inline_filtering,prefiltering}_requests_cnt` (atomic) - planner path taken

### Index exceptions (atomic - caught hnswlib exceptions)

- HNSW: `hnsw_{add,remove,modify,search,create}_exceptions_cnt`
- FLAT: `flat_{add,remove,modify,search,create}_exceptions_cnt`

### Thread pool (atomic)

- `worker_thread_pool_suspend_cnt` - total fork-triggered suspensions
- `{writer,reader}_worker_thread_pool_resumed_cnt` - total resumes after suspension
- `writer_worker_thread_pool_suspension_expired_cnt` - writer resumes due to `max-worker-suspension-secs` timeout (vs child-died signal)

### RDB (main thread)

`rdb_{load,save}_{success,failure}_cnt` - aux-load and aux-save outcomes.

### Coordinator (atomic)

- `coordinator_server_{get_global_metadata,search_index_partition}_{success,failure}_cnt` - server-side RPC outcomes
- `coordinator_client_{get_global_metadata,search_index_partition}_{success,failure}_cnt` - client-side RPC outcomes
- `coordinator_bytes_{out,in}` - request/response bytes across all RPCs

### FT.INTERNAL_UPDATE (atomic)

- `ft_internal_update_parse_failures_cnt` - proto deserialization failed
- `ft_internal_update_process_failures_cnt` - `CreateEntryOnReplica` failed
- `ft_internal_update_call_failures_cnt` - `ValkeyModule_Call` failed
- `process_internal_update_callback_failures_cnt` - registered callback failed
- `ft_internal_update_skipped_entries_cnt` - corrupted entries skipped during AOF load (gated by `skip-corrupted-internal-update-entries`)

### Ingestion (atomic)

- `{ingest,backfill}_{hash,json}_keys` - key ingestion counts by source and data type
- `ingest_field_{vector,numeric,tag,text}` - per-field-type counts
- `ingest_last_batch_size`, `ingest_total_batches`, `ingest_total_failures` - batch-level metrics

### Time-slice mutex (atomic)

- `time_slice_{read,write}_periods` - number of phase activations
- `time_slice_{read,write}_time` (us) - total time in each phase
- `time_slice_queries`, `time_slice_upserts`, `time_slice_deletes` - operation counts per phase

### Misc (atomic)

- `info_fanout_{retry,fail}_cnt` - cluster FT.INFO fanout outcomes
- `pause_handle_cluster_message_round_cnt` - cluster-bus message pauses (test hook)
- `text_query_{blocked,retry}_cnt` - text-query contention events
- `reclaimable_memory` (main thread) - memory recoverable by GC

## Latency samplers

`vmsdk::LatencySampler` - HdrHistogram style (1 ns .. 1 s, precision 2 -> ~40 KiB, ~1% error). Submit via `SAMPLE_EVERY_N(100)` which creates a `StopWatch` recording every 100th call. Success / failure tracked separately.

- `hnsw_vector_index_search_latency`
- `flat_vector_index_search_latency`
- Coordinator client: `{get_global_metadata,search_index_partition}_{success,failure}_latency` (4 samplers)
- Coordinator server: `{get_global_metadata,search_index_partition}_{success,failure}_latency` (4 samplers)

## RDB restore progress (atomic)

- `rdb_restore_in_progress` (bool)
- `rdb_restore_total_indexes`, `rdb_restore_completed_indexes`
- `rdb_restore_current_index_keys_total`, `_loaded`
- `rdb_restore_backpressure_wait_cycles`

Set at `PerformRDBLoad` start, cleared on completion.

## FT.INFO

`FTInfoCmd` -> `InfoCommand::ParseCommand` -> `InfoCommand::Execute`.

```cpp
struct InfoCommand {
  std::shared_ptr<IndexSchema> index_schema;
  std::string index_schema_name;
  InfoScope scope{InfoScope::kLocal};
  bool enable_partial_results;  // config default
  bool require_consistency;     // config default
  uint32_t timeout_ms{0};
};
```

Minimum syntax: `FT.INFO <index>`.

### Scopes

- **`kLocal`** - local shard only.
- **`kPrimary`** - fan out to all primaries.
- **`kCluster`** - fan out to all cluster nodes.

Cluster-mode fanout uses gRPC `InfoIndexPartition` RPCs. Fanout ops in `src/query/cluster_info_fanout_operation.h` + `src/query/primary_info_fanout_operation.h`.

### Timeouts

| Config | Default | Range |
|--------|---------|-------|
| `ft-info-timeout-ms` | 5000 | 100-300000 |
| `ft-info-rpc-timeout-ms` | 2500 | 100-300000 |

Errors -> `info_fanout_{retry,fail}_cnt`.

## `InfoIndexPartitionResponse` (gRPC)

| Field | Type | Meaning |
|-------|------|---------|
| `exists` | bool | index on this shard |
| `index_name` | string | |
| `db_num` | uint32 | |
| `num_docs` | uint64 | document count |
| `num_records` | uint64 | index records across attributes |
| `hash_indexing_failures` | uint64 | keys that failed indexing |
| `backfill_scanned_count` | uint64 | |
| `backfill_db_size` | uint64 | |
| `backfill_inqueue_tasks` | uint64 | |
| `backfill_complete_percent` | float | |
| `backfill_in_progress` | bool | |
| `mutation_queue_size` | uint64 | |
| `recent_mutations_queue_delay` | uint64 | |
| `state` | string | |
| `error` | string | |
| `error_type` | `FanoutErrorType` | |
| `attributes` | repeated `AttributeInfo` | identifier, alias, `user_indexed_memory`, `num_records` |

## FT._DEBUG

Debug-only, gated by `vmsdk::config::IsDebugModeEnabled()`. Debug off -> replies "ERR unknown command" (appears non-existent). All args logged at WARNING.

| Subcommand | Notes |
|------------|-------|
| `SHOW_INFO` | dump info variable metadata |
| `CONTROLLED_VARIABLE SET/GET/LIST` | test control variables |
| `PAUSEPOINT SET/RESET/TEST/LIST` | thread pausing for tests |
| `TEXTINFO <index> ...` | schema-level text index info |
| `STRINGPOOLSTATS` | string interning pool stats |
| `SHOW_METADATA` | `MetadataManager` table |
| `SHOW_INDEXSCHEMAS` | IndexSchema tables |
| `LIST_METRICS [APP\|DEV] [NAMES_ONLY]` | |
| `LIST_CONFIGS [VERBOSE] [APP\|DEV\|HIDDEN]` | |
| `HELP` | |

### Pausepoints

`vmsdk::debug::PausePoint("label")` at strategic locations. If SET, the calling thread blocks. Tests: TEST polls until threads are paused, RESET releases. **Never use on main thread or while holding locks.**

### Controlled variables

`CONTROLLED_BOOLEAN`, `CONTROLLED_SIZE_T` - debug-only, not replicated. Examples (coordinator): `ForceRemoteFailCount` (forces gRPC failures), `ForceIndexNotFoundError`, `PauseHandleClusterMessage`.

### `STRINGPOOLSTATS`

Four arrays: inline-string stats, out-of-line stats, by-refcount histogram, by-size histogram. Each bucket: Count, Bytes, AvgSize, Allocated, AvgAllocated, Utilization%. Also logged at NOTICE.

### `LIST_METRICS` / `LIST_CONFIGS`

- LIST_METRICS: APP vs DEV. `NAMES_ONLY` for names without values.
- LIST_CONFIGS: `VERBOSE` for detailed metadata, filters on APP / DEV / HIDDEN.
