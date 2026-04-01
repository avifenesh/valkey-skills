# Metrics, FT.INFO, and FT._DEBUG

Use when working on observability, understanding the metrics system, implementing FT.INFO cluster fanout, using FT._DEBUG for diagnostics, or adding new metrics counters.

Source: `src/metrics.h`, `src/commands/ft_info.cc`, `src/commands/ft_info_parser.h`, `src/commands/ft_debug.cc`

## Contents

- Metrics Singleton (line 19)
- Counter Categories (line 29)
- Latency Samplers (line 87)
- RDB Restore Progress (line 107)
- FT.INFO Command (line 119)
- FT.INFO Scopes and Fanout (line 138)
- InfoIndexPartition Response (line 154)
- FT._DEBUG Command (line 180)
- FT._DEBUG Subcommands (line 184)

## Metrics Singleton

`Metrics` is a singleton class with a nested `Stats` struct holding all counters and latency samplers. Access is via:

```cpp
Metrics::GetStats().some_counter++;
```

The singleton uses the Meyers pattern (`static Metrics instance` in `GetInstance()`). The `Stats` struct is mutable, allowing modification through the const singleton reference. This is safe because individual counters use `std::atomic` for thread-safe access from background threads, while non-atomic counters are accessed only from the main thread.

## Counter Categories

### Query Counters (main thread unless noted)
- `query_successful_requests_cnt` / `query_failed_requests_cnt` - total query outcomes
- `query_result_record_dropped_cnt` - records dropped during query processing
- `query_hybrid_requests_cnt` - hybrid (vector + filter) queries
- `query_nonvector_requests_cnt` (atomic) - pure non-vector queries
- `query_vector_requests_cnt` (atomic) - pure vector queries
- `query_text_requests_cnt` (atomic) - full-text queries
- `query_inline_filtering_requests_cnt` (atomic) - inline filter path
- `query_prefiltering_requests_cnt` (atomic) - prefilter path

### Index Exception Counters (all atomic)
HNSW: `hnsw_add_exceptions_cnt`, `hnsw_remove_exceptions_cnt`, `hnsw_modify_exceptions_cnt`, `hnsw_search_exceptions_cnt`, `hnsw_create_exceptions_cnt`

FLAT: `flat_add_exceptions_cnt`, `flat_remove_exceptions_cnt`, `flat_modify_exceptions_cnt`, `flat_search_exceptions_cnt`, `flat_create_exceptions_cnt`

### Thread Pool Counters (all atomic)
- `worker_thread_pool_suspend_cnt` - total suspensions (fork protection)
- `writer_worker_thread_pool_resumed_cnt` / `reader_worker_thread_pool_resumed_cnt`
- `writer_worker_thread_pool_suspension_expired_cnt`

### RDB Counters (main thread)
- `rdb_load_success_cnt` / `rdb_load_failure_cnt`
- `rdb_save_success_cnt` / `rdb_save_failure_cnt`

### Coordinator Counters (all atomic)
Server-side: `coordinator_server_get_global_metadata_success_cnt` / `_failure_cnt`, `coordinator_server_search_index_partition_success_cnt` / `_failure_cnt`

Client-side: `coordinator_client_get_global_metadata_success_cnt` / `_failure_cnt`, `coordinator_client_search_index_partition_success_cnt` / `_failure_cnt`

Bandwidth: `coordinator_bytes_out`, `coordinator_bytes_in`

### FT.INTERNAL_UPDATE Counters (all atomic)
- `ft_internal_update_parse_failures_cnt` - protobuf deserialization failures
- `ft_internal_update_process_failures_cnt` - CreateEntryOnReplica failures
- `ft_internal_update_call_failures_cnt` - ValkeyModule_Call failures
- `process_internal_update_callback_failures_cnt` - callback invocation failures
- `ft_internal_update_skipped_entries_cnt` - corrupted entries skipped during AOF load

### Ingestion Counters (all atomic)
- `ingest_hash_keys` / `backfill_hash_keys` - HASH key ingestion
- `ingest_json_keys` / `backfill_json_keys` - JSON key ingestion
- `ingest_field_vector` / `ingest_field_numeric` / `ingest_field_tag` / `ingest_field_text` - per-field-type counts
- `ingest_last_batch_size` / `ingest_total_batches` / `ingest_total_failures`

### Time Slice Mutex Counters (all atomic)
- `time_slice_read_periods` / `time_slice_read_time` (microseconds)
- `time_slice_queries`
- `time_slice_write_periods` / `time_slice_write_time` (microseconds)
- `time_slice_upserts` / `time_slice_deletes`

### Miscellaneous (all atomic)
- `info_fanout_retry_cnt` / `info_fanout_fail_cnt`
- `pause_handle_cluster_message_round_cnt`
- `text_query_blocked_cnt` / `text_query_retry_cnt`
- `reclaimable_memory` (main thread)

## Latency Samplers

Latency samplers use `vmsdk::LatencySampler` with HdrHistogram-style recording (1 nanosecond to 1 second range, precision 2 - correlating to ~40KiB memory and ~1% error).

Samplers are submitted via `SAMPLE_EVERY_N(100)` which creates a `StopWatch` that records every 100th call. Each sampler tracks percentiles internally.

Index search latency:
- `hnsw_vector_index_search_latency`
- `flat_vector_index_search_latency`

Coordinator client latency (4 samplers):
- `coordinator_client_get_global_metadata_success_latency` / `_failure_latency`
- `coordinator_client_search_index_partition_success_latency` / `_failure_latency`

Coordinator server latency (4 samplers):
- `coordinator_server_get_global_metadata_success_latency` / `_failure_latency`
- `coordinator_server_search_index_partition_success_latency` / `_failure_latency`

Success and failure latencies are tracked separately to distinguish healthy request times from error-path times.

## RDB Restore Progress

Atomic progress counters enable monitoring of RDB load progress:

- `rdb_restore_in_progress` (atomic bool) - true during `PerformRDBLoad`
- `rdb_restore_total_indexes` - total section count from RDB header
- `rdb_restore_completed_indexes` - incremented per completed section
- `rdb_restore_current_index_keys_total` / `rdb_restore_current_index_keys_loaded` - per-index key progress
- `rdb_restore_backpressure_wait_cycles` - backpressure events during restore

These counters are set at the start of `PerformRDBLoad` and cleared when loading completes. They allow external monitoring tools (and FT.INFO) to report restore progress.

## FT.INFO Command

`FTInfoCmd` in `ft_info.cc` parses the command via `InfoCommand::ParseCommand` and executes via `InfoCommand::Execute`.

The `InfoCommand` struct (`ft_info_parser.h`):

```cpp
struct InfoCommand {
  std::shared_ptr<IndexSchema> index_schema;
  std::string index_schema_name;
  InfoScope scope{InfoScope::kLocal};
  bool enable_partial_results;  // default from config
  bool require_consistency;     // default from config
  uint32_t timeout_ms{0};
};
```

The command supports at minimum `FT.INFO <index_name>`. Additional options control scope, consistency, and timeouts.

## FT.INFO Scopes and Fanout

Three scopes defined in `InfoScope`:

- **kLocal** - query only the local shard's IndexSchema
- **kPrimary** - fan out to all primary nodes (cluster mode)
- **kCluster** - fan out to all cluster nodes

In cluster mode, `FT.INFO` fans out via gRPC `InfoIndexPartition` RPCs. The response aggregates data from all shards. Fanout operations are implemented in `src/query/cluster_info_fanout_operation.h` and `src/query/primary_info_fanout_operation.h`.

Configurable timeouts:
- `ft-info-timeout-ms` - overall FT.INFO timeout (default 5000ms, range 100-300000ms)
- `ft-info-rpc-timeout-ms` - per-RPC timeout (default 2500ms, range 100-300000ms)

Fanout error handling is tracked via `info_fanout_retry_cnt` and `info_fanout_fail_cnt` in Metrics.

## InfoIndexPartition Response

The gRPC `InfoIndexPartitionResponse` carries per-shard data:

| Field | Type | Description |
|-------|------|-------------|
| `exists` | bool | Whether the index exists on this shard |
| `index_name` | string | Index name |
| `db_num` | uint32 | Database number |
| `num_docs` | uint64 | Document count |
| `num_records` | uint64 | Total index records across all attributes |
| `hash_indexing_failures` | uint64 | Keys that failed indexing |
| `backfill_scanned_count` | uint64 | Keys scanned during backfill |
| `backfill_db_size` | uint64 | Total DB size for backfill |
| `backfill_inqueue_tasks` | uint64 | Pending backfill tasks |
| `backfill_complete_percent` | float | Backfill completion percentage |
| `backfill_in_progress` | bool | Whether backfill is active |
| `mutation_queue_size` | uint64 | Pending mutations |
| `recent_mutations_queue_delay` | uint64 | Queue processing delay |
| `state` | string | Index state |
| `error` | string | Error description if any |
| `error_type` | FanoutErrorType | Error classification |
| `attributes` | repeated AttributeInfo | Per-attribute details |

Each `AttributeInfo` contains identifier, alias, `user_indexed_memory`, and `num_records`.

## FT._DEBUG Command

`FTDebugCmd` is a debug-only command gated by `vmsdk::config::IsDebugModeEnabled()`. When debug mode is off, it replies with "ERR unknown command" to appear non-existent. All arguments are logged at WARNING level.

## FT._DEBUG Subcommands

| Subcommand | Syntax | Description |
|------------|--------|-------------|
| `SHOW_INFO` | `FT._DEBUG SHOW_INFO` | Dump info variable metadata |
| `CONTROLLED_VARIABLE SET` | `FT._DEBUG CONTROLLED_VARIABLE SET <name> <value>` | Set a test control variable |
| `CONTROLLED_VARIABLE GET` | `FT._DEBUG CONTROLLED_VARIABLE GET <name>` | Get a test control variable |
| `CONTROLLED_VARIABLE LIST` | `FT._DEBUG CONTROLLED_VARIABLE LIST` | List all controlled variables |
| `PAUSEPOINT SET` | `FT._DEBUG PAUSEPOINT SET <name>` | Enable a named pausepoint |
| `PAUSEPOINT RESET` | `FT._DEBUG PAUSEPOINT RESET <name>` | Release threads paused at this point |
| `PAUSEPOINT TEST` | `FT._DEBUG PAUSEPOINT TEST <name>` | Return count of threads waiting |
| `PAUSEPOINT LIST` | `FT._DEBUG PAUSEPOINT LIST` | List all pausepoints |
| `TEXTINFO` | `FT._DEBUG TEXTINFO <index> ...` | Schema-level text index info |
| `STRINGPOOLSTATS` | `FT._DEBUG STRINGPOOLSTATS` | String interning pool statistics |
| `SHOW_METADATA` | `FT._DEBUG SHOW_METADATA` | Dump MetadataManager table |
| `SHOW_INDEXSCHEMAS` | `FT._DEBUG SHOW_INDEXSCHEMAS` | Dump IndexSchema tables |
| `LIST_METRICS` | `FT._DEBUG LIST_METRICS [APP\|DEV] [NAMES_ONLY]` | List app or dev metrics |
| `LIST_CONFIGS` | `FT._DEBUG LIST_CONFIGS [VERBOSE] [APP\|DEV\|HIDDEN]` | List config entries |
| `HELP` | `FT._DEBUG HELP` | Show available subcommands |

**Pausepoints** are a testing mechanism. Background threads call `vmsdk::debug::PausePoint("label")` at strategic locations. If a pausepoint is SET, the calling thread blocks. Tests use TEST to poll until threads are paused, then RESET to release them. Pausepoints must not be used on the main thread or while holding locks.

**Controlled Variables** (`CONTROLLED_BOOLEAN`, `CONTROLLED_SIZE_T`) are debug-only config values used in test code. Examples in the coordinator: `ForceRemoteFailCount` forces gRPC failures, `ForceIndexNotFoundError` simulates missing indexes, `PauseHandleClusterMessage` delays cluster message processing. These are not replicated.

**STRINGPOOLSTATS** returns 4 arrays: inline string stats, out-of-line string stats, by-refcount histogram, and by-size histogram. Each bucket reports Count, Bytes, AvgSize, Allocated, AvgAllocated, and Utilization percentage. Results are also logged at NOTICE level.

**LIST_METRICS** distinguishes APP (user-facing) and DEV (internal) metrics. The optional NAMES_ONLY flag returns only metric names without values.

**LIST_CONFIGS** supports VERBOSE mode (detailed metadata per config) and filtering by APP, DEV, or HIDDEN visibility categories.
