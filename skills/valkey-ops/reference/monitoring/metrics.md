# Monitoring Metrics

Use when setting up monitoring for Valkey - understanding INFO command output,
identifying critical metrics, setting alert thresholds, and running diagnostic
commands.

Source-verified against `src/server.c` INFO output generation in
valkey-io/valkey.

## Contents

- INFO Command (line 21)
- Critical Metrics by Category (line 40)
- Derived Metrics (line 148)
- Operational Diagnostic Commands (line 163)
- APM Integrations (line 241)
- See Also (line 282)

---

## INFO Command

The INFO command returns server state organized into sections. Request all
sections or specific ones:

```bash
valkey-cli INFO              # all default sections
valkey-cli INFO ALL          # all sections including non-default
valkey-cli INFO memory       # specific section
valkey-cli INFO stats        # specific section
valkey-cli INFO replication  # specific section
```

Default sections (from `genInfoSectionDict` in `src/server.c`):
`server`, `clients`, `memory`, `persistence`, `stats`, `replication`, `cpu`,
`module_list`, `errorstats`, `cluster`, `keyspace`.

---

## Critical Metrics by Category

### Memory

Source: `INFO memory` section. Verified field names from `src/server.c` lines
6188-6248.

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `used_memory` | Total bytes allocated by Valkey's allocator | > 80% of `maxmemory` |
| `used_memory_rss` | Resident Set Size from OS (actual RAM) | RSS >> used_memory indicates fragmentation |
| `used_memory_peak` | Historical peak of `used_memory` | Capacity planning baseline |
| `used_memory_dataset` | Memory used by actual data (minus overhead) | Track growth rate |
| `mem_fragmentation_ratio` | `used_memory_rss / used_memory` | > 1.5 (high fragmentation) or < 1.0 (swapping to disk) |
| `maxmemory` | Configured memory limit | Should be set in production |
| `used_memory_overhead` | Memory for internal structures, not data | Track relative to dataset |
| `mem_replication_backlog` | Memory used by replication backlog | Sizing reference |
| `mem_clients_normal` | Memory used by client buffers | Growing trend = leak |
| `active_defrag_running` | Active defragmentation CPU percentage | 0 when idle |

### Connections

Source: `INFO clients` section. Verified from `src/server.c` lines 6134-6150.

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `connected_clients` | Current client connections (excludes replicas) | Near `maxclients` (default 10000) |
| `blocked_clients` | Clients in blocking operations (BLPOP, etc.) | Sustained growth |
| `tracking_clients` | Clients using client-side caching | Informational |
| `rejected_connections` (stats) | Total connections rejected (`maxclients` hit) | > 0 |
| `maxclients` | Configured connection limit | Should match capacity plan |
| `pubsub_clients` | Clients subscribed to Pub/Sub | Informational |

### Performance

Source: `INFO stats` section. Verified from `src/server.c` lines 6356-6423.

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `instantaneous_ops_per_sec` | Current operations per second | Sudden drops (baseline-dependent) |
| `total_commands_processed` | Cumulative command count | Rate of change |
| `keyspace_hits` | Successful key lookups | Track hit rate |
| `keyspace_misses` | Failed key lookups | Hit rate < 90% = review access patterns |
| `latest_fork_usec` | Duration of last fork (RDB/AOF) | > 500,000 (500ms) |
| `evicted_keys` | Keys removed by maxmemory policy | > 0 when unexpected |
| `evicted_clients` | Clients evicted by maxmemory-clients | > 0 |
| `expired_keys` | Keys expired by TTL | Informational |
| `expired_fields` | Hash fields expired by field-level TTL (Valkey 8+) | Informational |
| `evicted_scripts` | Scripts evicted from cache (Valkey 8+) | > 0 when unexpected |
| `io_threaded_reads_processed` | Reads handled by I/O threads | Utilization tracking |
| `io_threaded_writes_processed` | Writes handled by I/O threads | Utilization tracking |
| `io_threads_active` | Currently active I/O threads | Compare with configured count |

### Replication

Source: `INFO replication` section. Verified from `src/server.c` lines
6428-6546.

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `role` | Primary (`master`) or `slave` | Unexpected role change |
| `master_link_status` | Replication link state | != `up` |
| `master_last_io_seconds_ago` | Seconds since last I/O with primary | > 10 |
| `master_sync_in_progress` | Full sync in progress | Stuck at 1 |
| `connected_slaves` | Number of connected replicas (on primary) | < expected count |
| `master_repl_offset` | Primary's replication offset | Compare with replica offsets for lag |
| `repl_backlog_active` | Backlog buffer active | Should be 1 on primary |
| `repl_backlog_size` | Backlog buffer size | Too small = full resyncs |

### Persistence

Source: `INFO persistence` section. Verified from `src/server.c` lines
6265-6307.

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `rdb_last_bgsave_status` | Last RDB save result | != `ok` |
| `rdb_last_bgsave_time_sec` | Duration of last RDB save | Growing trend |
| `rdb_changes_since_last_save` | Unsaved writes since last RDB | Risk assessment |
| `aof_enabled` | AOF persistence active | Should match config |
| `aof_last_bgrewrite_status` | Last AOF rewrite result | != `ok` |
| `aof_last_write_status` | Last AOF write result | != `ok` |
| `aof_current_size` | Current AOF file size | Growth tracking |
| `aof_buffer_length` | Pending AOF buffer | Sustained growth = I/O bottleneck |

### Cluster

Source: `INFO cluster` section.

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `cluster_state` | Cluster health (ok/fail) | != `ok` |
| `cluster_slots_ok` | Assigned and serving slots | < 16384 |
| `cluster_slots_fail` | Slots in FAIL state | > 0 |
| `cluster_slots_pfail` | Slots in PFAIL state | > 0 (investigate) |

### Error Stats

Source: `INFO errorstats` section (Valkey 7+).

| Metric | What It Measures | Alert Threshold |
|--------|-----------------|-----------------|
| `errorstat_ERR` | Generic error count | Rate increase |
| `errorstat_OOM` | Out-of-memory errors | > 0 |
| `errorstat_LOADING` | Loading errors | > 0 during normal operation |

---

## Derived Metrics

Calculate these from raw INFO fields:

| Derived Metric | Formula | Target |
|----------------|---------|--------|
| Hit rate | `keyspace_hits / (keyspace_hits + keyspace_misses) * 100` | > 90% |
| Memory usage % | `used_memory / maxmemory * 100` | < 80% |
| Replication lag (bytes) | `master_repl_offset - slave_repl_offset` | < 1MB |
| Connection usage % | `connected_clients / maxclients * 100` | < 80% |
| Eviction rate | `delta(evicted_keys) / interval` | 0 for non-cache workloads |
| Network throughput | `delta(total_net_input_bytes) / interval` | Baseline-dependent |

---

## Operational Diagnostic Commands

### Real-time command stream

```bash
# WARNING: adds overhead, use sparingly in production
valkey-cli MONITOR
```

### Client inspection

```bash
valkey-cli CLIENT LIST              # all connected clients
valkey-cli CLIENT INFO              # current connection info
valkey-cli CLIENT GETNAME           # current connection name
valkey-cli CLIENT LIST TYPE normal  # filter by type
```

### Memory analysis

```bash
valkey-cli MEMORY USAGE <key>       # memory for a specific key (bytes)
valkey-cli MEMORY DOCTOR            # memory health report
valkey-cli MEMORY STATS             # detailed memory breakdown
```

### Commandlog (slow commands, large requests, large replies)

The commandlog supersedes the legacy SLOWLOG, adding large-request and
large-reply tracking. SLOWLOG commands remain supported as aliases for the
`slow` log type. See [Commandlog](commandlog.md) for full details.

```bash
valkey-cli COMMANDLOG GET 10 slow           # last 10 slow commands
valkey-cli COMMANDLOG GET 10 large-request  # last 10 large requests
valkey-cli COMMANDLOG GET 10 large-reply    # last 10 large replies
valkey-cli COMMANDLOG LEN slow              # entry count
valkey-cli COMMANDLOG RESET slow            # clear entries
```

Configure thresholds:

```
commandlog-execution-slower-than 10000    # microseconds (10ms default)
commandlog-request-larger-than 1048576    # bytes (1MB default)
commandlog-reply-larger-than 1048576      # bytes (1MB default)
```

### Latency diagnostics

```bash
valkey-cli LATENCY LATEST           # latest latency events by type
valkey-cli LATENCY HISTORY <event>  # historical data for an event
valkey-cli LATENCY DOCTOR           # human-readable latency analysis
valkey-cli LATENCY GRAPH <event>    # ASCII graph of latency
valkey-cli LATENCY RESET            # clear latency data
```

Enable latency monitoring:

```
CONFIG SET latency-monitor-threshold 100    # milliseconds
```

### Valkey Search metrics (v8+)

When using Valkey Search, query `INFO SEARCH` for module-specific stats:

```bash
valkey-cli INFO SEARCH
```

Key fields: `search_number_of_indexes`, `search_used_memory_bytes`,
`search_successful_requests_count`, `search_failure_requests_count`,
`search_background_indexing_status` (IN_PROGRESS or NO_ACTIVITY).

---

## APM Integrations

### Datadog

Datadog's built-in `redisdb` check works with Valkey (no dedicated Valkey
integration exists). Metric prefix: `redis.*`. Configure in
`conf.d/redisdb.d/conf.yaml`:

```yaml
instances:
  - host: localhost
    port: 6379
```

Key Datadog-specific metric names: `redis.net.clients`,
`redis.mem.fragmentation_ratio`, `redis.net.instantaneous_ops_per_sec`,
`redis.command.usec_per_call{command:<cmd>}`. Datadog also provides log
collection, APM trace integration through client libraries, and built-in
monitors for memory consumption alerts.

### New Relic

New Relic uses `nri-redis` (Community Plus maintained). Configure in
`redis-config.yml`:

```yaml
integration_name: com.newrelic.redis
instances:
  - name: redis-metrics
    command: metrics
    arguments:
      hostname: localhost
      port: 6379
```

Key NR metrics: `net.connectedClients`, `system.usedMemoryBytes`,
`system.memFragmentationRatio`, `db.keyspaceHitsPerSecond`,
`net.commandsProcessedPerSecond`.

---

## See Also

- [Prometheus Setup](prometheus.md) - exporter and scrape configuration
- [Grafana Dashboards](grafana.md) - dashboard panels and queries
- [Alerting Rules](alerting.md) - alert thresholds for key metrics
- [Commandlog](commandlog.md) - slow command, large-request, and large-reply logging
- [Performance Latency](../performance/latency.md) - latency diagnosis workflow
- [Troubleshooting Diagnostics](../troubleshooting/diagnostics.md) - 7-phase investigation runbook using INFO metrics
- [Troubleshooting Slow Commands](../troubleshooting/slow-commands.md) - slow command investigation
- [Troubleshooting OOM](../troubleshooting/oom.md) - memory alert response
- [Security ACL](../security/acl.md) - ACL LOG for access denial auditing
- [See valkey-dev: latency](../../../valkey-dev/reference/monitoring/latency.md) - latency monitor internals
