Use when configuring Grafana dashboards for Valkey monitoring - importing

# Grafana Dashboard Setup
community dashboards, configuring data sources, and building key panels.

## Contents

- Prerequisites (line 20)
- Data Source Configuration (line 27)
- Community Dashboards (line 38)
- Key Panels to Configure (line 67)
- Dashboard Variables (line 147)
- Dashboard JSON Export (line 164)
- Grafana Provisioning (line 177)
- Percona PMM Dashboards (line 200)
- See Also (line 232)

---

## Prerequisites

- Prometheus scraping Valkey exporter (see [Prometheus Setup](prometheus.md))
- Grafana 9.x or later with Prometheus data source configured

---

## Data Source Configuration

Add Prometheus as a data source in Grafana:

1. Navigate to Configuration -> Data Sources -> Add data source
2. Select Prometheus
3. Set the URL to your Prometheus server (e.g., `http://prometheus:9090`)
4. Click Save & Test

---

## Community Dashboards

Import pre-built dashboards from Grafana.com by Dashboard ID:

| Dashboard ID | Name | Best For |
|-------------|------|----------|
| 763 | Redis Dashboard for Prometheus Redis Exporter 1.x | Official (maintained by oliver006), general-purpose |
| 14091 | Redis Overview | Compact single-pane overview |
| 11835 | Redis Dashboard for Prometheus Redis Exporter | Community variant |
| 12776 | Redis Cluster Overview | Cluster-specific panels |

Dashboard 763 is the canonical choice - it ships with the exporter source
(`contrib/grafana_prometheus_redis_dashboard.json`). It supports multi-value
instance dropdowns for Sentinel environments. Single-stat panels
(uptime, total memory, clients) do not aggregate across multiple instances.

### Import steps

1. Navigate to Dashboards -> Import
2. Enter the Dashboard ID (e.g., `763`)
3. Click Load
4. Select the Prometheus data source
5. Click Import

After import, adjust variables (instance selector, refresh interval) to match
your deployment.

---

## Key Panels to Configure

If building a custom dashboard or augmenting an imported one, include these
panels organized by category.

### Overview row

| Panel | Query | Visualization |
|-------|-------|---------------|
| Uptime | `redis_uptime_in_seconds` | Stat |
| Connected clients | `redis_connected_clients` | Stat |
| Ops/sec | `redis_instantaneous_ops_per_sec` | Stat |
| Memory usage | `redis_memory_used_bytes / redis_memory_max_bytes * 100` | Gauge (0-100%) |
| Instance status | `redis_up` | Stat (1=up, 0=down) |

### Memory row

| Panel | Query | Visualization |
|-------|-------|---------------|
| Memory used vs max | `redis_memory_used_bytes` and `redis_memory_max_bytes` on same graph | Time series |
| RSS vs allocated | `redis_memory_used_rss_bytes` and `redis_memory_used_bytes` | Time series |
| Fragmentation ratio | `redis_mem_fragmentation_ratio` | Time series (thresholds: green < 1.2, yellow < 1.5, red >= 1.5) |
| Evicted keys rate | `rate(redis_evicted_keys_total[5m])` | Time series |

### Connections row

| Panel | Query | Visualization |
|-------|-------|---------------|
| Connected clients | `redis_connected_clients` | Time series |
| Blocked clients | `redis_blocked_clients` | Time series |
| Rejected connections | `rate(redis_rejected_connections_total[5m])` | Time series |
| Connection rate | `rate(redis_connections_received_total[5m])` | Time series |

### Performance row

| Panel | Query | Visualization |
|-------|-------|---------------|
| Operations/sec | `redis_instantaneous_ops_per_sec` | Time series |
| Hit rate | `rate(redis_keyspace_hits_total[5m]) / (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m])) * 100` | Time series (%) |
| Command latency | `rate(redis_commands_duration_seconds_total[5m]) / rate(redis_commands_processed_total[5m])` | Time series |
| Fork duration | `redis_latest_fork_usec / 1e6` | Time series (seconds) |

### Replication row

| Panel | Query | Visualization |
|-------|-------|---------------|
| Replication lag (bytes) | `redis_master_repl_offset - on(instance) redis_slave_repl_offset` | Time series |
| Connected replicas | `redis_connected_slaves` | Stat |
| Replication link status | `redis_master_link_up` | Stat (1=up, 0=down) |

### Persistence row

| Panel | Query | Visualization |
|-------|-------|---------------|
| RDB save duration | `redis_rdb_last_bgsave_duration_sec` | Time series |
| RDB save status | `redis_rdb_last_bgsave_status` | Stat (1=ok, 0=err) |
| AOF rewrite status | `redis_aof_last_bgrewrite_status` | Stat |
| Changes since save | `redis_rdb_changes_since_last_save` | Time series |
| Time since last save | `time() - redis_rdb_last_save_timestamp_seconds` | Stat (seconds) |
| AOF pending fsyncs | `redis_aof_pending_bio_fsync` | Time series |

### Command latency row (requires latencystats, Valkey 7+)

| Panel | Query | Visualization |
|-------|-------|---------------|
| Top 5 by p99.9 | `topk(5, avg_over_time(redis_latency_percentiles_usec{quantile="99.9"}[10s]))` | Bar gauge |
| Per-command time/sec | `sum by(cmd) (irate(redis_commands_duration_seconds_total[1m]))` | Time series |
| Top 10 by CPU time | `topk(10, sum by(cmd) (redis_commands_duration_seconds_total) != 0)` | Table |
| Network I/O | `irate(redis_net_input_bytes_total[5m])` and `irate(redis_net_output_bytes_total[5m])` | Time series |

### Cluster row (cluster mode only)

| Panel | Query | Visualization |
|-------|-------|---------------|
| Cluster state | `redis_cluster_state` | Stat (1=ok, 0=fail) |
| Slots ok/fail/pfail | `redis_cluster_slots_ok`, `redis_cluster_slots_fail`, `redis_cluster_slots_pfail` | Stat |
| Cluster message rate | `rate(redis_cluster_messages_sent_total[5m])` | Time series |

---

## Dashboard Variables

Configure these template variables for multi-instance deployments:

| Variable | Type | Query | Description |
|----------|------|-------|-------------|
| `$instance` | Query | `label_values(redis_up, instance)` | Valkey instance selector |
| `$job` | Query | `label_values(redis_up, job)` | Prometheus job name |

Apply `$instance` filter to all panels:

```
redis_connected_clients{instance=~"$instance"}
```

---

## Dashboard JSON Export

After customizing, export the dashboard JSON for version control:

1. Dashboard Settings (gear icon) -> JSON Model
2. Copy the JSON
3. Store in your infrastructure repository

Enables reproducible dashboard deployments via Grafana provisioning or
the Grafana API.

---

## Grafana Provisioning

Automate dashboard deployment via provisioning files:

```yaml
# /etc/grafana/provisioning/dashboards/valkey.yaml
apiVersion: 1
providers:
  - name: valkey
    orgId: 1
    folder: Valkey
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards/valkey
      foldersFromFilesStructure: false
```

Place exported dashboard JSON files in `/var/lib/grafana/dashboards/valkey/`.

---

## Percona PMM Dashboards

Percona PMM ships 10 dedicated Valkey dashboards (`percona/grafana-dashboards`
repository, `dashboards/Valkey/` directory). PMM uses `redis_exporter` under
the hood, registered as an external service:

```bash
pmm-admin add external --service-name=valkey-primary \
  --listen-port=9121 \
  --group=valkey \
  --environment=production
```

Key dashboard names:

| Dashboard | Highlights |
|-----------|------------|
| Valkey/Redis Overview | Top 5 commands by latency, cumulative R/W rate |
| Valkey Clients | Per-service connected/blocked/evicted clients |
| Valkey Memory | Memory % usage, eviction policy, expired/evicted rates |
| Valkey Replication | Replica vs master offset lag, full/partial resyncs |
| Valkey Load | Commands/sec, IO thread operations, hits/misses |
| Valkey Command Details | Per-command latency histograms (GET, SET, RPOP, etc.), p99.9 |
| Valkey Persistence Details | AOF appendfsync policy, RDB save config, COW sizes |
| Valkey Cluster Details | Slot status, cluster state per service, known nodes |

PMM's distinguishing feature is per-command latency histograms using
`redis_commands_latencies_usec_bucket` - useful for identifying which
commands contribute most to tail latency.

---
