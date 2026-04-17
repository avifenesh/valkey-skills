# Monitoring Metrics

Use when wiring `INFO` fields into alerts/dashboards. Redis-standard diagnostic commands (`MONITOR`, `CLIENT LIST`, `MEMORY USAGE/DOCTOR/STATS`, `LATENCY LATEST/HISTORY/DOCTOR`) work identically; this file focuses on the metric catalog and Valkey-specific additions.

## INFO sections

`valkey-cli INFO` returns default sections; `INFO ALL` adds non-default (`commandstats`, `latencystats`, `tls`, `clients_statistics`, `search` from the valkey-search module). Request a single section with `INFO memory`, `INFO stats`, etc.

## Memory (`INFO memory`)

| Field | Alert threshold | Meaning |
|-------|-----------------|---------|
| `used_memory` | > 80% of `maxmemory` | Allocator's view of used bytes. |
| `used_memory_rss` | RSS >> used_memory | Fragmentation. |
| `mem_fragmentation_ratio` | > 1.5 or < 1.0 | Normal is 1.0-1.5. <1.0 means swapping. |
| `used_memory_peak` | - | Historical peak - capacity-planning baseline. |
| `mem_not_counted_for_evict` | sustained growth | Replication buffers not counted against maxmemory. Includes replica COB + repl backlog. |
| `mem_clients_normal` / `mem_clients_slaves` | growing trend | Client-buffer or replica-buffer backlog. |
| `active_defrag_running` | `> 0` means active | CPU % used by defrag this cycle. |

## Connections (`INFO clients`)

`connected_clients`, `blocked_clients`, `tracking_clients`, `pubsub_clients`, `maxclients`, `rejected_connections` (in stats). Alert when `rejected_connections` rate > 0 (you hit `maxclients`) or `connected_clients / maxclients > 0.8`.

## Stats (`INFO stats`) - Valkey additions

Beyond the Redis-baseline counters (`total_commands_processed`, `keyspace_hits/misses`, `evicted_keys`, `expired_keys`, `latest_fork_usec`, `instantaneous_ops_per_sec`):

| Field | Since | Meaning |
|-------|-------|---------|
| `evicted_clients` | 7.0 | Evicted by `maxmemory-clients`. > 0 = client-buffer pressure. |
| `evicted_scripts` | Valkey 8+ | Lua scripts evicted from the 500-entry LRU cache. Ramp = thrashing. |
| `expired_fields` | Valkey 9.0 | Hash fields reclaimed by per-field TTL (distinct from `expired_keys`). |
| `io_threaded_reads_processed` / `io_threaded_writes_processed` | 8+ | I/O thread utilization. |
| `io_threads_active` | 8+ | Current active count under Ignition/Cooldown. Below `io-threads - 1` = policy demoted workers. |
| `io_threaded_total_prefetch_batches` / `_entries` | 9.0 | Batch prefetch activity. Backed by `server.stat_total_prefetch_batches`/`_entries`. |
| `tracking_total_keys` | 6.0 | Current tracked-key count. Approaching `tracking-table-max-keys` = spurious invalidations incoming. |
| `tracking_total_items` / `tracking_total_prefixes` | 6.0 | BCAST / per-prefix scope. |

## Replication (`INFO replication`)

`role`, `master_link_status`, `master_last_io_seconds_ago`, `master_sync_in_progress`, `connected_slaves`, `master_repl_offset`, `slave_repl_offset`, `repl_backlog_active`, `repl_backlog_size`, `repl_backlog_first_byte_offset`, `repl_backlog_histlen`. Alert on `master_link_status != up`, `master_last_io_seconds_ago > 10`, or `master_repl_offset - slave_repl_offset > 1MB`.

Valkey 9.0 addition: dual-channel replication exposes `master_replid2` + `second_repl_offset` (same as Redis 7.0) plus replica-side `pending_repl_data_len` for back-pressure monitoring.

## Persistence (`INFO persistence`)

`rdb_last_bgsave_status`, `rdb_last_bgsave_time_sec`, `rdb_changes_since_last_save`, `aof_enabled`, `aof_last_bgrewrite_status`, `aof_last_write_status`, `aof_current_size`, `aof_buffer_length`. Alert on any `_status != ok`.

## Cluster (`INFO cluster` / `CLUSTER INFO`)

`cluster_state`, `cluster_slots_assigned` (should be 16384), `cluster_slots_ok`, `cluster_slots_pfail`, `cluster_slots_fail`. Valkey 9.0 additions exposed in `CLUSTER INFO`:

| Field | Meaning |
|-------|---------|
| `cluster_stats_bytes_sent` / `_received` | Cumulative cluster-bus traffic in bytes. |
| `cluster_stats_pubsub_bytes_sent` / `_received` | Pub/sub slice of above. |
| `cluster_stats_module_bytes_sent` / `_received` | Module-message slice. |

Watch the pub/sub slice - disproportionate growth means shard pub/sub is being routed as global, which is a config error (`cluster-allow-pubsubshard-when-down` interaction).

## Error stats (`INFO errorstats`)

`errorstat_<ERRCODE>` counters per error class: `ERR`, `OOM`, `LOADING`, `MASTERDOWN`, `CROSSSLOT`, `MOVED`, `ASK`, `BUSY`, `BUSYGROUP`, `NOAUTH`, `WRONGPASS`. Rate-of-change alerts are more useful than absolute thresholds.

## TLS (`INFO tls`)

Valkey-specific telemetry (not in Redis):

| Field | Meaning |
|-------|---------|
| `tls_server_cert_expire_time` | Unix seconds until server cert expires. |
| `tls_client_cert_expire_time` | Same for outbound cert. |
| `tls_ca_cert_expire_time` | CA expiry. |
| `tls_*_serial` | Current cert serial - alerts to detect unexpected cert rotations. |

Scrape all three expire_time fields; alert at 30 days remaining, page at 7 days.

## Derived metrics worth computing

- Hit rate: `keyspace_hits / (keyspace_hits + keyspace_misses)` - target > 90% on cache workloads.
- Memory pressure: `used_memory / maxmemory`.
- Replication lag (bytes): `master_repl_offset - <replica's reported offset>`.
- Eviction rate: `delta(evicted_keys) / interval` - should be ~0 for non-cache workloads.
- Connection saturation: `connected_clients / maxclients`.

## Module-specific INFO sections

valkey-search exposes `INFO SEARCH`: `search_number_of_indexes`, `search_used_memory_bytes`, `search_successful_requests_count`, `search_failure_requests_count`, `search_background_indexing_status` (IN_PROGRESS or NO_ACTIVITY). Similar pattern for valkey-bloom (`INFO BLOOM`) and valkey-json (`INFO JSON`). Query the sections only on nodes loading those modules.
