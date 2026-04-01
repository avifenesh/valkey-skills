Use when tuning Valkey alert thresholds, setting up Prometheus recording rules for Valkey, or configuring Alertmanager routing for Valkey alerts.

# Alert Threshold Tuning and Alertmanager Configuration

## Contents

- Alert Threshold Summary (line 12)
- Recording Rules (line 42)
- Alertmanager Routing (line 60)
- Community Alert Sources (line 92)
- See Also (line 100)

---

## Alert Threshold Summary

Quick reference for tuning thresholds to your environment:

| Alert | Default Threshold | Adjust When |
|-------|-------------------|-------------|
| Memory high | 90% of `maxmemory` | Lower for write-heavy workloads |
| Memory critical | 95% of `maxmemory` | - |
| Fragmentation high | ratio > 1.5 | Higher if active defrag is enabled |
| Swapping | ratio < 1.0 | - |
| Rejected connections | any > 0 | Raise if connection pooling causes bursts |
| Connections near limit | 80% of `maxclients` | Adjust based on pool sizing |
| Blocked clients | > 10 sustained | Adjust based on workload |
| Replication lag | > 30s since last I/O | Lower for latency-sensitive reads |
| Replication link down | any down | - |
| RDB/AOF failures | any failure | - |
| Command latency | > 10ms average | Lower for latency-critical apps |
| Hit rate low | < 90% | Higher for pure cache workloads |
| Fork duration | > 500ms | Higher for large datasets |
| Cluster state | != ok | - |
| Cluster slots fail | > 0 | - |
| No master | count < 1 | - |
| Multiple masters | count > 1 | Possible split-brain |
| Slowlog growing | > 10 entries/10m | Lower for latency-sensitive apps |
| p99.9 latency | > 10ms | Lower for SLA-bound services |
| RDB save stale | > 1 hour since last | Adjust based on save schedule |
| Eviction rate | > 100 keys/sec | Lower for non-cache workloads |

---

## Recording Rules

Pre-compute expensive queries. Add to the same rule file:

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

---

## Alertmanager Routing

Example Alertmanager configuration for routing Valkey alerts:

```yaml
# alertmanager.yml
route:
  receiver: default
  routes:
    - match:
        severity: critical
      receiver: pagerduty
      repeat_interval: 5m
    - match:
        severity: warning
      receiver: slack
      repeat_interval: 30m

receivers:
  - name: default
    slack_configs:
      - channel: '#valkey-alerts'
  - name: pagerduty
    pagerduty_configs:
      - service_key: '<your-service-key>'
  - name: slack
    slack_configs:
      - channel: '#valkey-alerts'
```

---

## Community Alert Sources

- **awesome-prometheus-alerts** (`samber/awesome-prometheus-alerts`,
  `dist/rules/redis/`) - includes RedisMissingMaster, RedisTooManyMasters,
  RedisClusterFlapping, RedisMissingBackup, RedisOutOfSystemMemory.
- **redis-mixin** (`oliver006/redis_exporter/contrib/redis-mixin/`) -
  Jsonnet-based alerts including cluster slot and state rules.

---

## See Also

- [alerting-rules](alerting-rules.md) - Complete Prometheus alert rules YAML
- [prometheus](prometheus.md) - Exporter setup and scrape configuration
- [grafana](grafana.md) - Dashboard definitions
