# Operations

Use when sizing an instance, planning capacity, or running the pre-go-live audit.

## Capacity defaults (source-verified)

| Parameter | Default |
|-----------|---------|
| `maxmemory` | `0` (unlimited) |
| `maxclients` | `10000` |
| Client output buffer - replica | `256mb hard, 64mb soft, 60s` |
| Client output buffer - pubsub | `32mb hard, 8mb soft, 60s` |

Valkey defaults `hash-max-listpack-entries 512` (vs Redis 128) - hash memory estimates may be lower than Redis for the same workload because more hashes stay compact.

## Sizing

Set `maxmemory` to 60-70% of available RAM. Remainder covers fork COW (up to 100% of `used_memory` during BGSAVE on write-heavy), client buffers, replication backlog, and OS.

```
total = maxmemory
      + fork COW (30-100% of maxmemory)
      + replica buffers (N * 256MB)
      + pubsub buffers (subscribers * 32MB)
      + replication backlog
      + OS (1-2GB)
```

Prefer more smaller nodes. Smaller nodes mean faster BGSAVE, faster failover, faster slot migration, and lower blast radius. Start scaling when any node exceeds 60% of `maxmemory`.

## Persistence math to sanity-check

- Fork COW can approach 2× dataset on write-heavy workloads - plan `maxmemory` at 60-70% of node RAM.
- Page table overhead: `dataset_bytes / 4096 * 8`. 24 GB → 48 MB. Visible in `rdb_last_cow_size` during save.
- `appendfsync everysec` worst case is ~2 s of loss (one second normally; up to one more if the fsync itself takes a second).
- `no-appendfsync-on-rewrite yes` silently downgrades durability to `appendfsync no` during rewrites. Set `no` if `always`/`everysec` promises matter.
- Recovery from `appendonly yes` + `aof-use-rdb-preamble yes` is near-RDB speed + AOF tail replay. RDB-only: ~2-5 s per GB on SSD.

## Verify script

```sh
#!/usr/bin/env bash
set -eu
H=${1:-127.0.0.1}
P=${2:-6379}
A=${3:+-a $3}
cli="valkey-cli -h $H -p $P ${A:-} --no-auth-warning"

g() { $cli CONFIG GET "$1" | tail -1; }
echo "maxmemory         : $(g maxmemory)"
echo "maxmemory-policy  : $(g maxmemory-policy)"
echo "appendonly        : $(g appendonly)"
echo "protected-mode    : $(g protected-mode)"
echo "io-threads        : $(g io-threads)"
echo "lazyfree-lazy-*   : $($cli CONFIG GET 'lazyfree-lazy-*' | paste - - | head -5)"  # all should be 'yes'
echo "extended-redis-*  : $(g extended-redis-compatibility)"                            # off unless migrating
echo "rdb-version-check : $(g rdb-version-check)"
echo "cluster_enabled   : $($cli INFO cluster      | grep cluster_enabled)"
echo "connected_slaves  : $($cli INFO replication  | grep connected_slaves)"
echo "used_memory_human : $($cli INFO memory       | grep used_memory_human:)"
[ "$(g maxmemory)" = "0" ] && echo "[WARN] maxmemory is unlimited"
```

## Go-live checklist

Items marked **V** are Valkey-specific defaults/behaviors to verify.

### System

- [ ] `vm.overcommit_memory=1` (BGSAVE/BGREWRITEAOF fork needs it).
- [ ] `net.core.somaxconn ≥ 65535` (≥ `tcp-backlog`).
- [ ] THP `never` - non-negotiable. Valkey warns at startup if enabled.
- [ ] Swap enabled with `vm.swappiness=1` - safety net, not runtime path.
- [ ] `ulimit -n ≥ maxclients + 32`. In systemd: `LimitNOFILE=65535`.
- [ ] Valkey runs as unprivileged `valkey` user; binary not setuid-root.

### Configuration

- [ ] **`maxmemory` set explicitly** - never leave at `0` in production.
- [ ] Eviction policy matches workload: `allkeys-lru`/`allkeys-lfu` for cache, `noeviction` for primary store, `volatile-*` only if every cache key has TTL.
- [ ] `maxmemory-clients 5%` caps aggregate client-buffer memory.
- [ ] `tcp-keepalive 300` (lower in NAT-aggressive environments).
- [ ] Persistence chosen and restore tested: cache-only (`save ""`, `appendonly no`), durable (`appendonly yes` + `appendfsync everysec` + `aof-use-rdb-preamble yes`), or hybrid.
- [ ] `latency-monitor-threshold > 0` (typical: 50-100 ms) - required for `LATENCY DOCTOR`.
- [ ] **V** COMMANDLOG thresholds set: `commandlog-execution-slower-than 10000` + the two `large-*` thresholds.
- [ ] **V** `hide-user-data-from-log yes` (Valkey default; verify not flipped to `no`).

### Security

- [ ] ACL users per service, no app traffic on `default`.
- [ ] **V** TLS enabled for client and replication/cluster-bus. Cert-rotation pipeline in place (restart/failover on 9.0.x - in-place reload is unstable-only).
- [ ] `bind` to explicit private IPs, not `0.0.0.0`.
- [ ] `protected-mode yes`.
- [ ] Firewall scoped to client port, Sentinel port (26379), and cluster bus (client+10000).
- [ ] Default user disabled or strong password; dangerous commands (`FLUSHALL`, `DEBUG`, `SHUTDOWN`, `CONFIG`) restricted via ACL or `rename-command`.

### Monitoring

- [ ] Prometheus exporter (`oliver006/redis_exporter`) running; ACL user scoped to `+info +ping +config|get +client|list +commandlog|get +commandlog|len +latency|latest +latency|history`.
- [ ] **V** Grafana Redis dashboard (ID `11835` or `763`) imported, plus panels for Valkey-only metrics (`expired_fields`, `evicted_scripts`, `io_threads_active`, `io_threaded_total_prefetch_batches`).
- [ ] **V** Alerts: instance down, `used_memory / maxmemory > 0.9`, `rejected_connections > 0`, replication link down, lag > 5 s warn / 30 s crit, `rdb_last_bgsave_status != ok`, latency p99 spike, TLS cert expiry (tracked out-of-band on 9.0.x - in-INFO expire telemetry is unstable-only).
- [ ] COMMANDLOG reviewed periodically - `COMMANDLOG GET 25 slow / large-request / large-reply`.

### Backup

- [ ] RDB shipped off-host (S3/GCS/Azure Blob or remote FS).
- [ ] Retention policy documented (e.g., hourly 24 h, daily 30 d).
- [ ] Restore tested in staging at least once; restore time documented.
- [ ] Alerts on backup age exceeding RPO and on upload failures.

### High availability

- [ ] Sentinel ≥3 instances on independent failure domains, OR Cluster ≥3 primaries each with 1 replica.
- [ ] `min-replicas-to-write ≥ 1` and `min-replicas-max-lag 10` - bounds split-brain write-loss.
- [ ] Failover tested: manual `SENTINEL FAILOVER` or `CLUSTER FAILOVER` in staging, clients reconnect, monitoring catches the event.
- [ ] `repl-backlog-size` sized per write rate + disconnect window (see `replication.md`).
- [ ] On K8s: PodDisruptionBudget with `maxUnavailable: 1`.

### Kubernetes-specific

- [ ] Kernel tuning via DaemonSet or privileged init container (sysctls aren't settable in all K8s distros).
- [ ] StorageClass is SSD-backed; PVC size ≥ 2× `maxmemory`.
- [ ] Pod anti-affinity across nodes or AZs.
- [ ] Memory limit ≥2× request (fork COW headroom). No CPU limit on latency-sensitive workloads.
- [ ] Startup probe's `failureThreshold * periodSeconds` > worst-case load time (AOF replay on a large dataset can take minutes).
- [ ] Cluster bus port (+10000) reachable between pods - via `hostNetwork`, `cluster-announce-*`, or an operator.

### Pre-upgrade

- [ ] Current version captured: `INFO server | grep valkey_version`.
- [ ] Fresh RDB/AOF backup taken immediately before.
- [ ] Release notes read; note deprecated configs and default changes.
- [ ] Rollback plan documented - for cross-RDB-major upgrades (9.0 writes RDB 80 once hash field TTL is in use), downgrade is a restore-from-backup, not in-place revert.
- [ ] Replica-version compatibility verified (`upgrades.md`).
- [ ] **V** Valkey 9.0: use **9.0.3+** only. 9.0.0-9.0.1 had hash field TTL bugs (memory leaks, crashes, data corruption).
