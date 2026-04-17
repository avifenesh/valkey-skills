# Prometheus Exporter for Valkey

Use when wiring Valkey into Prometheus.

## Exporter choice

`oliver006/redis_exporter` is the de-facto exporter for Valkey. Re-uses the `redis_*` metric prefix (kept for Grafana/alert-rule compatibility with existing Redis dashboards). Valkey-specific support:

- Accepts `valkey://` and `valkeys://` URI schemes alongside `redis://` / `rediss://`.
- Cluster discovery endpoint `/discover-cluster-nodes` when started with `--is-cluster`. Use with Prometheus `http_sd_configs` for auto-discovered cluster targets.
- `--exclude-latency-histogram-metrics` - set on Valkey < 7 only; 7.x+ populates `LATENCY HISTOGRAM` and the exporter scrapes it by default.

## Valkey-only metrics the exporter surfaces

Metrics present in `INFO` but Valkey-specific (so absent from Redis 7.2-trained dashboards):

| Metric | Source field | Meaning |
|--------|-------------|---------|
| `redis_expired_subkeys_total` | `expired_fields` | Hash fields reclaimed by per-field TTL |
| `redis_evicted_scripts_total` | `evicted_scripts` | Scripts evicted from cache |
| `redis_io_threads_active` | `io_threads_active` | Current active I/O threads under Ignition/Cooldown |
| `redis_cluster_stats_bytes_sent_total` / `_received_total` | `cluster_stats_bytes_sent` / `received` | Cluster bus traffic (Valkey-new INFO field) |

Alert-rule-worthy: `redis_expired_subkeys_total` sudden jumps reveal whether a session store is leaning on hash-field TTL more than expected; `redis_io_threads_active` below `io-threads - 1` means Ignition demoted a worker.

## Minimal ACL for the exporter

```
ACL SETUSER exporter on >pw \
    +info +ping +config|get +client|list \
    +commandlog|get +commandlog|len \
    +latency|latest +latency|history
```

`+commandlog|*` replaces the `+slowlog|*` grant on Valkey - the exporter calls both for backward compat, but only `COMMANDLOG` exists natively now. `+slowlog|*` still works as an alias but grants access to the same data.

## Cluster-aware scraping

One exporter in front of a cluster, Prometheus pulls the node list at scrape time:

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

The `/scrape?target=<uri>` pattern is the multi-target model; a single exporter process handles all nodes. Works with atomic slot migration - moved slots show up as the target's metrics next scrape without exporter reconfiguration.

For single-instance or Sentinel: one exporter per node with standard `static_configs`.
