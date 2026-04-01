# Prometheus Alert Rules for Valkey

Use when configuring Prometheus alert rules for Valkey - complete YAML for availability, memory, connections, replication, persistence, performance, and cluster alerts.

## Contents

- Alert Rule File (line 12)
- Complete Alert Rules (line 25)

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
        labels: { severity: critical }
        annotations:
          summary: "Valkey instance {{ $labels.instance }} is down"

  - name: valkey-memory
    rules:
      - alert: ValkeyMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Memory above 90% on {{ $labels.instance }}"

      - alert: ValkeyMemoryCritical
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.95
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "Memory above 95% on {{ $labels.instance }} - evictions or OOM imminent"

      - alert: ValkeyHighFragmentation
        expr: redis_mem_fragmentation_ratio > 1.5
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "Fragmentation ratio {{ $value }} on {{ $labels.instance }}"

      - alert: ValkeyMemorySwapping
        expr: redis_mem_fragmentation_ratio < 1.0
        for: 10m
        labels: { severity: critical }
        annotations:
          summary: "Likely swapping on {{ $labels.instance }} (frag ratio {{ $value }})"

      - alert: ValkeyEvictions
        expr: increase(redis_evicted_keys_total[5m]) > 0
        for: 1m
        labels: { severity: warning }
        annotations:
          summary: "{{ $value }} keys evicted in 5m on {{ $labels.instance }}"

  - name: valkey-connections
    rules:
      - alert: ValkeyRejectedConnections
        expr: increase(redis_rejected_connections_total[5m]) > 0
        for: 1m
        labels: { severity: warning }
        annotations:
          summary: "Rejecting connections on {{ $labels.instance }}"

      - alert: ValkeyConnectionsNearLimit
        expr: redis_connected_clients / redis_config_maxclients > 0.8
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "{{ $value | humanizePercentage }} of maxclients on {{ $labels.instance }}"

      - alert: ValkeyBlockedClientsHigh
        expr: redis_blocked_clients > 10
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $value }} blocked clients on {{ $labels.instance }}"

  - name: valkey-replication
    rules:
      - alert: ValkeyReplicationBroken
        expr: redis_connected_slaves < 1
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "No replicas connected to {{ $labels.instance }}"

      - alert: ValkeyReplicationLagHigh
        expr: redis_master_last_io_seconds_ago > 30
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "No data from primary in {{ $value }}s on {{ $labels.instance }}"

      - alert: ValkeyReplicationLinkDown
        expr: redis_master_link_up == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Replication link down on {{ $labels.instance }}"

  - name: valkey-persistence
    rules:
      - alert: ValkeyRDBSaveFailed
        expr: redis_rdb_last_bgsave_status == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "RDB save failed on {{ $labels.instance }}"

      - alert: ValkeyAOFRewriteFailed
        expr: redis_aof_last_bgrewrite_status == 0
        for: 1m
        labels: { severity: warning }
        annotations:
          summary: "AOF rewrite failed on {{ $labels.instance }}"

      - alert: ValkeyAOFWriteFailed
        expr: redis_aof_last_write_status == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "AOF writes failing on {{ $labels.instance }} - data loss risk"

  - name: valkey-performance
    rules:
      - alert: ValkeyHighLatency
        expr: sum(rate(redis_commands_duration_seconds_total[5m])) / sum(rate(redis_commands_processed_total[5m])) > 0.01
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Average command latency > 10ms on {{ $labels.instance }}"

      - alert: ValkeyLowHitRate
        expr: rate(redis_keyspace_hits_total[5m]) / (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m])) < 0.9
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "Hit rate {{ $value | humanizePercentage }} on {{ $labels.instance }}"

      - alert: ValkeySlowFork
        expr: redis_latest_fork_usec > 500000
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "Fork took {{ $value }}us on {{ $labels.instance }}"

  - name: valkey-cluster
    rules:
      - alert: ValkeyClusterStateNotOk
        expr: redis_cluster_state == 0
        for: 30s
        labels: { severity: critical }
        annotations:
          summary: "Cluster state not OK on {{ $labels.instance }}"

      - alert: ValkeyClusterSlotsFail
        expr: redis_cluster_slots_fail > 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "{{ $value }} slots in FAIL state on {{ $labels.instance }}"

      - alert: ValkeyNoMaster
        expr: (count(redis_instance_info{role="master"}) or vector(0)) < 1
        for: 30s
        labels: { severity: critical }
        annotations:
          summary: "No Valkey master detected - failover may have failed"

      - alert: ValkeyTooManyMasters
        expr: count(redis_instance_info{role="master"}) > 1
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "{{ $value }} masters detected - possible split-brain"

      - alert: ValkeyClusterFlapping
        expr: changes(redis_connected_slaves[1m]) > 1
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: "Replica flapping on {{ $labels.instance }}"

  - name: valkey-operational
    rules:
      - alert: ValkeySlowlogGrowing
        expr: delta(redis_slowlog_length[10m]) > 10
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "{{ $value }} new slowlog entries in 10m on {{ $labels.instance }}"

      - alert: ValkeyHighP99Latency
        expr: redis_latency_percentiles_usec{quantile="99.9"} > 10000
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "p99.9 latency {{ $value }}us on {{ $labels.instance }}"

      - alert: ValkeyRDBSaveStale
        expr: time() - redis_rdb_last_save_timestamp_seconds > 3600
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "No RDB save in over 1 hour on {{ $labels.instance }}"

      - alert: ValkeyHighKeyEvictionRate
        expr: rate(redis_evicted_keys_total[5m]) > 100
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Evicting {{ $value }} keys/sec on {{ $labels.instance }}"
```

---

## See Also

- [alerting-config](alerting-config.md) - Threshold tuning, recording rules, Alertmanager routing
- [prometheus](prometheus.md) - Exporter setup and scrape configuration
- [grafana](grafana.md) - Dashboard definitions
