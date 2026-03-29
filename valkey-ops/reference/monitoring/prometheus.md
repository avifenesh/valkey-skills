# Prometheus Exporter Setup

Use when configuring Prometheus to scrape Valkey metrics - exporter deployment,
scrape configuration, metric naming, and multi-instance setups.

---

## Exporter: oliver006/redis_exporter

The `oliver006/redis_exporter` is the standard Prometheus exporter for
Valkey. It supports Valkey 8.x and 9.x despite the "redis" naming (the
protocol is compatible).

### Docker deployment

```bash
docker run -d --name valkey-exporter \
  -p 9121:9121 \
  -e REDIS_ADDR=valkey://valkey-host:6379 \
  -e REDIS_PASSWORD=secret \
  oliver006/redis_exporter
```

### Binary deployment

```bash
./redis_exporter \
  --redis.addr=valkey://localhost:6379 \
  --redis.password=secret \
  --web.listen-address=0.0.0.0:9121
```

### Systemd service

```ini
[Unit]
Description=Valkey Prometheus Exporter
After=network.target

[Service]
Type=simple
User=prometheus
ExecStart=/usr/local/bin/redis_exporter \
  --redis.addr=valkey://localhost:6379 \
  --redis.password-file=/etc/valkey-exporter/password
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## Exporter Configuration Flags

| Flag | Env Var | Default | Description |
|------|---------|---------|-------------|
| `--redis.addr` | `REDIS_ADDR` | `redis://localhost:6379` | Instance address |
| `--redis.user` | `REDIS_USER` | none | ACL username |
| `--redis.password` | `REDIS_PASSWORD` | none | Authentication password |
| `--redis.password-file` | `REDIS_PASSWORD_FILE` | none | File containing password |
| `--web.listen-address` | `REDIS_EXPORTER_WEB_LISTEN_ADDRESS` | `0.0.0.0:9121` | Exporter bind address |
| `--web.telemetry-path` | `REDIS_EXPORTER_WEB_TELEMETRY_PATH` | `/metrics` | Metrics endpoint path |
| `--namespace` | `REDIS_EXPORTER_NAMESPACE` | `redis` | Metric name prefix |
| `--is-cluster` | - | false | Enable cluster node discovery |
| `--skip-tls-verification` | `REDIS_EXPORTER_SKIP_TLS_VERIFICATION` | false | Skip TLS cert verification |
| `--tls-client-cert-file` | `REDIS_EXPORTER_TLS_CLIENT_CERT_FILE` | none | Client cert for mTLS |
| `--tls-client-key-file` | `REDIS_EXPORTER_TLS_CLIENT_KEY_FILE` | none | Client key for mTLS |
| `--tls-ca-cert-file` | `REDIS_EXPORTER_TLS_CA_CERT_FILE` | none | CA cert for verification |

---

## Prometheus Scrape Configuration

### Single instance

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

### Multiple instances via relabeling

When running one exporter per Valkey instance:

```yaml
scrape_configs:
  - job_name: valkey
    static_configs:
      - targets:
        - valkey-primary:9121
        - valkey-replica-1:9121
        - valkey-replica-2:9121
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.+):9121'
        target_label: instance
        replacement: '${1}:6379'
```

### Multi-target pattern (single exporter, multiple instances)

```yaml
scrape_configs:
  - job_name: valkey
    static_configs:
      - targets:
        - valkey://valkey-primary:6379
        - valkey://valkey-replica-1:6379
        - valkey://valkey-replica-2:6379
    metrics_path: /scrape
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: exporter-host:9121
```

### Service discovery (Kubernetes)

```yaml
scrape_configs:
  - job_name: valkey
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: (.+)
        replacement: ${1}:9121
```

---

## Metric Naming Conventions

The exporter uses the `redis_` prefix by default (configurable via
`--namespace`). Key metric families:

| Prometheus Metric | INFO Field | Type |
|-------------------|-----------|------|
| `redis_up` | (connectivity) | gauge |
| `redis_uptime_in_seconds` | uptime_in_seconds | gauge |
| `redis_connected_clients` | connected_clients | gauge |
| `redis_blocked_clients` | blocked_clients | gauge |
| `redis_memory_used_bytes` | used_memory | gauge |
| `redis_memory_max_bytes` | maxmemory | gauge |
| `redis_memory_used_rss_bytes` | used_memory_rss | gauge |
| `redis_mem_fragmentation_ratio` | mem_fragmentation_ratio | gauge |
| `redis_commands_processed_total` | total_commands_processed | counter |
| `redis_connections_received_total` | total_connections_received | counter |
| `redis_rejected_connections_total` | rejected_connections | counter |
| `redis_keyspace_hits_total` | keyspace_hits | counter |
| `redis_keyspace_misses_total` | keyspace_misses | counter |
| `redis_evicted_keys_total` | evicted_keys | counter |
| `redis_expired_keys_total` | expired_keys | counter |
| `redis_connected_slaves` | connected_slaves | gauge |
| `redis_master_repl_offset` | master_repl_offset | gauge |
| `redis_rdb_last_save_timestamp_seconds` | rdb_last_save_time | gauge |
| `redis_instantaneous_ops_per_sec` | instantaneous_ops_per_sec | gauge |
| `redis_latest_fork_usec` | latest_fork_usec | gauge |
| `redis_commands_duration_seconds_total` | (per-command) | counter |

---

## ACL User for Exporter

Create a minimal-privilege ACL user for the exporter:

```
ACL SETUSER exporter on >exporterpass +info +ping +config|get +client|list +slowlog|get +latency|latest ~*
```

This gives the exporter access to the monitoring commands it needs without
granting data access or dangerous operations.

---

## Verification

After setup, verify the exporter is working:

```bash
# Check exporter health
curl http://exporter-host:9121/health

# View raw metrics
curl http://exporter-host:9121/metrics

# Check Prometheus targets
# Navigate to Prometheus UI -> Status -> Targets
```

---

## See Also

- [Monitoring Metrics](metrics.md) - metric definitions and alert thresholds
- [Grafana Dashboards](grafana.md) - dashboard setup
- [Alerting Rules](alerting.md) - Prometheus alert rules for Valkey
- [Kubernetes Tuning](../kubernetes/tuning-k8s.md) - sidecar exporter in K8s
- [Security ACL](../security/acl.md) - minimal-privilege exporter user
