# Prometheus and Grafana for Valkey

Use when setting up metrics collection and visualization for Valkey with
Prometheus and Grafana - exporter selection, scrape configuration, dashboards,
Kubernetes integration, and alerting.

---

## redis_exporter (oliver006/redis_exporter)

The standard Prometheus exporter for Valkey and Redis metrics. Officially
branded as "Prometheus Valkey & Redis Metrics Exporter". Despite the name
retaining "redis", the project explicitly supports Valkey 7.x, 8.x, and 9.x
with native `valkey://` and `valkeys://` URI schemes.

- **Latest version**: v1.82.0 (2026-03-08)
- **Port**: 9121 (default)
- **Repo**: [oliver006/redis_exporter](https://github.com/oliver006/redis_exporter)
- **Distribution**: Docker Hub, ghcr.io, quay.io, standalone binary
- **License**: MIT
- **Release cadence**: Roughly monthly (v1.75.0 through v1.82.0 between Aug 2025 and Mar 2026)

v1.82.0 added hostname-based metric export via cluster discovery and Redis role
labels on all metrics.

### Quick start

```bash
# Docker
docker run -d --name valkey-exporter \
  -p 9121:9121 \
  -e REDIS_ADDR=valkey://valkey-host:6379 \
  oliver006/redis_exporter

# Binary
./redis_exporter --redis.addr=valkey://localhost:6379
```

### Key configuration flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--redis.addr` | `redis://localhost:6379` | Valkey instance address |
| `--redis.user` | none | ACL username |
| `--redis.password` | none | Auth password |
| `--namespace` | `redis` | Metric name prefix |
| `--is-cluster` | false | Enable cluster node auto-discovery |
| `--check-keys` | none | Key patterns to export via SCAN |
| `--check-streams` | none | Stream patterns for group/consumer metrics |
| `--export-client-list` | false | Export CLIENT LIST as metrics |
| `--include-system-metrics` | false | Include system memory metrics |

The `--namespace` flag controls the metric prefix. All metrics are prefixed
with `redis_` by default. Changing this to `valkey` would rename metrics to
`valkey_connected_clients`, etc. - but this breaks compatibility with existing
dashboards and alerting rules that expect the `redis_` prefix. Most deployments
keep the default.

### Embedded in Operators and Charts

The Hyperspike operator bundles redis_exporter (bumped to v1.78.0 in their
v0.0.61 release). Bitnami Helm charts bundle redis-exporter 1.76.0. Both
auto-configure the exporter sidecar and ServiceMonitor creation.

---

## Key Metrics

All metrics use the `redis_` prefix by default. The most important metrics
to monitor in each category:

| Category | Key Metrics | What to watch |
|----------|-------------|---------------|
| Memory | `redis_memory_used_bytes`, `redis_memory_max_bytes`, `redis_mem_fragmentation_ratio` | Usage approaching maxmemory; fragmentation above 1.5 |
| Connections | `redis_connected_clients`, `redis_blocked_clients`, `redis_rejected_connections_total` | Rejected connections indicate maxclients reached |
| Commands | `redis_instantaneous_ops_per_sec`, `redis_commands_duration_seconds_total`, `redis_keyspace_hits_total` | Ops/sec trends; hit rate; per-command latency |
| Replication | `redis_connected_slaves`, `redis_master_repl_offset`, `redis_master_link_up` | Link status; replication lag (offset delta) |
| Keyspace | `redis_db_keys`, `redis_evicted_keys_total`, `redis_expired_keys_total` | Key count growth; eviction pressure |

For the full metric reference with alert thresholds, see the valkey-ops skill
(monitoring/metrics and monitoring/alerting).

---

## Prometheus Scrape Configuration

### Basic static scrape

```yaml
scrape_configs:
  - job_name: valkey
    static_configs:
      - targets:
        - valkey-host-1:9121
        - valkey-host-2:9121
    scrape_interval: 15s
    scrape_timeout: 10s
```

### Multi-target pattern (single exporter, multiple instances)

```yaml
scrape_configs:
  - job_name: valkey
    static_configs:
      - targets:
        - valkey://primary:6379
        - valkey://replica-1:6379
    metrics_path: /scrape
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: exporter-host:9121
```

### Cluster auto-discovery

Requires `--is-cluster` flag on the exporter. Prometheus discovers all cluster
nodes automatically:

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

---

## Grafana Dashboards

### Valkey dashboard (ID 24733)

The dedicated Valkey monitoring dashboard on Grafana Labs. Import via
Dashboards -> Import -> enter ID `24733`. Designed specifically for Valkey
deployments with panels reflecting Valkey terminology and features.

### Redis-compatible dashboards

Existing Redis dashboards work with Valkey because the exporter uses the same
`redis_` metric prefix:

| Dashboard ID | Name | Notes |
|-------------|------|-------|
| 763 | Redis Dashboard (official exporter) | Canonical, maintained by oliver006 |
| 14091 | Redis Exporter Quickstart and Dashboard | Compact single-pane view |
| 12776 | Redis | Cluster-specific panels |

Dashboard 763 ships with the exporter source code at
`contrib/grafana_prometheus_redis_dashboard.json`.

### Valkey-Specific Metric Gaps

No public dashboard currently visualizes Valkey-only primitives:

- **COMMANDLOG** (8.1+) - tracks slow execution, large request payloads, and
  large reply payloads. Unlike SLOWLOG, captures three criteria. Only Valkey
  Admin has a UI for this data today.
- **CLUSTER SLOT-STATS** (8.0+) - per-slot key counts, reads, writes, and CPU
  usage. Enables targeted rebalancing instead of guessing from aggregate node
  metrics.
- **Per-thread I/O utilization** (9.1) - `used_active_time_io_thread_N` fields
  in INFO. Addresses the problem that CPU utilization is misleading with
  busy-polling I/O threads.

The `valkey-perf-benchmark` repo (valkey-io/valkey-perf-benchmark) includes
Grafana dashboards for benchmark visualization across commits - but these are
for CI/benchmarking, not production monitoring.

---

## OpenTelemetry Integration

### Valkey GLIDE (Built-In OTel)

GLIDE has native OpenTelemetry instrumentation across Java, Python, Node.js, and
Go. Active development includes proper DB semantic conventions and per-command
server address resolution for cluster mode. Spring Data Valkey's README lists
"OpenTelemetry instrumentation support when using the Valkey GLIDE client for
emitting traces and metrics."

### valkey-go (Built-In OTel)

Ships a `valkeyotel` package with two custom metrics: `valkey_do_cache_miss` and
`valkey_do_cache_hits`. Integration via `valkeyotel.NewClient(option)`.

### Other Clients

For valkey-py and iovalkey, OTel integration is either through existing Redis
instrumentation libraries (protocol-compatible) or not yet available natively.
Native Valkey instrumentation for opentelemetry-python-contrib is under
development.

---

## Kubernetes: PodMonitor with redis_exporter Sidecar

When running Valkey on Kubernetes with the Prometheus Operator, deploy
redis_exporter as a sidecar container and use a PodMonitor CRD to configure
scraping.

### Sidecar container (add to Valkey pod spec)

```yaml
containers:
  - name: valkey
    image: valkey/valkey:9.0
    ports:
      - containerPort: 6379
  - name: exporter
    image: oliver006/redis_exporter:latest
    ports:
      - containerPort: 9121
        name: metrics
    env:
      - name: REDIS_ADDR
        value: "valkey://localhost:6379"
```

### PodMonitor CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: valkey-monitor
  labels:
    app: valkey
spec:
  selector:
    matchLabels:
      app: valkey
  podMetricsEndpoints:
    - port: metrics
      interval: 15s
      path: /metrics
```

The official Valkey Helm chart supports metrics export configuration natively -
enable `metrics.enabled: true` to add the exporter sidecar and create the
PodMonitor automatically.

---

## Alert Rule Examples

Save as a Prometheus rule file and reference in `prometheus.yml` under
`rule_files`. These are starter alerts - see the valkey-ops skill
(monitoring/alerting) for a complete production alert ruleset.

```yaml
groups:
  - name: valkey-alerts
    rules:
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Valkey instance {{ $labels.instance }} is down"

      - alert: ValkeyMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Memory above 90% on {{ $labels.instance }}"

      - alert: ValkeyReplicationBroken
        expr: redis_master_link_up == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "Replica {{ $labels.instance }} lost connection to primary"
```

---

## When to Use What

| Situation | Approach |
|-----------|----------|
| Self-hosted Valkey, need metrics | redis_exporter + Prometheus + Grafana |
| Kubernetes cluster | Exporter sidecar + PodMonitor CRD |
| Already using a monitoring platform | See [platforms.md](platforms.md) for Datadog, New Relic, Percona PMM |
| Need server-side monitoring commands | See the valkey-ops skill for INFO, COMMANDLOG, LATENCY |

---

## See Also

- [Monitoring Platforms](platforms.md) - Percona PMM, Datadog, New Relic
- [GUI Tools](gui-tools.md) - desktop and web-based monitoring and management
- Cross-reference the valkey-ops skill for server-side monitoring commands (INFO, COMMANDLOG, LATENCY, MEMORY DOCTOR)
