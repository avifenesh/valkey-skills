# Valkey/Redis Monitoring Research

Research date: 2026-03-29
Sources: GitHub repos, Grafana dashboard registry, Prometheus alerting communities, Percona PMM, Datadog, New Relic

---

## 1. oliver006/redis_exporter

**Latest version:** v1.82.0 (2026-03-08)
**Repository:** https://github.com/oliver006/redis_exporter
**Docker:** `oliver006/redis_exporter`, also on ghcr.io and quay.io
**Default port:** 9121
**Compatibility:** Valkey 7.x, 8.x, 9.x (and Redis) - explicitly branded as "Prometheus Valkey & Redis Metrics Exporter"

The exporter natively supports `valkey://` and `valkeys://` URI schemes (internally mapped to `redis://`/`rediss://`).

### Configuration Flags

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `redis.addr` | `REDIS_ADDR` | `redis://localhost:6379` | Instance address. Use `rediss://` for TLS, `valkey://`/`valkeys://` for Valkey |
| `redis.user` | `REDIS_USER` | `""` | ACL username (Redis 6+/Valkey) |
| `redis.password` | `REDIS_PASSWORD` | `""` | Password |
| `redis.password-file` | `REDIS_PASSWORD_FILE` | `""` | JSON file mapping hosts to passwords |
| `check-keys` | `REDIS_EXPORTER_CHECK_KEYS` | `""` | Key patterns to export (uses SCAN) |
| `check-single-keys` | `REDIS_EXPORTER_CHECK_SINGLE_KEYS` | `""` | Specific keys to export (direct lookup, faster) |
| `check-streams` | `REDIS_EXPORTER_CHECK_STREAMS` | `""` | Stream patterns for stream/group/consumer metrics |
| `check-single-streams` | `REDIS_EXPORTER_CHECK_SINGLE_STREAMS` | `""` | Specific streams (direct lookup) |
| `streams-exclude-consumer-metrics` | `REDIS_EXPORTER_STREAMS_EXCLUDE_CONSUMER_METRICS` | `false` | Skip per-consumer metrics (reduces cardinality) |
| `check-keys-batch-size` | `REDIS_EXPORTER_CHECK_KEYS_BATCH_SIZE` | - | COUNT for SCAN batches |
| `count-keys` | `REDIS_EXPORTER_COUNT_KEYS` | `""` | Patterns to count via SCAN |
| `check-key-groups` | `REDIS_EXPORTER_CHECK_KEY_GROUPS` | `""` | Lua regexes for memory aggregation by key groups |
| `max-distinct-key-groups` | `REDIS_EXPORTER_MAX_DISTINCT_KEY_GROUPS` | - | Cap on distinct key groups per DB |
| `script` | `REDIS_EXPORTER_SCRIPT` | `""` | Lua script paths for custom metrics |
| `lua-script-read-only` | `REDIS_EXPORTER_LUA_SCRIPT_READ_ONLY` | `false` | Use EVAL_RO instead of EVAL |
| `namespace` | `REDIS_EXPORTER_NAMESPACE` | `redis` | Metric prefix namespace |
| `web.listen-address` | `REDIS_EXPORTER_WEB_LISTEN_ADDRESS` | `0.0.0.0:9121` | Listen address |
| `web.telemetry-path` | `REDIS_EXPORTER_WEB_TELEMETRY_PATH` | `/metrics` | Metrics path |
| `connection-timeout` | `REDIS_EXPORTER_CONNECTION_TIMEOUT` | `15s` | Connection timeout |
| `is-cluster` | `REDIS_EXPORTER_IS_CLUSTER` | `false` | Enable cluster mode + `/discover-cluster-nodes` endpoint |
| `cluster-discover-hostnames` | `REDIS_EXPORTER_CLUSTER_DISCOVER_HOSTNAMES` | `false` | Use hostnames in cluster discovery |
| `redis-only-metrics` | `REDIS_EXPORTER_REDIS_ONLY_METRICS` | `false` | Omit Go runtime metrics |
| `include-go-runtime-metrics` | `REDIS_EXPORTER_INCLUDE_GO_RUNTIME_METRICS` | `false` | Include Go runtime metrics |
| `include-config-metrics` | `REDIS_EXPORTER_INCL_CONFIG_METRICS` | `false` | Export all CONFIG settings as metrics |
| `include-system-metrics` | `REDIS_EXPORTER_INCL_SYSTEM_METRICS` | `false` | Export `total_system_memory_bytes` |
| `include-modules-metrics` | `REDIS_EXPORTER_INCL_MODULES_METRICS` | `false` | Collect Redis Modules metrics |
| `include-search-indexes-metrics` | `REDIS_EXPORTER_INCL_SEARCH_INDEXES_METRICS` | `false` | Collect Search index metrics |
| `check-search-indexes` | `REDIS_EXPORTER_CHECK_SEARCH_INDEXES` | `.*` | Regex filter for Search indexes |
| `exclude-latency-histogram-metrics` | `REDIS_EXPORTER_EXCLUDE_LATENCY_HISTOGRAM_METRICS` | `false` | Skip LATENCY HISTOGRAM (avoids errors on < v7) |
| `redact-config-metrics` | `REDIS_EXPORTER_REDACT_CONFIG_METRICS` | `false` | Redact sensitive config values |
| `ping-on-connect` | `REDIS_EXPORTER_PING_ON_CONNECT` | `false` | PING after connect, record duration |
| `export-client-list` | `REDIS_EXPORTER_EXPORT_CLIENT_LIST` | `false` | CLIENT LIST metrics |
| `export-client-port` | `REDIS_EXPORTER_EXPORT_CLIENT_PORT` | `false` | Include client port (high cardinality) |
| `set-client-name` | `REDIS_EXPORTER_SET_CLIENT_NAME` | `true` | Set client name to `redis_exporter` |
| `append-instance-role-label` | `REDIS_EXPORTER_APPEND_INSTANCE_ROLE_LABEL` | `false` | Add `instance_role` label (master/replica) |
| `include-metrics-for-empty-databases` | `REDIS_EXPORTER_INCL_METRICS_FOR_EMPTY_DATABASES` | `false` | Emit db metrics for empty DBs |
| `config-command` | `REDIS_EXPORTER_CONFIG_COMMAND` | `CONFIG` | Custom CONFIG command name; set `-` to skip |
| `disable-scrape-endpoint` | `REDIS_EXPORTER_DISABLE_SCRAPE_ENDPOINT` | `false` | Disable `/scrape` endpoint |
| `basic-auth-username` | `REDIS_EXPORTER_BASIC_AUTH_USERNAME` | `""` | Basic auth for exporter endpoint |
| `basic-auth-password` | `REDIS_EXPORTER_BASIC_AUTH_PASSWORD` | `""` | Basic auth password (plaintext) |
| `basic-auth-hash-password` | `REDIS_EXPORTER_BASIC_AUTH_HASH_PASSWORD` | `""` | Bcrypt-hashed password alternative |
| `is-tile38` | `REDIS_EXPORTER_IS_TILE38` | `false` | Tile38-specific metrics |
| `log-level` | `REDIS_EXPORTER_LOG_LEVEL` | - | Log level |
| `log-format` | `REDIS_EXPORTER_LOG_FORMAT` | `txt` | Log format (`txt` or `json`) |
| `debug` | `REDIS_EXPORTER_DEBUG` | `false` | Verbose debug output |

**TLS flags:** `tls-client-key-file`, `tls-client-cert-file`, `tls-ca-cert-file`, `tls-server-key-file`, `tls-server-cert-file`, `tls-server-ca-cert-file`, `tls-server-min-version` (default TLS1.2), `skip-tls-verification`

### Complete Metric Names

All metrics are prefixed with `redis_` by default (configurable via `--namespace`).

#### Gauge Metrics (from INFO)

**Server:**
- `redis_uptime_in_seconds`
- `redis_process_id`
- `redis_io_threads_active`

**Clients:**
- `redis_connected_clients`
- `redis_blocked_clients`
- `redis_max_clients`
- `redis_tracking_clients`
- `redis_clients_in_timeout_table`
- `redis_pubsub_clients` (v7.4+)
- `redis_watching_clients` (v7.4+)
- `redis_total_watched_keys` (v7.4+)
- `redis_total_blocking_keys` (v7.2+)
- `redis_total_blocking_keys_on_nokey` (v7.2+)
- `redis_client_longest_output_list` (v2-4)
- `redis_client_biggest_input_buf` (v2-4)
- `redis_client_recent_max_output_buffer_bytes` (v5+)
- `redis_client_recent_max_input_buffer_bytes` (v5+)

**Memory:**
- `redis_allocator_active_bytes`
- `redis_allocator_allocated_bytes`
- `redis_allocator_resident_bytes`
- `redis_allocator_frag_ratio`
- `redis_allocator_frag_bytes`
- `redis_allocator_muzzy_bytes`
- `redis_allocator_rss_ratio`
- `redis_allocator_rss_bytes`
- `redis_memory_used_bytes`
- `redis_memory_used_rss_bytes`
- `redis_memory_used_peak_bytes`
- `redis_memory_used_lua_bytes`
- `redis_memory_used_vm_eval_bytes` (v7.0+)
- `redis_memory_used_scripts_eval_bytes` (v7.0+)
- `redis_memory_used_overhead_bytes`
- `redis_memory_used_startup_bytes`
- `redis_memory_used_dataset_bytes`
- `redis_memory_used_vm_functions_bytes` (v7.0+)
- `redis_memory_used_scripts_bytes` (v7.0+)
- `redis_memory_used_functions_bytes` (v7.0+)
- `redis_memory_used_vm_total` (v7.0+)
- `redis_memory_max_bytes`
- `redis_memory_max_reservation_bytes`
- `redis_memory_max_reservation_desired_bytes`
- `redis_memory_max_fragmentation_reservation_bytes`
- `redis_memory_max_fragmentation_reservation_desired_bytes`
- `redis_mem_fragmentation_ratio`
- `redis_mem_fragmentation_bytes`
- `redis_mem_clients_slaves`
- `redis_mem_clients_normal`
- `redis_mem_cluster_links_bytes`
- `redis_mem_aof_buffer_bytes`
- `redis_mem_replication_backlog_bytes`
- `redis_expired_stale_percentage`
- `redis_mem_not_counted_for_eviction_bytes`
- `redis_mem_total_replication_buffers_bytes` (v7.0+)
- `redis_mem_overhead_db_hashtable_rehashing_bytes` (v7.4+)
- `redis_lazyfree_pending_objects`
- `redis_lazyfreed_objects`
- `redis_active_defrag_running`
- `redis_migrate_cached_sockets_total`
- `redis_defrag_hits`, `redis_defrag_misses`, `redis_defrag_key_hits`, `redis_defrag_key_misses`
- `redis_number_of_cached_scripts` (v7.0+)
- `redis_number_of_functions` (v7.0+)
- `redis_number_of_libraries` (v7.4+)

**Persistence:**
- `redis_loading_dump_file`
- `redis_async_loading` (v7.0+)
- `redis_rdb_changes_since_last_save`
- `redis_rdb_bgsave_in_progress`
- `redis_rdb_last_save_timestamp_seconds`
- `redis_rdb_last_bgsave_status`
- `redis_rdb_last_bgsave_duration_sec`
- `redis_rdb_current_bgsave_duration_sec`
- `redis_rdb_saves_total`
- `redis_rdb_last_cow_size_bytes`
- `redis_rdb_last_load_expired_keys` (v7.0+)
- `redis_rdb_last_load_loaded_keys` (v7.0+)
- `redis_aof_enabled`
- `redis_aof_rewrite_in_progress`
- `redis_aof_rewrite_scheduled`
- `redis_aof_last_rewrite_duration_sec`
- `redis_aof_current_rewrite_duration_sec`
- `redis_aof_last_cow_size_bytes`
- `redis_aof_current_size_bytes`
- `redis_aof_base_size_bytes`
- `redis_aof_pending_rewrite`
- `redis_aof_buffer_length`
- `redis_aof_rewrite_buffer_length` (v7.0+)
- `redis_aof_pending_bio_fsync`
- `redis_aof_delayed_fsync`
- `redis_aof_last_bgrewrite_status`
- `redis_aof_last_write_status`
- `redis_module_fork_in_progress`
- `redis_module_fork_last_cow_size`

**Stats:**
- `redis_current_eviction_exceeded_time_ms`
- `redis_pubsub_channels`
- `redis_pubsub_patterns`
- `redis_pubsubshard_channels` (v7.0.3+)
- `redis_latest_fork_usec`
- `redis_tracking_total_keys`, `redis_tracking_total_items`, `redis_tracking_total_prefixes`
- `redis_instantaneous_eventloop_cycles_per_sec` (v7.0+)
- `redis_instantaneous_eventloop_duration_usec` (v7.0+)

**Replication:**
- `redis_connected_slaves`
- `redis_replication_backlog_bytes`
- `redis_repl_backlog_is_active`
- `redis_repl_backlog_first_byte_offset`
- `redis_repl_backlog_history_bytes`
- `redis_master_repl_offset`
- `redis_second_repl_offset`
- `redis_slave_expires_tracked_keys`
- `redis_slave_priority`
- `redis_replica_resyncs_full`
- `redis_replica_partial_resync_accepted`
- `redis_replica_partial_resync_denied`

**Cluster:**
- `redis_cluster_messages_sent_total`
- `redis_cluster_messages_received_total`

#### Counter Metrics (from INFO)

- `redis_connections_received_total`
- `redis_commands_processed_total`
- `redis_rejected_connections_total`
- `redis_net_input_bytes_total`
- `redis_net_output_bytes_total`
- `redis_net_repl_input_bytes_total`
- `redis_net_repl_output_bytes_total`
- `redis_expired_subkeys_total`
- `redis_expired_keys_total`
- `redis_expired_time_cap_reached_total`
- `redis_expire_cycle_cpu_time_ms_total`
- `redis_evicted_keys_total`
- `redis_evicted_clients_total` (v7.0+)
- `redis_evicted_scripts_total` (v7.4+)
- `redis_eviction_exceeded_time_ms_total`
- `redis_keyspace_hits_total`
- `redis_keyspace_misses_total`
- `redis_eventloop_cycles_total` (v7.0+)
- `redis_eventloop_duration_sum_usec_total` (v7.0+)
- `redis_eventloop_duration_cmd_sum_usec_total` (v7.0+)
- `redis_cpu_sys_seconds_total`
- `redis_cpu_user_seconds_total`
- `redis_cpu_sys_children_seconds_total`
- `redis_cpu_user_children_seconds_total`
- `redis_cpu_sys_main_thread_seconds_total`
- `redis_cpu_user_main_thread_seconds_total`
- `redis_unexpected_error_replies`
- `redis_total_error_replies`
- `redis_dump_payload_sanitizations`
- `redis_total_reads_processed`
- `redis_total_writes_processed`
- `redis_io_threaded_reads_processed`
- `redis_io_threaded_writes_processed`
- `redis_client_query_buffer_limit_disconnections_total`
- `redis_client_output_buffer_limit_disconnections_total`
- `redis_reply_buffer_shrinks_total`
- `redis_reply_buffer_expands_total`
- `redis_acl_access_denied_auth_total`
- `redis_acl_access_denied_cmd_total`
- `redis_acl_access_denied_key_total`
- `redis_acl_access_denied_channel_total`

#### Valkey v8 Specific Counter Metrics

- `redis_bf_bloom_defrag_hits_total`
- `redis_bf_bloom_defrag_misses_total`
- `redis_search_worker_pool_suspend_count`
- `redis_search_writer_resumed_count`
- `redis_search_reader_resumed_count`
- `redis_search_writer_suspension_expired_count`
- `redis_search_rdb_load_success_count`
- `redis_search_rdb_load_failure_count`
- `redis_search_rdb_save_success_count`
- `redis_search_rdb_save_failure_count`
- `redis_search_successful_requests_count`
- `redis_search_failure_requests_count`
- `redis_search_hybrid_requests_count`
- `redis_search_inline_filtering_requests_count`
- `redis_search_hnsw_add_exceptions_count`
- `redis_search_hnsw_remove_exceptions_count`
- `redis_search_hnsw_modify_exceptions_count`
- `redis_search_hnsw_search_exceptions_count`
- `redis_search_hnsw_create_exceptions_count`
- `redis_search_vector_externing_entry_count`
- `redis_search_vector_externing_generated_value_count`
- `redis_search_vector_externing_lru_promote_count`
- `redis_search_vector_externing_deferred_entry_count`

#### Database Metrics

- `redis_db_keys{db="db0"}` - total keys per database
- `redis_db_keys_expiring{db="db0"}` - keys with TTL per database
- `redis_db_avg_ttl_seconds{db="db0"}` - average TTL per database

#### Command Stats Metrics

- `redis_commands_total{cmd="get"}` - total calls per command
- `redis_commands_duration_seconds_total{cmd="get"}` - total CPU time per command
- `redis_commands_latencies_usec_bucket{cmd="get"}` - latency histogram per command

#### Key Group Metrics (when `check-key-groups` enabled)

- `redis_key_group_count{db,key_group}` - keys in group
- `redis_key_group_memory_usage_bytes{db,key_group}` - memory per group
- `redis_number_of_distinct_key_groups{db}` - distinct groups
- `redis_last_key_groups_scrape_duration_milliseconds` - scrape duration

#### Key Metrics (when `check-keys`/`check-single-keys` enabled)

- `redis_key_size{db,key}` - size/length of monitored keys
- `redis_key_value{db,key}` - value of numeric keys
- `redis_key_value_as_string{db,key}` - string value as label

#### Exporter-Internal Metrics

- `redis_exporter_last_scrape_connect_time_seconds`
- `redis_exporter_last_scrape_ping_time_seconds`
- `redis_instance_info{role, os, ...}` - instance metadata
- `redis_up` - 1 if reachable, 0 if down
- `redis_config_maxclients` - from CONFIG GET
- `redis_config_maxmemory` - from CONFIG GET
- `redis_config_io_threads` - from CONFIG GET
- `redis_config_key_value{key}` - all config as labels (when `include-config-metrics`)
- `redis_slowlog_length` - current slowlog entries
- `redis_slowlog_last_id` - last slowlog entry ID
- `redis_latency_percentiles_usec{cmd,quantile}` - per-command latency percentiles

### ACL Configuration for Dedicated Exporter User

```
ACL SETUSER exporter -@all +@connection +memory -readonly +strlen +config|get +xinfo +pfcount -quit +zcard +type +xlen -readwrite -command +client -wait +scard +llen +hlen +get +eval +slowlog +cluster|info +cluster|slots +cluster|nodes -hello -echo +info +latency +scan -reset -auth -asking >PASSWORD
```

For Sentinel monitoring:
```
ACL SETUSER exporter -@all +@connection -command +client -hello +info -auth +sentinel|masters +sentinel|replicas +sentinel|slaves +sentinel|sentinels +sentinel|ckquorum >PASSWORD
```

### Prometheus Scrape Configurations

**Single instance:**
```yaml
scrape_configs:
  - job_name: redis_exporter
    static_configs:
      - targets: ['redis-exporter:9121']
```

**Multi-target (multiple Redis instances, one exporter):**
```yaml
scrape_configs:
  - job_name: redis_exporter_targets
    static_configs:
      - targets:
        - redis://first-redis:6379
        - redis://second-redis:6379
        - redis://second-redis:6380
    metrics_path: /scrape
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: redis-exporter:9121

  - job_name: redis_exporter
    static_configs:
      - targets: ['redis-exporter:9121']
```

**Cluster auto-discovery (requires `--is-cluster`):**
```yaml
scrape_configs:
  - job_name: redis_exporter_cluster_nodes
    http_sd_configs:
      - url: http://redis-exporter:9121/discover-cluster-nodes
        refresh_interval: 10m
    metrics_path: /scrape
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: redis-exporter:9121
```

**File-based service discovery:**
```yaml
scrape_configs:
  - job_name: redis_exporter_targets
    file_sd_configs:
      - files:
        - targets-redis-instances.json
    metrics_path: /scrape
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: redis-exporter:9121
```

targets-redis-instances.json:
```json
[
  {
    "targets": ["redis://redis-host-01:6379", "redis://redis-host-02:6379"],
    "labels": {}
  }
]
```

**Kubernetes sidecar pattern:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9121"
    spec:
      containers:
      - name: redis
        image: valkey/valkey:8
        ports:
        - containerPort: 6379
      - name: redis-exporter
        image: oliver006/redis_exporter:latest
        securityContext:
          runAsUser: 59000
          runAsGroup: 59000
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
        ports:
        - containerPort: 9121
```

**Kubernetes instance relabelling (human-readable names):**
```yaml
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_name]
    action: replace
    target_label: instance
    regex: (.*redis.*)
```

---

## 2. Grafana Dashboards

### Official Dashboard from redis_exporter

**Dashboard ID:** 763
**Title:** Redis Dashboard for Prometheus Redis Exporter 1.x
**URL:** https://grafana.com/grafana/dashboards/763
**UID:** `e008bc3f-81a2-40f9-baf2-a33fd8dec7ec`
**Source:** https://github.com/oliver006/redis_exporter/blob/master/contrib/grafana_prometheus_redis_dashboard.json
**Data source:** Prometheus

Panels:
- Max Uptime
- Clients
- Memory Usage
- Total Commands/sec
- Hits/Misses per Sec
- Total Memory Usage
- Network I/O
- Total Items per DB
- Expiring vs Not-Expiring Keys
- Expired/Evicted Keys
- Connected/Blocked Clients
- Average Time Spent by Command/sec
- Total Time Spent by Command/sec

Supports multi-value dropdown for Redis Sentinel environments (view multiple instances simultaneously). Note: single-stat panels (uptime, total memory, clients) do not aggregate across multiple instances.

### Percona PMM Valkey Dashboards

**Repository:** https://github.com/percona/grafana-dashboards/tree/main/dashboards/Valkey
**Count:** 10 dedicated Valkey dashboards

#### Valkey/Redis Overview (UID: `valkey-overview`)
- Min Uptime
- Total Connected/Blocked Clients
- Cumulative Read and Write Rate
- Top 5 Commands by Latency (Last 10s)
- Average Latency
- Total Memory Usage
- Cumulative Network I/O

#### Valkey Clients (`Valkey_Clients.json`)
- Connected/Blocked Clients per service
- Config Max Clients
- Evicted Clients
- Client Input/Output Buffers

#### Valkey Memory (`Valkey_Memory.json`)
- Memory Usage percentage
- Eviction Policy
- Number of Keys
- Total Memory Usage vs Max
- Expired/Evicted Keys rates
- Expiring vs Not-Expiring Keys

#### Valkey Replication (`Valkey_Replication.json`)
- Replication roles (`redis_instance_info`)
- Replica vs Master Offset lag
- Connected Replicas count
- Full/Partial Resyncs
- Backlog Size, First Byte Offset, History Bytes

#### Valkey Load (`Valkey_Load.json`)
- Total Commands/sec
- Read vs Write Rates
- Commands by Type
- Hits/Misses per Sec
- IO Thread Operations
- IO Threads Configured vs Active

#### Valkey Command Details (`Valkey_CommandDetails.json`)
- Commands/sec and Read/Write rates
- Commands by Type breakdown
- Top 10 Commands by Total Time
- Total Time Spent by Command/sec
- Command Latency Percentiles
- Per-command latency histograms (GET, SET, RPOP, LPOP, HSET, LRANGE, PSYNC, RPUSH, LPUSH)

#### Valkey Persistence Details (`Valkey_PersistenceDetails.json`)
- AOF: Enabled, appendfsync policy, loading status, delayed fsyncs, rewrite duration, COW size, success status, async loading
- RDB: Last bgsave timestamp, success status, save config, saves count, changes since last save

#### Valkey Network (`Valkey_Network.json`)
- Network Input/Output rates per service

#### Valkey Slowlog (`Valkey_Slowlog.json`)
- Slowlog length and max length
- Slowlog entries
- Slowlog threshold (slower-than in ms)

#### Valkey Cluster Details (`Valkey_ClusterDetails.json`)
- Slots Status (ok/fail/pfail)
- Cluster State per service
- Cluster Connections and Messages
- Known Nodes
- Replication Roles and Offsets

### Other Known Dashboard IDs

These are community dashboards found on grafana.com:

| ID | Title | Notes |
|----|-------|-------|
| 763 | Redis Dashboard for Prometheus Redis Exporter 1.x | Official, maintained by oliver006 |
| 11835 | Redis Dashboard for Prometheus Redis Exporter | Community variant |
| 14091 | Redis Overview | Compact single-pane overview |
| 12776 | Redis Cluster Overview | Cluster-specific panels |

---

## 3. Prometheus Alerting Rules

### awesome-prometheus-alerts (samber/awesome-prometheus-alerts)

Source: `dist/rules/redis/oliver006-redis-exporter.yml`

```yaml
groups:
  - name: Oliver006RedisExporter
    rules:

      - alert: RedisDown
        expr: 'redis_up == 0'
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: Redis down (instance {{ $labels.instance }})
          description: "Redis instance is down"

      - alert: RedisMissingMaster
        expr: '(count(redis_instance_info{role="master"}) or vector(0)) < 1'
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: Redis missing master (instance {{ $labels.instance }})
          description: "Redis cluster has no node marked as master"

      - alert: RedisTooManyMasters
        expr: 'count(redis_instance_info{role="master"}) > 1'
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: Redis too many masters

      - alert: RedisDisconnectedSlaves
        expr: 'count without (instance, job) (redis_connected_slaves) - sum without (instance, job) (redis_connected_slaves) - 1 > 0'
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: Redis disconnected slaves

      - alert: RedisReplicationBroken
        expr: 'delta(redis_connected_slaves[1m]) < 0'
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: Redis replication broken (lost a slave)

      - alert: RedisClusterFlapping
        expr: 'changes(redis_connected_slaves[1m]) > 1'
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: Redis cluster flapping (replica disconnect/reconnect)

      - alert: RedisMissingBackup
        expr: 'time() - redis_rdb_last_save_timestamp_seconds > 60 * 60 * 48'
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: Redis missing backup (no RDB save in 48 hours)

      - alert: RedisOutOfSystemMemory
        # Requires --include-system-metrics
        expr: 'redis_memory_used_bytes / redis_total_system_memory_bytes * 100 > 90 and redis_total_system_memory_bytes > 0'
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: Redis out of system memory (> 90%)

      - alert: RedisOutOfConfiguredMaxmemory
        expr: 'redis_memory_used_bytes / redis_memory_max_bytes * 100 > 90 and on(instance) redis_memory_max_bytes > 0'
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: Redis out of configured maxmemory (> 90%)

      - alert: RedisTooManyConnections
        expr: 'redis_connected_clients / redis_config_maxclients * 100 > 90 and redis_config_maxclients > 0'
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: Redis too many connections (> 90% used)

      - alert: RedisNotEnoughConnections
        expr: 'redis_connected_clients < 5'
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: Redis not enough connections (< 5)

      - alert: RedisRejectedConnections
        expr: 'increase(redis_rejected_connections_total[1m]) > 5'
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: Redis rejected connections
```

### redis-mixin (from redis_exporter contrib)

Source: `contrib/redis-mixin/` - Jsonnet-based alerts and recording rules

**Alerts:**
```yaml
groups:
  - name: redis
    rules:
      - alert: RedisDown
        expr: 'redis_up == 0'
        for: 5m
        severity: critical

      - alert: RedisOutOfMemory
        expr: 'redis_memory_used_bytes / redis_total_system_memory_bytes * 100 > 90'
        for: 5m
        severity: warning

      - alert: RedisTooManyConnections
        expr: 'redis_connected_clients > <threshold>'
        for: 5m
        severity: warning

      - alert: RedisClusterSlotFail
        expr: 'redis_cluster_slots_fail > 0'
        for: 5m
        severity: warning

      - alert: RedisClusterSlotPfail
        expr: 'redis_cluster_slots_pfail > 0'
        for: 5m
        severity: warning

      - alert: RedisClusterStateNotOk
        expr: 'redis_cluster_state == 0'
        for: 5m
        severity: critical
```

**Recording rules:**
```yaml
groups:
  - name: redis.rules
    rules:
      - record: redis_memory_fragmentation_ratio
        expr: 'redis_memory_used_rss_bytes / redis_memory_used_bytes'
```

### Production-Recommended Alerting Rules (Composite)

Based on community patterns and the above sources, here are production-tested thresholds:

```yaml
groups:
  - name: valkey-critical
    rules:
      # Instance health
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 1m
        labels: { severity: critical }

      - alert: ValkeyClusterStateNotOk
        expr: redis_cluster_state == 0
        for: 30s
        labels: { severity: critical }

      - alert: ValkeyClusterSlotsFail
        expr: redis_cluster_slots_fail > 0
        for: 1m
        labels: { severity: critical }

      # Replication
      - alert: ValkeyNoMaster
        expr: (count(redis_instance_info{role="master"}) or vector(0)) < 1
        for: 30s
        labels: { severity: critical }

      - alert: ValkeyReplicationBroken
        expr: delta(redis_connected_slaves[1m]) < 0
        for: 0m
        labels: { severity: critical }

  - name: valkey-warning
    rules:
      # Memory
      - alert: ValkeyMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes * 100 > 80 and on(instance) redis_memory_max_bytes > 0
        for: 5m
        labels: { severity: warning }

      - alert: ValkeyMemoryCritical
        expr: redis_memory_used_bytes / redis_memory_max_bytes * 100 > 90 and on(instance) redis_memory_max_bytes > 0
        for: 2m
        labels: { severity: critical }

      - alert: ValkeyHighFragmentation
        expr: redis_mem_fragmentation_ratio > 1.5
        for: 10m
        labels: { severity: warning }

      # Connections
      - alert: ValkeyConnectionsNearMax
        expr: redis_connected_clients / redis_config_maxclients * 100 > 80
        for: 5m
        labels: { severity: warning }

      - alert: ValkeyRejectedConnections
        expr: increase(redis_rejected_connections_total[5m]) > 0
        for: 0m
        labels: { severity: warning }

      # Performance
      - alert: ValkeyHighLatency
        expr: redis_latency_percentiles_usec{quantile="99.9"} > 10000
        for: 5m
        labels: { severity: warning }

      - alert: ValkeySlowlogGrowing
        expr: delta(redis_slowlog_length[10m]) > 10
        for: 0m
        labels: { severity: warning }

      - alert: ValkeyHighKeyEviction
        expr: rate(redis_evicted_keys_total[5m]) > 100
        for: 5m
        labels: { severity: warning }

      # Persistence
      - alert: ValkeyRDBSaveStale
        expr: time() - redis_rdb_last_save_timestamp_seconds > 3600
        for: 0m
        labels: { severity: warning }

      - alert: ValkeyRDBSaveFailing
        expr: redis_rdb_last_bgsave_status == 0
        for: 5m
        labels: { severity: critical }

      - alert: ValkeyAOFWriteFailing
        expr: redis_aof_last_write_status == 0
        for: 1m
        labels: { severity: critical }

      # Replication lag
      - alert: ValkeyReplicaLag
        expr: redis_master_repl_offset - on(service_name) group_left() redis_connected_slave_offset_bytes > 10000000
        for: 5m
        labels: { severity: warning }
```

---

## 4. Percona PMM for Valkey

### Overview

Percona Monitoring and Management (PMM) has first-class Valkey support via dedicated dashboards in `percona/grafana-dashboards`. PMM uses `redis_exporter` under the hood as an external service.

### Dashboard Coverage

PMM ships 10 dedicated Valkey dashboards (see Section 2 above for full panel details):
1. **Valkey/Redis Overview** - top-level KPIs
2. **Valkey Clients** - connection management
3. **Valkey Memory** - memory usage and eviction
4. **Valkey Replication** - master/replica lag and resyncs
5. **Valkey Load** - commands/sec, read/write rates, IO threads
6. **Valkey Command Details** - per-command latency, histograms, top commands
7. **Valkey Persistence Details** - AOF and RDB status
8. **Valkey Network** - network I/O rates
9. **Valkey Slowlog** - slowlog entries and thresholds
10. **Valkey Cluster Details** - slot status, cluster state, messages

### Unique PMM Features

- **Per-command latency histograms** - uses `redis_commands_latencies_usec_bucket` for GET, SET, RPOP, LPOP, HSET, LRANGE, PSYNC, RPUSH, LPUSH
- **Latency percentiles** - `redis_latency_percentiles_usec{quantile="99.9"}` for p99.9 monitoring
- **IO thread monitoring** - tracks `redis_io_threaded_reads_processed`, `redis_io_threaded_writes_processed`, configured threads vs active
- **Replica offset lag visualization** - `redis_master_repl_offset - redis_connected_slave_offset_bytes`
- **Top 5 commands by latency** - `topk(5, avg_over_time(redis_latency_percentiles_usec{quantile="99.9"}[10s]))`

### PMM Setup for Valkey

PMM uses the external service mechanism since Valkey is not a built-in PMM service type:

```bash
# Add redis_exporter as external service
pmm-admin add external --service-name=valkey-primary \
  --listen-port=9121 \
  --group=valkey \
  --environment=production
```

---

## 5. APM Integrations

### Datadog

**Integration:** Built-in `redisdb` check (source_type_id: 21)
**Repository:** https://github.com/DataDog/integrations-core/tree/main/redisdb
**Valkey support:** No dedicated `valkey` integration directory; uses `redisdb` for both Redis and Valkey
**Metric prefix:** `redis.*`
**Total metrics:** ~270 metrics tracked in metadata.csv

#### Configuration

```yaml
# conf.d/redisdb.d/conf.yaml
init_config:
instances:
  - host: localhost
    port: 6379
    # username: <USERNAME>  # Redis 6+/Valkey ACL
    # password: <PASSWORD>
```

#### Key Metrics (Datadog-specific names)

**Clients:**
- `redis.net.clients` (connected clients - service check metric)
- `redis.clients.blocked`
- `redis.clients.evicted`
- `redis.clients.watching`

**Memory:**
- `redis.mem.used` / `redis.mem.rss` / `redis.mem.peak`
- `redis.mem.fragmentation_ratio`
- `redis.allocator.active` / `.allocated` / `.resident`

**Performance:**
- `redis.net.commands` / `redis.net.instantaneous_ops_per_sec`
- `redis.command.calls{command:<cmd>}` / `redis.command.usec_per_call{command:<cmd>}`
- `redis.cpu.sys` / `redis.cpu.user`
- `redis.eventloop.cycles` / `redis.eventloop.duration_cmd_sum`

**Persistence:**
- `redis.rdb.changes_since_last` / `redis.rdb.bgsave_in_progress` / `redis.rdb.last_save_time`
- `redis.aof.size` / `redis.aof.buffer_length` / `redis.aof.last_rewrite_time`

**Replication:**
- `redis.replication.master_link_down_since_seconds`
- `redis.replication.delay` (offset-based lag)

**Cluster:**
- `redis.cluster.state` / `redis.cluster.slots_ok` / `redis.cluster.slots_fail`

#### Datadog Features Beyond Basic Metrics

- **Log collection** from Redis log files
- **APM Trace integration** - distributed tracing through Redis client libraries
- **Process signatures** - auto-detects `redis-server` processes
- **Built-in monitors** - "Memory consumption is high" threshold alert
- **Saved views** - error/warning status, PID overview, Redis patterns

### New Relic

**Integration:** `nri-redis` (New Relic Infrastructure integration)
**Repository:** https://github.com/newrelic/nri-redis
**Category:** Community Plus (actively maintained)

#### Key Metrics (New Relic naming)

| NR Metric | Type | Description |
|-----------|------|-------------|
| `net.connectedClients` | Gauge | Connected clients |
| `net.blockedClients` | Gauge | Blocked clients |
| `system.usedMemoryBytes` | Gauge | Memory used |
| `system.usedMemoryRssBytes` | Gauge | RSS memory |
| `system.usedMemoryPeakBytes` | Gauge | Peak memory |
| `system.memFragmentationRatio` | Gauge | Fragmentation ratio |
| `system.totalSystemMemoryBytes` | Gauge | Total system memory |
| `db.rdbChangesSinceLastSave` | Gauge | Changes since last RDB save |
| `db.keyspaceHitsPerSecond` | Rate | Hit rate |
| `db.keyspaceMissesPerSecond` | Rate | Miss rate |
| `db.expiredKeysPerSecond` | Rate | Expiry rate |
| `db.evictedKeysPerSecond` | Rate | Eviction rate |
| `net.commandsProcessedPerSecond` | Rate | Command throughput |
| `net.connectionsReceivedPerSecond` | Rate | Connection rate |
| `net.inputBytesPerSecond` | Rate | Input throughput |
| `net.outputBytesPerSecond` | Rate | Output throughput |
| `software.uptimeMilliseconds` | Gauge | Uptime |
| `cluster.connectedSlaves` | Gauge | Connected replicas |
| `cluster.roles` | Attribute | master/slave |

#### Configuration

```yaml
# redis-config.yml
integration_name: com.newrelic.redis
instances:
  - name: redis-metrics
    command: metrics
    arguments:
      hostname: localhost
      port: 6379
      # password: ""
      # keys: '{"0":["<KEY_1>"],"1":["<KEY_2>"]}'
      # keys_limit: 30
      # renamed_commands: '{"CONFIG":"<RENAMED>"}'
    labels:
      env: production
      role: primary
```

### Elastic/ELK Stack

Elastic provides a `redis` module in both Metricbeat and Filebeat:
- **Metricbeat redis module** - collects INFO, SLOWLOG, keyspace stats
- **Filebeat redis module** - parses Redis log files, slowlog entries

### Zabbix

Zabbix has built-in Redis templates:
- Template name: "Redis by Zabbix agent 2"
- Uses `redis.info[]` items for all INFO sections
- Supports `redis.config[]` for config monitoring
- Built-in triggers for memory, connections, replication

---

## 6. Valkey-Specific Monitoring Considerations

### INFO Command Sections (Valkey 9.x)

Valkey's `INFO` command returns these sections:
- `server` - general server info, version, uptime, mode
- `clients` - connected/blocked clients, buffer stats
- `memory` - memory allocation, fragmentation, RSS
- `persistence` - RDB/AOF status, save timestamps
- `stats` - commands processed, connections, keyspace hits/misses
- `replication` - master/replica state, offset, backlog
- `cpu` - system/user CPU consumption
- `errorstats` - error counts by type
- `commandstats` - per-command call counts and duration
- `latencystats` - per-command latency histograms (v7+)
- `cluster` - cluster state, slots, messages
- `keyspace` - per-database key counts
- `modules` - loaded module information

### Valkey-Specific Stats Not in Redis

Valkey server.c includes these fields in its stats section:
- `expired_fields` - expired hash fields count (Valkey field-level TTL)
- `expired_keys_with_volatile_items_stale_perc` - stale percentage for volatile keys
- `evicted_scripts` - evicted scripts count (v7.4+/Valkey 8+)
- `io_threads_active` - active IO threads gauge

### Valkey Latency Monitoring Subsystem

Built-in latency monitoring (separate from redis_exporter):

```
CONFIG SET latency-monitor-threshold 100
```

Commands:
- `LATENCY LATEST` - latest spikes per event
- `LATENCY HISTORY <event>` - time series for an event
- `LATENCY RESET [event...]` - clear history
- `LATENCY GRAPH <event>` - ASCII art visualization
- `LATENCY DOCTOR` - human-readable analysis

Monitored events:
- `command` - regular commands
- `fast-command` - O(1)/O(log N) commands
- `fork` - fork(2) system call
- `rdb-unlink-temp-file` - unlink(2) call
- `aof-fsync-always` - fsync(2) with appendfsync=always
- `aof-write` - generic AOF write(2)
- `aof-write-pending-fsync` - write(2) with pending fsync
- `aof-write-active-child` - write(2) with active child
- `aof-write-alone` - write(2) alone
- `aof-fstat` - fstat(2) call
- `aof-rename` - rename(2) after BGREWRITEAOF
- `aof-rewrite-diff-write` - diff writing during BGREWRITEAOF
- `active-defrag-cycle` - active defragmentation
- `expire-cycle` - key expiration
- `eviction-cycle` - eviction processing
- `eviction-del` - deletes during eviction

### Valkey Search Module Metrics (v8+)

When using Valkey Search (`INFO SEARCH`), additional monitoring metrics:

| Category | Metrics |
|----------|---------|
| Index Stats | `search_number_of_indexes`, `search_number_of_attributes`, `search_total_indexed_documents`, `search_total_active_write_threads` |
| Memory | `search_used_memory_bytes`, `search_index_reclaimable_memory`, `search_used_memory_human` |
| Queries | `search_successful_requests_count`, `search_failure_requests_count`, `search_hybrid_requests_count`, `search_vector_requests_count`, `search_nonvector_requests_count` |
| RDB | `search_rdb_load_success_cnt`, `search_rdb_load_failure_cnt`, `search_rdb_save_success_cnt`, `search_rdb_save_failure_cnt` |
| Thread Pool | `search_worker_pool_suspend_cnt`, `search_reader_resumed_cnt`, `search_writer_resumed_cnt`, `search_query_queue_size`, `search_writer_queue_size` |
| Vector | `search_vector_externing_entry_count`, HNSW exception counts |
| Indexing | `search_background_indexing_status` (IN_PROGRESS/NO_ACTIVITY), `search_total_indexing_time` |

---

## 7. Production PromQL Queries

### Throughput and Performance

```promql
# Commands per second
rate(redis_commands_processed_total[5m])

# Commands per second by type
sum by(cmd) (rate(redis_commands_total[1m]))

# Read vs write rate
sum(rate(redis_total_reads_processed[5m]))
sum(rate(redis_total_writes_processed[5m]))

# Hit ratio
redis_keyspace_hits_total / (redis_keyspace_hits_total + redis_keyspace_misses_total) * 100

# Hit rate over time
irate(redis_keyspace_hits_total[5m]) / (irate(redis_keyspace_hits_total[5m]) + irate(redis_keyspace_misses_total[5m]))

# Top 5 commands by p99.9 latency
topk(5, avg_over_time(redis_latency_percentiles_usec{quantile="99.9", cmd!~"config\\|get|bgsave|bgrewriteaof"}[10s]))

# Average latency across commands
avg(redis_latency_percentiles_usec{cmd!~"config\\|get|bgsave|bgrewriteaof|save|flushdb|flushall"})

# Per-command total time spent/sec
sum by(cmd) (irate(redis_commands_duration_seconds_total[1m]))

# Top 10 commands by total CPU time
topk(10, sum by(cmd) (redis_commands_duration_seconds_total) != 0)

# Network I/O rates
irate(redis_net_input_bytes_total[5m])
irate(redis_net_output_bytes_total[5m])

# Eventloop duration (v7+)
rate(redis_eventloop_duration_sum_usec_total[5m]) / rate(redis_eventloop_cycles_total[5m])
```

### Memory

```promql
# Memory utilization percentage
100 * redis_memory_used_bytes / redis_memory_max_bytes

# Fragmentation ratio (recording rule recommended)
redis_memory_used_rss_bytes / redis_memory_used_bytes

# Memory breakdown
redis_memory_used_overhead_bytes
redis_memory_used_dataset_bytes
redis_memory_used_scripts_bytes
redis_mem_clients_normal
redis_mem_clients_slaves
redis_mem_replication_backlog_bytes
redis_mem_aof_buffer_bytes

# Eviction rate
rate(redis_evicted_keys_total[5m])

# Expired keys rate
rate(redis_expired_keys_total[5m])

# Keys with vs without TTL
sum(redis_db_keys) - sum(redis_db_keys_expiring)
sum(redis_db_keys_expiring)

# Total keys across all databases
sum(redis_db_keys)
```

### Connections

```promql
# Connection utilization
redis_connected_clients / redis_config_maxclients * 100

# Connection rate
rate(redis_connections_received_total[5m])

# Rejected connections
increase(redis_rejected_connections_total[5m])

# Blocked clients
redis_blocked_clients

# Client buffer sizes (rates for trend)
rate(redis_client_recent_max_input_buffer_bytes[5m])
rate(redis_client_recent_max_output_buffer_bytes[5m])

# Evicted clients
redis_evicted_clients_total
```

### Replication

```promql
# Replica lag in bytes
redis_master_repl_offset - on(service_name) group_left(slave_ip, slave_port) redis_connected_slave_offset_bytes

# Connected replicas
redis_connected_slaves

# Full resyncs (should be rare)
redis_replica_resyncs_full

# Partial resyncs
redis_replica_partial_resync_accepted
redis_replica_partial_resync_denied

# Backlog usage
redis_repl_backlog_history_bytes / redis_replication_backlog_bytes
```

### Persistence

```promql
# Time since last RDB save
time() - redis_rdb_last_save_timestamp_seconds

# RDB save status (0 = error, 1 = ok)
redis_rdb_last_bgsave_status

# AOF status
redis_aof_last_write_status
redis_aof_last_bgrewrite_status

# AOF size growth
rate(redis_aof_current_size_bytes[5m])

# Pending AOF fsyncs
redis_aof_pending_bio_fsync

# Changes since last save
redis_rdb_changes_since_last_save
```

### Cluster

```promql
# Cluster state (1 = ok, 0 = fail)
redis_cluster_state

# Slot distribution
redis_cluster_slots_ok
redis_cluster_slots_fail
redis_cluster_slots_pfail

# Cluster message rate
rate(redis_cluster_messages_sent_total[5m])
rate(redis_cluster_messages_received_total[5m])
```

### IO Threads (Valkey/Redis 7+)

```promql
# IO thread activity
irate(redis_io_threaded_reads_processed[5m])
irate(redis_io_threaded_writes_processed[5m])

# Configured vs active threads
redis_config_io_threads
redis_io_threads_active
```

### Slowlog

```promql
# Slowlog length growth
redis_slowlog_length

# Slowlog growth rate
delta(redis_slowlog_length[10m])
```

---

## 8. Monitoring Architecture Patterns

### Pattern 1: Single Exporter, Multiple Instances

Best for: 5-50 instances, centralized management

```
[Valkey 1] ----\
[Valkey 2] ------> [redis_exporter] <--- [Prometheus] ---> [Grafana]
[Valkey 3] ----/     (multi-target)
```

Use `--redis.addr=` (empty) with `/scrape?target=` endpoint.

### Pattern 2: Sidecar Per Instance

Best for: Kubernetes, per-pod monitoring, >50 instances

```
[Pod: Valkey + Exporter] <--- [Prometheus ServiceDiscovery] ---> [Grafana]
[Pod: Valkey + Exporter] <---/
```

Use Kubernetes annotations `prometheus.io/scrape: "true"` and `prometheus.io/port: "9121"`.

### Pattern 3: Cluster Auto-Discovery

Best for: Valkey Cluster deployments

```
[Valkey Cluster] --cluster-nodes--> [redis_exporter --is-cluster]
                                        |
                                  /discover-cluster-nodes
                                        |
                                    [Prometheus http_sd_configs]
```

### Pattern 4: PMM Integration

Best for: Organizations already using Percona PMM for database monitoring

```
[Valkey] <--- [redis_exporter] <--- [PMM Server (Prometheus + Grafana)]
```

Register via `pmm-admin add external`.

### Recommended Scrape Intervals

| Metric Type | Interval | Rationale |
|-------------|----------|-----------|
| Standard INFO metrics | 15s-30s | Low overhead, good resolution |
| Key-level metrics (`check-keys`) | 60s-120s | SCAN can be expensive on large keyspaces |
| Key group aggregation | 120s-300s | Full keyspace scan with Lua |
| Config metrics | 60s | Rarely changes |
| Slowlog metrics | 30s | Catch transient slow commands |

---

## 9. Version Compatibility Matrix

| Feature | Redis 6.x | Redis 7.0+ | Valkey 7.x | Valkey 8.x | Valkey 9.x |
|---------|-----------|------------|------------|------------|------------|
| Basic INFO metrics | Yes | Yes | Yes | Yes | Yes |
| ACL-based auth | Yes | Yes | Yes | Yes | Yes |
| commandstats | Yes | Yes | Yes | Yes | Yes |
| latencystats histograms | No | Yes | Yes | Yes | Yes |
| errorstats | No | Yes | Yes | Yes | Yes |
| IO threads metrics | No | Yes | Yes | Yes | Yes |
| eventloop metrics | No | Yes | Yes | Yes | Yes |
| Field-level TTL stats | No | No | No | Yes | Yes |
| Search module metrics | No | With RediSearch | No | Yes | Yes |
| Bloom filter defrag metrics | No | No | No | Yes | Yes |
| `valkey://` URI scheme | N/A | N/A | Yes | Yes | Yes |

---

## 10. Source URLs

- redis_exporter repo: https://github.com/oliver006/redis_exporter
- redis_exporter releases: https://github.com/oliver006/redis_exporter/releases
- Grafana Dashboard 763: https://grafana.com/grafana/dashboards/763
- awesome-prometheus-alerts Redis rules: https://github.com/samber/awesome-prometheus-alerts/blob/master/dist/rules/redis/oliver006-redis-exporter.yml
- redis_exporter mixin: https://github.com/oliver006/redis_exporter/tree/master/contrib/redis-mixin
- Percona Valkey dashboards: https://github.com/percona/grafana-dashboards/tree/main/dashboards/Valkey
- Datadog Redis integration: https://github.com/DataDog/integrations-core/tree/main/redisdb
- New Relic Redis integration: https://github.com/newrelic/nri-redis
- Valkey latency monitoring docs: https://github.com/valkey-io/valkey-doc/blob/main/topics/latency-monitor.md
- Valkey search monitoring: https://github.com/valkey-io/valkey-doc/blob/main/topics/search-monitoring.md
- Valkey admin guide: https://github.com/valkey-io/valkey-doc/blob/main/topics/admin.md
- Datadog Redis monitoring blog: https://www.datadoghq.com/blog/how-to-monitor-redis-performance-metrics
