# Monitoring

Use when wiring `INFO` into dashboards/alerts, picking an exporter, or investigating with COMMANDLOG. Redis-standard diagnostics (`MONITOR`, `CLIENT LIST`, `MEMORY USAGE/DOCTOR/STATS`, `LATENCY LATEST/HISTORY/DOCTOR`) work identically.

## INFO sections

`valkey-cli INFO` returns default sections; `INFO ALL` adds non-default (`commandstats`, `latencystats`, `tls`, `clients_statistics`, `search` from valkey-search). Single section: `INFO memory`, `INFO stats`, etc.

## Memory (`INFO memory`)

| Field | Alert threshold | Meaning |
|-------|-----------------|---------|
| `used_memory` | > 80% of `maxmemory` | Allocator's view. |
| `used_memory_rss` | RSS >> used_memory | Fragmentation. |
| `mem_fragmentation_ratio` | > 1.5 or < 1.0 | Normal 1.0-1.5. <1.0 means swapping. |
| `used_memory_peak` | - | Historical peak - capacity-planning baseline. |
| `mem_not_counted_for_evict` | sustained growth | Replication buffers not counted against maxmemory (replica COB + repl backlog). |
| `mem_clients_normal` / `mem_clients_slaves` | growing | Client-buffer or replica-buffer backlog. |
| `active_defrag_running` | > 0 active | CPU % used by defrag this cycle. |

## Connections (`INFO clients`)

`connected_clients`, `blocked_clients`, `tracking_clients`, `pubsub_clients`, `maxclients`, `rejected_connections` (in stats). Alert when `rejected_connections` rate > 0 or `connected_clients / maxclients > 0.8`.

## Stats (`INFO stats`) - Valkey additions

Beyond Redis baseline (`total_commands_processed`, `keyspace_hits/misses`, `evicted_keys`, `expired_keys`, `latest_fork_usec`, `instantaneous_ops_per_sec`):

| Field | Since | Meaning |
|-------|-------|---------|
| `evicted_clients` | 7.0 | Evicted by `maxmemory-clients`. >0 = client-buffer pressure. |
| `evicted_scripts` | Valkey 8+ | Lua scripts evicted from the 500-entry LRU cache. Ramp = thrashing. |
| `expired_fields` | Valkey 9.0 | Hash fields reclaimed by per-field TTL (distinct from `expired_keys`). |
| `io_threaded_reads_processed` / `io_threaded_writes_processed` | 8+ | I/O thread utilization. |
| `io_threads_active` | 8+ | Current active worker count from `adjustIOThreadsByEventLoad`. Below `io-threads - 1` = some workers parked. |
| `io_threaded_total_prefetch_batches` / `_entries` | 9.0 | Batch prefetch activity. |
| `tracking_total_keys` | 6.0 | Current tracked-key count. Approaching `tracking-table-max-keys` = spurious invalidations incoming. |
| `tracking_total_items` / `tracking_total_prefixes` | 6.0 | BCAST / per-prefix scope. |

## Replication (`INFO replication`)

`role`, `master_link_status`, `master_last_io_seconds_ago`, `master_sync_in_progress`, `connected_slaves`, `master_repl_offset`, `slave_repl_offset`, `repl_backlog_active`, `repl_backlog_size`, `repl_backlog_first_byte_offset`, `repl_backlog_histlen`. Alert on `master_link_status != up`, `master_last_io_seconds_ago > 10`, `master_repl_offset - slave_repl_offset > 1MB`.

Dual-channel adds replica-side `pending_repl_data_len` for back-pressure monitoring.

## Persistence (`INFO persistence`)

`rdb_last_bgsave_status`, `rdb_last_bgsave_time_sec`, `rdb_changes_since_last_save`, `aof_enabled`, `aof_last_bgrewrite_status`, `aof_last_write_status`, `aof_current_size`, `aof_buffer_length`. Alert on any `_status != ok`.

## Cluster (`CLUSTER INFO`)

`cluster_state`, `cluster_slots_assigned` (should be 16384), `cluster_slots_ok`, `cluster_slots_pfail`, `cluster_slots_fail`. Message-level counters in `cluster_stats_messages_*_sent` / `_received` (per message type). Byte-level cluster-bus counters (`cluster_stats_bytes_*` / pubsub / module slices) are unstable-only; not on 9.0.x.

## Error stats (`INFO errorstats`)

`errorstat_<ERRCODE>` counters: `ERR`, `OOM`, `LOADING`, `MASTERDOWN`, `CROSSSLOT`, `MOVED`, `ASK`, `BUSY`, `BUSYGROUP`, `NOAUTH`, `WRONGPASS`. Rate-of-change alerts are more useful than absolute thresholds.

## TLS (`INFO tls`)

Standard `tls_*` counters (`tls_connections_to_timeout`, `tls_accepted_tls`, `tls_rejected_connections`). Cert expiry INFO telemetry (`tls_*_cert_expire_time`, `tls_*_serial`) and in-place `tls-auto-reload-interval` are unstable-only; on 9.0.x, track cert expiry out-of-band and rotate via restart or failover.

## Derived metrics

- Hit rate: `keyspace_hits / (keyspace_hits + keyspace_misses)` - target >90% on cache.
- Memory pressure: `used_memory / maxmemory`.
- Replication lag (bytes): `master_repl_offset - <replica's reported offset>`.
- Eviction rate: `delta(evicted_keys) / interval` - ~0 for non-cache.
- Connection saturation: `connected_clients / maxclients`.

## Module-specific INFO

valkey-search exposes `INFO SEARCH` (`search_number_of_indexes`, `search_used_memory_bytes`, `search_successful_requests_count`, `search_failure_requests_count`, `search_background_indexing_status`). Similar pattern for valkey-bloom (`INFO BLOOM`) and valkey-json (`INFO JSON`). Query only on nodes loading those modules.

## Prometheus exporter

`oliver006/redis_exporter` is de-facto for Valkey. Keeps `redis_*` metric prefix for Grafana/alert-rule compat. Valkey-specific:

- Accepts `valkey://` and `valkeys://` URI schemes alongside `redis://` / `rediss://`.
- Cluster discovery endpoint `/discover-cluster-nodes` when started with `--is-cluster`. Use with Prometheus `http_sd_configs`.
- `--exclude-latency-histogram-metrics`: set on Valkey < 7 only; 7.x+ populates `LATENCY HISTOGRAM` and it's scraped by default.

### Valkey-only metrics surfaced

| Metric | Source INFO field |
|--------|-------------------|
| `redis_expired_subkeys_total` | `expired_fields` |
| `redis_evicted_scripts_total` | `evicted_scripts` |
| `redis_io_threads_active` | `io_threads_active` |

Alert-worthy: `redis_expired_subkeys_total` jumps reveal unexpected hash-field TTL churn; `redis_io_threads_active` below `io-threads - 1` means `adjustIOThreadsByEventLoad` parked a worker.

### Minimal ACL for the exporter

```
ACL SETUSER exporter on >pw \
    +info +ping +config|get +client|list \
    +commandlog|get +commandlog|len \
    +latency|latest +latency|history
```

`+slowlog|*` still works as an alias for `+commandlog|slow-*`.

### Cluster-aware scraping

```yaml
scrape_configs:
  - job_name: valkey-cluster
    http_sd_configs:
      - url: http://exporter-host:9121/discover-cluster-nodes
        refresh_interval: 10m
    metrics_path: /scrape
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: exporter-host:9121
```

Multi-target model - one exporter handles all nodes. Works with atomic slot migration: moved slots appear on the target's next scrape without exporter reconfiguration.

## Grafana

All `redis_*`-prefixed community dashboards work with Valkey.

| Dashboard ID | Name |
|-------------|------|
| 763 | Redis Dashboard for Prometheus Redis Exporter 1.x (canonical) |
| 14091 | Redis Overview |
| 12776 | Redis Cluster Overview |

Percona PMM ships dedicated Valkey-named dashboards in `percona/grafana-dashboards` under `dashboards/Valkey/` - the only ones with Valkey-specific naming.

## Recording rules (`valkey:` prefix)

Distinguishes Valkey from Redis instances when both exist:

```yaml
groups:
  - name: valkey-recording
    rules:
      - record: valkey:memory_fragmentation_ratio
        expr: redis_memory_used_rss_bytes / redis_memory_used_bytes
      - record: valkey:hit_rate
        expr: rate(redis_keyspace_hits_total[5m]) / (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
      - record: valkey:memory_utilization
        expr: redis_memory_used_bytes / redis_memory_max_bytes
```

## Alerting

Key categories (expressions use `redis_*` prefix):

- Availability: `redis_up == 0`
- Memory: `redis_memory_used_bytes / redis_memory_max_bytes > 0.9`
- Replication: `redis_master_link_up == 0`, `redis_connected_slaves < 1`
- Persistence: `redis_rdb_last_bgsave_status == 0`, `redis_aof_last_bgrewrite_status == 0`
- Cluster: `redis_cluster_state == 0`, `redis_cluster_slots_fail > 0`

Use `Valkey`-prefixed alert names for Alertmanager routing even though metric names use `redis_`:

```yaml
- alert: ValkeyDown
  expr: redis_up == 0
```

```yaml
route:
  routes:
    - match_re:
        alertname: "^Valkey.*"
      receiver: valkey-team
```

Community alert sources: `samber/awesome-prometheus-alerts` (`dist/rules/redis/`), `oliver006/redis_exporter/contrib/redis-mixin/` (Jsonnet).

## COMMANDLOG (replaces SLOWLOG)

Three logs in one command family:

| Type | Tracks | Threshold unit |
|------|-------|----------------|
| `slow` | Command execution time | microseconds |
| `large-request` | Inbound argv bytes | bytes |
| `large-reply` | Outbound reply bytes | bytes |

Internal constants: `COMMANDLOG_TYPE_SLOW=0`, `COMMANDLOG_TYPE_LARGE_REQUEST=1`, `COMMANDLOG_TYPE_LARGE_REPLY=2`. `SLOWLOG *` works as alias for `slow` only.

### Config

| Parameter | Default | Redis alias (for `slow` only) |
|-----------|---------|-------------------------------|
| `commandlog-execution-slower-than` | `10000` µs | `slowlog-log-slower-than` |
| `commandlog-slow-execution-max-len` | `128` | `slowlog-max-len` |
| `commandlog-request-larger-than` | `1048576` B | - |
| `commandlog-large-request-max-len` | `128` | - |
| `commandlog-reply-larger-than` | `1048576` B | - |
| `commandlog-large-reply-max-len` | `128` | - |

`-1` threshold or `0` max-len disables that type.

### Commands

```
COMMANDLOG GET <count> <type>          # count=-1 for all; type = slow | large-request | large-reply
COMMANDLOG LEN <type>
COMMANDLOG RESET <type>
SLOWLOG GET/LEN/RESET [count]          # alias - slow type only
```

Entry shape: `[id, timestamp, value, arguments[], peerid, cname]`. `value` is duration (slow) or bytes (large-*). Arguments truncated to `COMMANDLOG_ENTRY_MAX_ARGC=32` slots, each capped at `COMMANDLOG_ENTRY_MAX_STRING=128` bytes - excess becomes `... (N more)`.

Cluster mode: all three subcommands carry `REQUEST_POLICY:ALL_NODES`; `LEN` additionally has `RESPONSE_POLICY:AGG_SUM` so cluster-aware clients fan-out and merge. Aggregated IDs are not globally unique.

### Argv edge cases

- **Rewritten commands**: if the server rewrote `c->argv` (e.g., `SET ... EX` internally), the entry captures `c->original_argv` - what the client sent, not what executed.
- **Script execution**: `value` from executing-client counters; `peerid`/`cname` from `scriptGetCaller()`. Lua entries show caller identity, not script engine's.
- **Redaction**: `redactClientCommandArgument` eagerly copies `c->argv` into `c->original_argv` and writes `shared.redacted` into the redacted slot. Commandlog records from `original_argv` so the masked value is what gets logged. (The lazy-bitmap redaction model is unstable-only.)
- **Command-level skip**: commands with `CMD_SKIP_COMMANDLOG` (AUTH, HELLO, etc.) don't enter any of the three logs.

### Exporter reality

`redis_exporter` exposes only the slow log today (as `redis_slowlog_length`, `redis_slowlog_last_id`) because it calls `SLOWLOG GET`. For `large-request` / `large-reply`, call `COMMANDLOG LEN large-request` / `large-reply` from a custom scrape agent until exporter catches up.

### Investigation workflow

Tighten thresholds during an incident, restore after:

```
CONFIG SET commandlog-execution-slower-than 1000       # 1ms
CONFIG SET commandlog-reply-larger-than 65536          # 64KB
CONFIG SET commandlog-slow-execution-max-len 1024
```

When done, restore to defaults (`10000` / `1048576` / `128`).
