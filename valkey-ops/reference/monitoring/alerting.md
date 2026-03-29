# Prometheus Alerting Rules

Use when configuring alerts for Valkey - alert thresholds for availability,
memory, connections, replication, persistence, and performance.

---

## Alert Rule File

Save as `/etc/prometheus/rules/valkey-alerts.yml` and reference it in
`prometheus.yml`:

```yaml
# prometheus.yml
rule_files:
  - /etc/prometheus/rules/valkey-alerts.yml
```

---

## Complete Alert Rules

```yaml
groups:
  - name: valkey-availability
    rules:
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Valkey instance {{ $labels.instance }} is down"
          description: "Valkey exporter cannot connect to the instance."


  - name: valkey-memory
    rules:
      - alert: ValkeyMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Valkey memory usage above 90% on {{ $labels.instance }}"
          description: "Memory usage is {{ $value | humanizePercentage }}."

      - alert: ValkeyMemoryCritical
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.95
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Valkey memory usage above 95% on {{ $labels.instance }}"
          description: "Memory usage is {{ $value | humanizePercentage }}. Evictions or OOM imminent."

      - alert: ValkeyHighFragmentation
        expr: redis_mem_fragmentation_ratio > 1.5
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "High memory fragmentation on {{ $labels.instance }}"
          description: "Fragmentation ratio is {{ $value }}. Consider active defragmentation or restart."

      - alert: ValkeyMemorySwapping
        expr: redis_mem_fragmentation_ratio < 1.0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Valkey may be swapping on {{ $labels.instance }}"
          description: "Fragmentation ratio is {{ $value }} (below 1.0 indicates RSS < allocated, likely swapping)."

      - alert: ValkeyEvictions
        expr: increase(redis_evicted_keys_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Key evictions occurring on {{ $labels.instance }}"
          description: "{{ $value }} keys evicted in the last 5 minutes."

  - name: valkey-connections
    rules:
      - alert: ValkeyRejectedConnections
        expr: increase(redis_rejected_connections_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Valkey rejecting connections on {{ $labels.instance }}"
          description: "{{ $value }} connections rejected. Check maxclients setting."

      - alert: ValkeyConnectionsNearLimit
        expr: redis_connected_clients / redis_config_maxclients > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Connection count near limit on {{ $labels.instance }}"
          description: "{{ $value | humanizePercentage }} of maxclients used."

      - alert: ValkeyBlockedClientsHigh
        expr: redis_blocked_clients > 10
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High number of blocked clients on {{ $labels.instance }}"
          description: "{{ $value }} clients are blocked."

  - name: valkey-replication
    rules:
      - alert: ValkeyReplicationBroken
        expr: redis_connected_slaves < 1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "No replicas connected to {{ $labels.instance }}"
          description: "Expected at least 1 connected replica."

      - alert: ValkeyReplicationLagHigh
        expr: redis_master_last_io_seconds_ago > 30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Replication lag high on {{ $labels.instance }}"
          description: "Replica has not received data from primary in {{ $value }} seconds."

      - alert: ValkeyReplicationLinkDown
        expr: redis_master_link_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Replication link down on {{ $labels.instance }}"
          description: "Replica cannot reach its primary."

  - name: valkey-persistence
    rules:
      - alert: ValkeyRDBSaveFailed
        expr: redis_rdb_last_bgsave_status == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "RDB save failed on {{ $labels.instance }}"
          description: "Last background save did not complete successfully."

      - alert: ValkeyAOFRewriteFailed
        expr: redis_aof_last_bgrewrite_status == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "AOF rewrite failed on {{ $labels.instance }}"
          description: "Last AOF background rewrite did not complete successfully."

      - alert: ValkeyAOFWriteFailed
        expr: redis_aof_last_write_status == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "AOF write error on {{ $labels.instance }}"
          description: "AOF writes are failing. Risk of data loss."

  - name: valkey-performance
    rules:
      - alert: ValkeyHighLatency
        expr: >
          rate(redis_commands_duration_seconds_total[5m])
          /
          rate(redis_commands_processed_total[5m])
          > 0.01
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High average command latency on {{ $labels.instance }}"
          description: "Average command duration exceeds 10ms."

      - alert: ValkeyLowHitRate
        expr: >
          rate(redis_keyspace_hits_total[5m])
          /
          (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
          < 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Low cache hit rate on {{ $labels.instance }}"
          description: "Hit rate is {{ $value | humanizePercentage }}. Review access patterns."

      - alert: ValkeySlowFork
        expr: redis_latest_fork_usec > 500000
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Slow fork on {{ $labels.instance }}"
          description: "Last fork took {{ $value }}us (> 500ms). Large dataset or memory pressure."
```

---

## Alert Threshold Summary

Quick reference for tuning thresholds to your environment:

| Alert | Default Threshold | Adjust When |
|-------|-------------------|-------------|
| Memory high | 90% of maxmemory | Lower for write-heavy workloads |
| Memory critical | 95% of maxmemory | - |
| Fragmentation high | ratio > 1.5 | Higher if active defrag is enabled |
| Swapping | ratio < 1.0 | - |
| Rejected connections | any > 0 | Raise if connection pooling causes bursts |
| Connections near limit | 80% of maxclients | Adjust based on pool sizing |
| Blocked clients | > 10 sustained | Adjust based on workload |
| Replication lag | > 30s since last I/O | Lower for latency-sensitive reads |
| Replication link down | any down | - |
| RDB/AOF failures | any failure | - |
| Command latency | > 10ms average | Lower for latency-critical apps |
| Hit rate low | < 90% | Higher for pure cache workloads |
| Fork duration | > 500ms | Higher for large datasets |

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

## See Also

- [Monitoring Metrics](metrics.md) - metric definitions and INFO field mapping
- [Prometheus Setup](prometheus.md) - exporter and scrape configuration
- [Grafana Dashboards](grafana.md) - dashboard thresholds aligned with alerts
- [Pub/Sub Configuration](../configuration/pubsub.md) - subscriber buffer alerting
- [Troubleshooting OOM](../troubleshooting/oom.md) - memory alert response
