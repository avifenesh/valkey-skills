# Alert Threshold Tuning and Alertmanager Configuration

Use when tuning Valkey alert thresholds or configuring Alertmanager routing for Valkey alerts.

Standard Prometheus/Alertmanager configuration applies. See Redis monitoring docs for general threshold guidance.

## Valkey-Specific Recording Rules

Use `valkey:` prefix for recording rules to distinguish from Redis instances:

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

## Alertmanager Routing (Valkey-Named)

```yaml
route:
  routes:
    - match_re:
        alertname: "^Valkey.*"
      receiver: valkey-team
receivers:
  - name: valkey-team
    slack_configs:
      - channel: '#valkey-alerts'
```

## Community Alert Sources

- `samber/awesome-prometheus-alerts` (`dist/rules/redis/`) - works with Valkey
- `oliver006/redis_exporter/contrib/redis-mixin/` - Jsonnet-based rules
