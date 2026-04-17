# Production Deployment Checklist

Use as a pre-go-live audit. Items marked **V** are Valkey-specific defaults/behaviors to verify; the rest are the Redis-standard operator checklist.

## Verify script

```sh
#!/usr/bin/env bash
set -eu
H=${1:-127.0.0.1} P=${2:-6379} ${3:+A="-a $3"}
cli="valkey-cli -h $H -p $P ${A:-} --no-auth-warning"

g() { $cli CONFIG GET "$1" | tail -1; }
echo "maxmemory         : $(g maxmemory)"
echo "maxmemory-policy  : $(g maxmemory-policy)"
echo "appendonly        : $(g appendonly)"
echo "protected-mode    : $(g protected-mode)"
echo "io-threads        : $(g io-threads)"
echo "lazyfree-lazy-*   : $($cli CONFIG GET 'lazyfree-lazy-*' | paste - - | head -5)"  # V: all should be 'yes'
echo "extended-redis-*  : $(g extended-redis-compatibility)"                            # V: off unless migrating
echo "rdb-version-check : $(g rdb-version-check)"                                       # V
echo "cluster_enabled   : $($cli INFO cluster      | grep cluster_enabled)"
echo "connected_slaves  : $($cli INFO replication  | grep connected_slaves)"
echo "used_memory_human : $($cli INFO memory       | grep used_memory_human:)"
[ "$(g maxmemory)" = "0" ] && echo "[WARN] maxmemory is unlimited"
```

## System

- [ ] `vm.overcommit_memory=1` (BGSAVE/BGREWRITEAOF fork path needs it).
- [ ] `net.core.somaxconn ≥ 65535` (≥ `tcp-backlog`).
- [ ] Transparent huge pages = `never` - non-negotiable. Valkey warns at startup if enabled.
- [ ] Swap enabled with `vm.swappiness=1` - safety net, not a runtime path.
- [ ] `ulimit -n` ≥ `maxclients + 32`. In systemd: `LimitNOFILE=65535`.
- [ ] Valkey runs as unprivileged `valkey` user; binary not setuid-root.

## Configuration

- [ ] **`maxmemory` set explicitly** - never leave at `0` in production.
- [ ] Eviction policy matches workload: `allkeys-lru`/`allkeys-lfu` for cache, `noeviction` for primary data store, `volatile-*` only if every cache key has a TTL.
- [ ] `maxmemory-clients 5%` to cap aggregate client-buffer memory.
- [ ] `tcp-keepalive 300` (lower in NAT-aggressive environments).
- [ ] Persistence chosen and restore tested: cache-only (`save ""`, `appendonly no`), durable (`appendonly yes` + `appendfsync everysec` + `aof-use-rdb-preamble yes`), or hybrid.
- [ ] `latency-monitor-threshold` > 0 (typical: 50-100 ms) - required for `LATENCY DOCTOR`.
- [ ] COMMANDLOG thresholds set: `commandlog-execution-slower-than 10000` + the two large-* thresholds. Review regularly. **V**
- [ ] `hide-user-data-from-log yes` (Valkey default; verify not flipped to `no` for debugging leftover). **V**

## Security

- [ ] ACL users per service, no app traffic on `default`.
- [ ] TLS enabled for client and replication/cluster-bus traffic. `tls-auto-reload-interval > 0` for automated cert rotation. **V**
- [ ] `bind` to explicit private IPs, not `0.0.0.0`.
- [ ] `protected-mode yes`.
- [ ] Firewall scoped to client port, Sentinel port (26379), and cluster bus port (client+10000).
- [ ] Default user disabled or strong password; dangerous commands (`FLUSHALL`, `DEBUG`, `SHUTDOWN`, `CONFIG`) restricted via ACL or `rename-command`.

## Monitoring

- [ ] Prometheus exporter (`oliver006/redis_exporter`) running; ACL user scoped to `+info +ping +config|get +client|list +commandlog|get +commandlog|len +latency|latest +latency|history`.
- [ ] Grafana Redis dashboard (ID `11835` or `763`) imported. Add panels for Valkey-only metrics (`expired_fields`, `evicted_scripts`, `io_threads_active`, `cluster_stats_bytes_*`). **V**
- [ ] Alerts: instance down, `used_memory / maxmemory > 0.9`, `rejected_connections` rate > 0, replication link down, replication lag > 5 s warn / 30 s crit, `rdb_last_bgsave_status != ok`, latency p99 spike, TLS cert expiry at 30 / 7 days. **V** (TLS cert alerts via `tls_server_cert_expire_time` etc.)
- [ ] COMMANDLOG reviewed periodically - `COMMANDLOG GET 25 slow / large-request / large-reply`.

## Backup

- [ ] RDB shipped off-host (S3/GCS/Azure Blob or remote FS).
- [ ] Retention policy written down (e.g., hourly 24 h, daily 30 d).
- [ ] Restore procedure tested in staging at least once; restore time documented.
- [ ] Alerting on backup age exceeding RPO and on upload failures.

## High availability

- [ ] Sentinel ≥ 3 instances on independent failure domains OR Cluster ≥ 3 primaries each with 1 replica.
- [ ] `min-replicas-to-write` ≥ 1 and `min-replicas-max-lag 10` - bounds split-brain write-loss window.
- [ ] Failover tested: manual `SENTINEL FAILOVER` or `CLUSTER FAILOVER` in staging, clients reconnect, monitoring catches the event.
- [ ] `repl-backlog-size` sized per write rate + disconnect window (see `replication-tuning.md`).
- [ ] On Kubernetes: PodDisruptionBudget with `maxUnavailable: 1`.

## Kubernetes-specific

- [ ] Kernel tuning via DaemonSet or privileged init container (sysctls aren't settable in all K8s distros).
- [ ] StorageClass is SSD-backed; PVC size ≥ 2× `maxmemory`.
- [ ] Pod anti-affinity across nodes or AZs.
- [ ] Memory limit ≥ 2× request (fork COW headroom). No CPU limit on latency-sensitive workloads (CFS throttling spikes tail latency).
- [ ] Startup probe's `failureThreshold * periodSeconds` > worst-case load time (AOF replay on a large dataset can take minutes).
- [ ] Cluster bus port (+10000) reachable between pods - handled by `hostNetwork`, `cluster-announce-*`, or an operator.

## Persistence math to sanity-check

- Fork COW can approach 2× dataset on write-heavy workloads. Plan `maxmemory` at 60-70% of node RAM in that case.
- Page table overhead: `dataset_bytes / 4096 * 8`. 24 GB → 48 MB. Visible in `rdb_last_cow_size` during save.
- `appendfsync everysec` worst case is ~2 s of loss (one second normally; up to one more if the fsync itself takes a second).
- `no-appendfsync-on-rewrite yes` silently downgrades durability to `appendfsync no` during rewrites. Set `no` if `always`/`everysec` promises matter.
- Valkey: recovery from `appendonly yes` + `aof-use-rdb-preamble yes` is near-RDB speed plus AOF tail replay. RDB-only: ~2-5 s per GB on SSD.

## Pre-upgrade

- [ ] Current version captured: `INFO server | grep valkey_version`.
- [ ] Fresh RDB/AOF backup taken immediately before the upgrade.
- [ ] Release notes read; note deprecated configs and any default changes.
- [ ] Rollback plan documented - for cross-RDB-major upgrades (Valkey 9.0 writes RDB 80 once hash field TTL is in use), downgrade is a restore-from-backup, not an in-place revert.
- [ ] Replica-version compatibility verified (`upgrades-compatibility.md`).
- [ ] **Valkey 9.0**: use **9.0.3+** only. 9.0.0-9.0.1 had hash field TTL bugs (memory leaks, crashes, data corruption). **V**
