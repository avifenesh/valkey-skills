# Prometheus Alert Rules for Valkey

Use when configuring Prometheus alert rules for Valkey.

Standard Redis Prometheus alerting applies. The `redis_exporter` emits `redis_*` prefixed metrics for Valkey instances. Alert rule expressions use `redis_*` metric names.

## Rule File Location

```yaml
# prometheus.yml
rule_files:
  - /etc/prometheus/rules/valkey-alerts.yml
```

## Key Alert Categories

- Availability: `redis_up == 0`
- Memory: `redis_memory_used_bytes / redis_memory_max_bytes > 0.9`
- Replication: `redis_master_link_up == 0`, `redis_connected_slaves < 1`
- Persistence: `redis_rdb_last_bgsave_status == 0`, `redis_aof_last_bgrewrite_status == 0`
- Cluster: `redis_cluster_state == 0`, `redis_cluster_slots_fail > 0`

## Valkey-Specific Alert Names

Use `Valkey` prefix in alert names for clarity, even though metric names use `redis_` prefix:

```yaml
- alert: ValkeyDown
  expr: redis_up == 0
```

## Note on Slowlog Alert

The `redis_slowlog_length` metric reflects Valkey's commandlog. The `ValkeySlowlogGrowing` alert still works - it measures the same underlying commandlog data. See monitoring-commandlog.md for the full commandlog interface.
