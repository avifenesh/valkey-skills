# Production Deployment Checklist

Use when preparing a Valkey deployment for production, auditing an existing setup, or verifying readiness before go-live.

---

## Quick-Verify Script

Run against a live instance to check the most critical production settings:

```bash
#!/usr/bin/env bash
# Usage: ./verify-valkey.sh [host] [port] [password]
H=${1:-127.0.0.1}; P=${2:-6379}; A=${3:+"-a $3"}
CLI="valkey-cli -h $H -p $P $A --no-auth-warning"
echo "=== Valkey Production Verify ==="
echo "maxmemory:        $($CLI CONFIG GET maxmemory | tail -1)"
echo "maxmemory-policy: $($CLI CONFIG GET maxmemory-policy | tail -1)"
echo "appendonly:        $($CLI CONFIG GET appendonly | tail -1)"
echo "tcp-keepalive:     $($CLI CONFIG GET tcp-keepalive | tail -1)"
echo "protected-mode:    $($CLI CONFIG GET protected-mode | tail -1)"
echo "connected_slaves:  $($CLI INFO replication | grep connected_slaves)"
echo "cluster_enabled:   $($CLI INFO cluster | grep cluster_enabled)"
echo "io_threads:        $($CLI CONFIG GET io-threads | tail -1)"
echo "used_memory_human: $($CLI INFO memory | grep used_memory_human:)"
echo "uptime_in_days:    $($CLI INFO server | grep uptime_in_days)"
# [WARN] if maxmemory is 0 (unlimited)
MM=$($CLI CONFIG GET maxmemory | tail -1)
[ "$MM" = "0" ] && echo "[WARN] maxmemory is unlimited - set it explicitly"
echo "=== Done ==="
```

---

## System

- [ ] **vm.overcommit_memory = 1** - prevents BGSAVE/BGREWRITEAOF fork failures. Set in `/etc/sysctl.d/99-valkey.conf` or via init container in Kubernetes.
- [ ] **net.core.somaxconn >= 65535** - TCP listen backlog. Must match or exceed `tcp-backlog` config.
- [ ] **Transparent huge pages disabled** - THP causes latency spikes. `echo never > /sys/kernel/mm/transparent_hugepage/enabled`. Make persistent via systemd unit or init container.
- [ ] **Swap enabled** - safety net to prevent OOM kills. Swap is slow but better than process death. Set `vm.swappiness=1` to minimize swap use under normal operation.
- [ ] **File descriptor limit >= `maxclients` + 32** - Valkey needs file descriptors for client connections plus internal file handles. Set via `LimitNOFILE` in systemd or `ulimit -n`.
- [ ] **Valkey runs as unprivileged user** - never run as root. Create a dedicated `valkey` user with `--system --no-create-home --shell /usr/sbin/nologin`.

## Configuration

- [ ] **`maxmemory` set explicitly** - never leave `maxmemory` unlimited in production. Valkey will grow until the OS kills it.
- [ ] **Eviction policy chosen for workload** - `allkeys-lru` for general cache, `noeviction` for primary data store, `volatile-ttl` for session stores. Source: `maxmemory_policy_enum` in `src/config.c` lists all 8 policies.
- [ ] **`maxmemory-clients` 5%** - caps aggregate client buffer memory. Prevents a few clients from consuming all memory with large pipelines or pub/sub.
- [ ] **tcp-keepalive 300** - detects dead connections. Lower values (60-120) for environments with aggressive NAT timeouts.
- [ ] **Persistence strategy configured and tested** - choose RDB, AOF, or hybrid. Test restore from backup before go-live.
  - Cache-only: `save ""`, `appendonly no`
  - Durable store: `appendonly yes`, `appendfsync everysec`, `aof-use-rdb-preamble yes`
- [ ] **latency-monitor-threshold enabled** - set to 50-100ms. Enables `LATENCY DOCTOR` and `LATENCY LATEST` diagnostics.
- [ ] **Commandlog configured** - `commandlog-execution-slower-than 10000` (10ms), `commandlog-slow-execution-max-len 128`. Legacy `slowlog-*` aliases also work. Review periodically.

## Security

- [ ] **ACLs configured per service** - do not use the default user for application connections. Create per-service users with minimal permissions.
- [ ] **TLS enabled** - encrypt client-server and replication traffic. Build with `BUILD_TLS=yes` or use Docker images with TLS support.
- [ ] **Bound to specific interfaces** - `bind 127.0.0.1 -::1` or specific private IPs. Never bind to `0.0.0.0` without authentication.
- [ ] **protected-mode yes** - rejects external connections when no password is set. Default is on; verify it stays on.
- [ ] **Firewall rules in place** - restrict access to port 6379 (client), 26379 (Sentinel), and cluster bus port (client+10000).
- [ ] **Default user restricted** - either disable the default user or set a strong password. Use ACL users for all connections.
- [ ] **Dangerous commands renamed or disabled** - consider ACL rules to restrict `FLUSHALL`, `FLUSHDB`, `DEBUG`, `SHUTDOWN`, `CONFIG` for non-admin users.

## Monitoring

- [ ] **Prometheus exporter running** - deploy redis_exporter (oliver006/redis_exporter) as a sidecar or standalone. Exposes metrics on port 9121.
- [ ] **Grafana dashboards imported** - community dashboards (ID 11835 or 763) cover key metrics.
- [ ] **Alerts configured** - critical alerts at minimum:
  - Instance down (`redis_up == 0`)
  - Memory usage > 90% of maxmemory
  - Replication lag increasing
  - Replication link down
  - BGSAVE failures
  - Rejected connections
  - Latency spikes (p99 > threshold)
- [ ] **Commandlog reviewed periodically** - `COMMANDLOG GET 25 slow` to catch expensive commands. `SLOWLOG GET 25` also works.
- [ ] **LATENCY DOCTOR available** - requires `latency-monitor-threshold > 0`.

## Backup

- [ ] **RDB snapshots shipped off-host** - do not rely on local snapshots alone. Copy to object storage (S3, GCS, Azure Blob) or remote filesystem.
- [ ] **Backup retention policy** - hourly snapshots for 24 hours, daily for 30 days. Adjust based on RPO requirements.
- [ ] **Restore procedure tested** - perform a test restore at least once before production. Verify data integrity after restore. Document the procedure.
- [ ] **Backup monitoring** - alert on `rdb_last_bgsave_status != ok` and on backup age exceeding threshold.

## High Availability

- [ ] **Sentinel or Cluster deployed** - standalone instances have no automatic failover.
  - Sentinel: minimum 3 instances on independent infrastructure
  - Cluster: minimum 3 primaries with 1 replica each (6 nodes)
- [ ] **`min-replicas-to-write` configured** - prevents split-brain writes. Set to 1 (or N-1 for N replicas). Combine with `min-replicas-max-lag` (e.g., 10 seconds).
- [ ] **Failover tested in staging** - trigger a manual failover and verify:
  - Clients reconnect automatically
  - Data integrity preserved
  - Monitoring detects the event
  - Recovery time within SLA
- [ ] **Replication backlog sized appropriately** - `repl-backlog-size` should be proportional to write rate and expected disconnection time. Formula: `write_rate_bytes_per_second * max_expected_disconnect_seconds`.
- [ ] **Pod Disruption Budget (Kubernetes)** - `maxUnavailable: 1` to prevent simultaneous eviction during node drains.

## Kubernetes-Specific

- [ ] **Kernel tuning applied** - `vm.overcommit_memory`, `somaxconn`, THP disabled via init container or DaemonSet.
- [ ] **Persistent volumes on SSD** - use SSD-backed StorageClass. PVC size >= 2x `maxmemory`.
- [ ] **Pod anti-affinity configured** - spread Valkey pods across nodes or availability zones.
- [ ] **Resource requests and limits set** - memory limits >= 2x requests for fork headroom. Avoid CPU limits for latency-sensitive workloads.
- [ ] **Startup probe configured** - prevents liveness probe kills during AOF/RDB loading. Set `failureThreshold * periodSeconds` to exceed maximum load time.
- [ ] **Cluster mode NAT handled** - use `cluster-announce-ip`, `hostNetwork`, or an operator that manages cluster bus routing.

## Persistence Specifics

- [ ] **Fork memory headroom verified** - COW can use up to 2x memory during BGSAVE/AOF rewrite. Page table overhead = `dataset_size / 4KB * 8 bytes`. For 24GB dataset, that is 48MB page table alone.
- [ ] **`appendfsync everysec` worst case understood** - actual worst-case data loss is 2 seconds (not 1 second). If background fsync takes > 1s, writes are delayed up to an additional second.
- [ ] **`no-appendfsync-on-rewrite` implications known** - if set to `yes`, durability drops to `appendfsync no` during rewrites (up to 30s data loss).
- [ ] **Recovery time estimated** - 1GB loads in 2-5s on SSD, 100GB in 3-6 minutes. AOF is slower unless using hybrid (`aof-use-rdb-preamble yes`).
- [ ] **Off-site backup verified** - verify upload size matches, use independent alerting on backup transfer failures.

## Pre-Upgrade Verification

- [ ] **Current version documented** - `INFO server | grep valkey_version`
- [ ] **RDB/AOF backup taken** - fresh backup before any upgrade
- [ ] **Release notes reviewed** - check for breaking changes, deprecated configs, new defaults
- [ ] **Rollback plan documented** - know how to revert if the upgrade fails
- [ ] **Replica versions compatible** - see [upgrades/compatibility.md](upgrades/compatibility.md)
- [ ] **Valkey 9.0: use 9.0.3+** - 9.0.0-9.0.1 had critical hash field expiration bugs (memory leaks, crashes, data corruption). Sentinel 9.0+ requires `+failover` ACL permission (permanent requirement, not a regression).

## See Also

- [Configuration Essentials](configuration/essentials.md) - all config defaults
- [Security Hardening](security/hardening.md) - defense in depth
- [Security ACL](security/acl.md) - per-user access control
- [Security TLS](security/tls.md) - encryption in transit
- [Monitoring Metrics](monitoring/metrics.md) - key metrics and thresholds
- [Monitoring Alerting](monitoring/alerting.md) - Prometheus alert rules
- [Monitoring Commandlog](monitoring/commandlog.md) - commandlog configuration and audit
- [Troubleshooting Diagnostics](troubleshooting/diagnostics.md) - 7-phase investigation runbook
- [Persistence AOF](persistence/aof.md) - AOF configuration
- [Persistence RDB](persistence/rdb.md) - RDB configuration
- [Persistence Backup](persistence/backup-recovery.md) - backup procedures
- [Durability vs Performance](performance/durability.md) - persistence trade-off spectrum
- [Replication Safety](replication/safety.md) - write safety, split-brain prevention
- [Capacity Planning](operations/capacity-planning.md) - memory and connection sizing
- [Upgrades Rolling](upgrades/rolling-upgrade.md) - zero-downtime upgrade procedures
- [Upgrades Migration](upgrades/migration.md) - Redis to Valkey migration
- [Upgrades Compatibility](upgrades/compatibility.md) - version compatibility
- [Kubernetes Helm](kubernetes/helm.md) - Helm chart deployment
- [Kubernetes Operators](kubernetes/operators.md) - CRD-based deployment
- [Kubernetes StatefulSets](kubernetes/statefulset.md) - StatefulSet patterns
- [Kubernetes Tuning](kubernetes/tuning-k8s.md) - kernel tuning in K8s
