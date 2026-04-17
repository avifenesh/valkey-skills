---
name: valkey-ops
description: "Use when deploying, configuring, monitoring, or troubleshooting self-hosted Valkey. Covers Sentinel, cluster, persistence, replication, security, Kubernetes, performance tuning. Only what diverges from Redis or is genuinely novel; Redis-baseline ops knowledge is assumed. Not for app development (valkey) or server internals (valkey-dev)."
version: 2.0.0
argument-hint: "[config, deploy, monitor, or troubleshoot topic]"
---

# Valkey Operations Reference

Organized by operational topic. Each file covers a coherent work area; Redis-baseline behavior is assumed and not repeated. All files target Valkey 9.0.3.

## Route by work area

| Working on... | File | Grep-friendly topics inside |
|---------------|------|-----------------------------|
| Install, build flags, binaries, allocator, systemd, bare metal, Docker images (official vs Bitnami), Compose patterns | `reference/deployment.md` | `## Versions`, `## Build flags`, `## Bare metal`, `## Docker`, `## Docker Compose` |
| `valkey.conf` audit/tuning, maxmemory, eviction, encoding thresholds, lazy-free, logging, COMMANDLOG, CPU pinning | `reference/configuration.md` | `## Network`, `## Memory and eviction`, `## Encoding thresholds`, `## Lazy-free`, `## COMMANDLOG`, `## Replication`, `## Cluster` |
| Sentinel deployment, timing, cross-DC, NAT, coordinated failover (9.0+), split-brain prevention, `min-replicas-to-write` | `reference/sentinel.md` | `## Deployment config`, `## Timing knobs`, `## Cross-DC placement`, `## Coordinated failover (Valkey 9.0+)`, `## Write safety` |
| Cluster setup, failover modes, atomic slot migration (`CLUSTER MIGRATESLOTS`, 9.0+), resharding, rolling restart, consistency | `reference/cluster.md` | `## Setup`, `## CLUSTER FAILOVER modes`, `## Atomic slot migration (9.0+)`, `## Rolling restart`, `## Consistency` |
| RDB config, `VALKEY080` magic, AOF multi-part, hybrid, backup strategies, PITR, disaster recovery | `reference/persistence.md` | `## RDB - config`, `## RDB - magic and version`, `## AOF - multi-part architecture`, `## Disaster recovery` |
| Primary/replica setup, backlog sizing, diskless, dual-channel (8.0+), NAT announce, data-loss patterns | `reference/replication.md` | `## Terminology`, `## Backlog sizing`, `## Dual-channel replication (8.0+)`, `## Incident patterns` |
| ACL (`%R~`/`%W~`, Sentinel user), TLS (mTLS, `tls-auth-clients-user` CN mapping), hardening checklist | `reference/security.md` | `## ACL - Valkey-only pieces`, `## TLS - tls-auth-clients-user`, `## TLS - replication and cluster bus`, `## Hardening checklist` |
| INFO fields, Prometheus exporter, Grafana, alerting, COMMANDLOG command family | `reference/monitoring.md` | `## INFO sections`, `## Prometheus exporter`, `## COMMANDLOG (replaces SLOWLOG)`, `## Alerting` |
| I/O threads sizing, per-key memory savings (kvstore per-slot, embedded string+key+expire on 9.0), active defrag, 9.0 perf features, kernel knobs, client-side caching, benchmarking | `reference/performance.md` | `## I/O threads`, `## Memory - built-in per-key savings on 9.0`, `## Active defragmentation`, `## Valkey 9.0 performance features`, `## Client-side caching` |
| OOM, slow commands, replication lag diagnosis, cluster partitions, THP spikes, incident patterns, health-check script | `reference/troubleshooting.md` | `## Quick triage sequence`, `## OOM`, `## Cluster partitions`, `## Incident patterns`, `## Quick health-check script` |
| Version compatibility, RDB range (12-79 foreign), Redis → Valkey migration (3 paths), rolling upgrade, coordinated failover for upgrades, 9.0 gotchas | `reference/upgrades.md` | `## RDB version compatibility`, `## Replication compatibility`, `## Redis → Valkey migration`, `## Rolling upgrades`, `## 9.0 production gotchas` |
| Helm (official vs Bitnami), operators (official, Hyperspike, SAP), StatefulSet patterns, PVC sizing, gossip under NAT | `reference/kubernetes.md` | `## Helm charts`, `## Operators`, `## Raw StatefulSet`, `## Cluster gossip under NAT`, `## GKE Autopilot` |
| Capacity planning, memory sizing, go-live checklist (system/config/security/monitoring/backup/HA/K8s), pre-upgrade audit | `reference/operations.md` | `## Sizing`, `## Persistence math to sanity-check`, `## Verify script`, `## Go-live checklist` |

## Critical rules

1. **`maxmemory` must be set explicitly.** Default `0` (unlimited) lets the process grow until OOM killer fires.
2. **Persistence on every primary.** Without it, a restart of an empty primary wipes replicas on full resync - classic cascading-data-loss incident.
3. **Never 2 Sentinels.** Need ≥3 on independent failure domains. Two cannot achieve majority.
4. **Valkey 9.0.0-9.0.1 had hash-field-TTL bugs** (memory leaks, crashes, data corruption). Use **9.0.3+** in production.
5. **Memory limit on K8s must exceed `maxmemory` by fork COW headroom** (typically 2× on write-heavy). Otherwise BGSAVE OOMKills the pod.
6. **`rdb-version-check strict` (default) rejects Redis CE 7.4+ RDB files** - the 12-79 range is reserved as "foreign". Migration from Redis CE requires `relaxed` mode (at your own risk) or a different path.

## Common grep hazards

These names differ from Redis or are Valkey-specific - agents trained on Redis search for the wrong tokens:

- `SLOWLOG` → **COMMANDLOG** family. Three types: `slow`, `large-request`, `large-reply`. `SLOWLOG GET/LEN/RESET` still works as alias for `slow` only. Configs: `commandlog-execution-slower-than`, `commandlog-request-larger-than`, `commandlog-reply-larger-than`, plus `*-max-len` for each.
- `slaveof` / `slave-priority` / `masterauth` / `masteruser` → `replicaof` / `replica-priority` / `primaryauth` / `primaryuser`. Redis names still accepted.
- `redis-server` / `redis-cli` / `/etc/redis/` / `/var/lib/redis/` / `redis` user → `valkey-*` / `/etc/valkey/` / `/var/lib/valkey/` / `valkey` user. `USE_REDIS_SYMLINKS=yes` (default) installs `redis-*` symlinks for legacy scripts.
- `cluster-mf-timeout` → **not a real config**. Actual: `cluster-manual-failover-timeout` (default 5000 ms, Valkey-only - Redis hardcodes this).
- `busy-script-time` / `lua-memory-limit` → **not real**. Actual: `busy-reply-threshold` (default 5000 ms, alias `lua-time-limit`). Lua has no separate memory limit (shares `maxmemory`).
- **lazy-free defaults flipped** in Valkey (all five are `yes`; Redis defaults `no`): `lazyfree-lazy-eviction`, `lazyfree-lazy-expire`, `lazyfree-lazy-server-del`, `lazyfree-lazy-user-del`, `lazyfree-lazy-user-flush`. `DEL` behaves like `UNLINK` unless disabled.
- `hash-max-listpack-entries` default is `512` - same as Redis 7.2.4 (the "Redis default 128" claim is a myth; both default to 512). No Valkey-specific divergence here.
- `cluster-allow-pubsubshard-when-down` defaults **`yes`** on 9.0.3 (same as Redis 7.0+) - shard pub/sub keeps working when the cluster is FAIL. Set `no` explicitly if your use case needs fail-closed pub/sub.
- `+failover` ACL permission → **not real** (fabrication). FAILOVER and CLUSTER FAILOVER use standard `@admin`/`@dangerous`/`@slow` categories - no special gate beyond any admin command.
- `alldbs` / per-DB ACL selectors → **9.1+/unstable only**, not 9.0.x. Don't prescribe on 9.0 deployments.
- `tls-auth-clients-user uri` (SPIFFE-style SAN URI mapping) and `tls-auto-reload-interval` (in-place cert reload) are **unstable-only**. On 9.0.x the enum has `CN` and `off` only; cert rotation requires restart/failover. TLS cert expire INFO fields (`tls_server_cert_expire_time` etc.) and `cluster_stats_bytes_*` byte counters are also unstable-only.
- `io-threads-do-reads`, `dynamic-hz`, `lua-replicate-commands`, `list-max-ziplist-*` → **deprecated** on 9.0.3 (silently accepted; in `deprecated_configs[]`). `events-per-io-thread` is NOT deprecated on 9.0.3 - it's a live `HIDDEN_CONFIG` with default `2`, still tunable via `CONFIG SET`. (The Ignition/Cooldown CPU-sample policy that replaces it is on `unstable`, not 9.0.3.)
- RDB magic: files version ≥80 use `VALKEY` magic (`VALKEY080` for RDB 80). Files ≤11 use `REDIS`. Range 12-79 is the reserved "foreign" range - Valkey rejects under `rdb-version-check strict`.
- `LOLWUT` output changed from "Redis ver." to "Valkey ver." in 9.0 - breaks scripts that parse LOLWUT for version detection. Use `INFO server` instead.
- `extended-redis-compatibility yes` makes INFO/HELLO/LOLWUT report `redis_version: 7.2.4` - transition knob for clients that check server identity, not a permanent config.
