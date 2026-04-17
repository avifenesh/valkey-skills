# Upgrades

Use when planning a version bump, migrating from Redis, or doing a rolling upgrade.

## Versioning and support

`major.minor.patch`:

| Component | Scope | Cluster mixing | Upgrade risk |
|-----------|-------|----------------|--------------|
| Patch | Bug fixes | Safe | Minimal |
| Minor | Backward-compatible features | Avoid long-term | Low |
| Major | May break compatibility | Not safe | Review release notes |

Support: 3 years bug+security fixes from first minor release of each major; 5 years security-only on the latest minor.

## Release history

| Version | Date | Notes |
|---------|------|-------|
| 8.0.0 GA | Sep 2024 | Fork of Redis OSS 7.2.4 |
| 8.0.1-8.0.7 | Oct 2024-Feb 2026 | Security + bug fixes |
| 8.1.0 GA | Mar 2025 | SIMD, embedded hash values, BGSAVE CANCEL |
| 8.1.1-8.1.6 | Apr 2025-Feb 2026 | Security + bug fixes |
| 9.0.0 GA | Oct 2025 | Atomic slot migration, hash field expiration |
| 9.0.1 | Dec 2025 | Bug fixes |
| 9.0.2 | Feb 2026 | Critical hash field expiration fixes |
| 9.0.3 | Feb 2026 | Security (3 CVEs) |

**9.0.0-9.0.1 critical bugs**: hash-field-TTL memory leaks, crashes, data corruption; Lua VM crash after `FUNCTION FLUSH ASYNC + FUNCTION LOAD`; crash aborting slot migration during child snapshot. **Use 9.0.3+ in production.**

## RDB version compatibility

| RDB Version | Introduced | Magic |
|-------------|------------|-------|
| 9 | Redis 5.0 | `REDIS` |
| 10 | Redis 7.0 | `REDIS` |
| 11 | Redis 7.2 / Valkey 7.2 | `REDIS` |
| 12-79 | Reserved (foreign) | - |
| 80 | Valkey 9.0 | `VALKEY` |

`RDB_FOREIGN_VERSION_MIN=12`, `RDB_FOREIGN_VERSION_MAX=79`. Valkey rejects foreign range under `rdb-version-check strict` (default) - this is how it prevents loading Redis CE 7.4+ RDBs.

`rdb-version-check`:
- `strict` (default) - rejects future versions and foreign range.
- `relaxed` - accepts any version ≥1, allows loading foreign RDB. Use only for migration from forks that use the reserved range.

## Replication compatibility

`replicaRdbVersion()` selects highest RDB version the replica understands:

```
{11, 0x070200}   -- Replicas reporting >= 7.2 get RDB 11
{80, 0x090000}   -- Replicas reporting >= 9.0 get RDB 80
```

Fallback is RDB 11 when replica doesn't report version (Redis 7.2 and older).

| Primary | Replica | Works | RDB sent |
|---------|---------|-------|----------|
| Valkey 9.x | Valkey 9.x | Yes | 80 |
| Valkey 9.x | Valkey 8.x | Yes | 11 (downgraded) |
| Valkey 9.x | Redis 7.2 | Yes | 11 (fallback) |
| Valkey 8.x | Valkey 9.x | Yes | 11 |
| Redis 7.2 | Valkey 8.x | Yes | 11 |
| Redis 7.2 | Valkey 9.x | Yes | 11 |
| Redis CE 7.4+ | Valkey any | **No** | Foreign range |
| Valkey any | Redis CE 7.4+ | **No** | Foreign range |

Key rule: replica RDB version must be ≥ primary RDB version for data to load. Higher-version primaries send downgraded RDB to older replicas automatically.

## Feature availability

| Feature | Since | Notes |
|---------|-------|-------|
| I/O threads | 8.0+ | `io-threads` config |
| Dual-channel replication | 8.0+ | Parallel RDB + backlog transfer |
| SIMD BITCOUNT / HyperLogLog | 8.1+ | Automatic with AVX2 / NEON |
| `extended-redis-compatibility` | 8.0+ | Reports as Redis for client compat |
| Atomic slot migration | 9.0+ | `CLUSTER MIGRATESLOTS` |
| Coordinated Sentinel failover | 9.0+ | `SENTINEL FAILOVER ... COORDINATED` |
| Memory prefetching for pipelines | 9.0+ | `prefetch-batch-max-size` |
| Zero-copy response path | 9.0+ | `min-io-threads-avoid-copy-reply` |
| Multipath TCP | 9.0+ | `mptcp` (Linux 5.6+) |
| Hash field TTL | 9.0+ | Requires RDB 80 |

## Deprecated configs (silently ignored)

- `list-max-ziplist-entries`, `list-max-ziplist-value` - replaced by listpack
- `lua-replicate-commands` - always enabled
- `io-threads-do-reads` - always enabled when I/O threads configured
- `dynamic-hz` - always enabled
- `events-per-io-thread` - Ignition/Cooldown CPU-sample policy replaced the event-count heuristic

## Client library compatibility

- Valkey 8.x: wire-protocol compatible with Redis; all Redis clients work unchanged.
- Valkey 9.x new features (hash field expiration, numbered DBs in cluster) need updated clients.
- `REDISCLI_AUTH` env var supported alongside `VALKEYCLI_AUTH` (9.0+).
- `LOLWUT` output changed from "Redis ver." to "Valkey ver." in 9.0 - may break naive version-detection scripts.

## Redis → Valkey migration

Compatible with Redis OSS ≤ 7.2. **Redis CE 7.4+ is not compatible** - foreign RDB range.

| What changes | What doesn't |
|--------------|--------------|
| Binary names: `redis-*` → `valkey-*` (symlinks preserve old) | RESP wire protocol |
| Config path: `redis.conf` → `valkey.conf` (identical format) | Redis 7.2 command set |
| Data dir: `/var/lib/redis` → `/var/lib/valkey` | RDB/AOF file formats |
| Service unit: `redis.service` → `valkey.service` | Client library compat |
| Default user: `redis` → `valkey` | Ports |
| INFO/HELLO/LOLWUT report "valkey" | ACL syntax, Lua, module API |
| RDB magic (9.0+): `REDIS` → `VALKEY` for version 80+ | |

### `extended-redis-compatibility`

```
CONFIG SET extended-redis-compatibility yes
```

Reports `redis_version: 7.2.4` in `INFO`, `HELLO`, `LOLWUT`, `CLIENT SETNAME`. Runtime-modifiable. Useful transition knob for clients that check server identity; turn off once every client is updated.

### Migration paths

**1. Binary replacement** (minutes of downtime). Stop Redis, copy `dump.rdb` (or `appendonlydir/`) into Valkey's data dir, update paths, fix ownership, start Valkey. Safest for simple single-instance. Downtime = AOF replay time.

**2. Replication-based** (seconds of switchover). Spin up Valkey as replica of running Redis primary: `REPLICAOF redis-host 6379`. Wait for `master_link_status:up` and `master_sync_in_progress:0`, verify `DBSIZE` matches, flip client endpoints, `REPLICAOF NO ONE` on Valkey, shut down Redis. Valkey's `replicaof` accepts a Redis primary.

**3. Cluster migration** (zero downtime per shard). For each Redis primary, add Valkey node as replica (`--cluster add-node ... --cluster-replica --cluster-master-id <redis-primary-node-id>`). Wait for sync. `CLUSTER FAILOVER` on the Valkey replica, remove old Redis nodes with `--cluster del-node`, verify with `valkey-cli --cluster check`. During the mixed window, any resharding uses legacy key-by-key MIGRATE (ASM needs all-9.0+).

### Immutable configs (restart required)

`cluster-enabled`, `daemonize`, `databases`, `cluster-config-file`, `unixsocket`, `logfile`, `syslog-enabled`, `aclfile`, `appendfilename`, `appenddirname`, `tcp-backlog`, `cluster-port`, `supervised`, `pidfile`, `disable-thp`. Get these right in `valkey.conf` before start.

`bind` and `port` ARE runtime-modifiable despite what some Redis docs claim.

### Post-migration validation

1. **Key count**: `INFO keyspace` - `db0:keys` match source and target.
2. **Spot check**: `RANDOMKEY` + `TYPE` + `GET`/`HGETALL`/`LRANGE` on both sides.
3. **TTL**: compare `PTTL` on samples - should be within seconds.
4. **Replication offset** (method 2): `master_repl_offset` matches before promotion.
5. **Cluster check** (method 3): all 16384 slots covered, no errors.
6. **commandstats**: `INFO commandstats` - no unexpected `failed_calls` climbing post-cutover.
7. Application smoke tests, p50/p99 latency, error rates.

## Rolling upgrades

Baseline (same as Redis): upgrade replicas first, then promote-and-upgrade each primary. Sentinel: upgrade non-primary instances, `SENTINEL FAILOVER <name>`, upgrade old primary, then upgrade Sentinel processes. Cluster: upgrade all replicas across all shards first, then `CLUSTER FAILOVER` per shard and upgrade the old primary one at a time. Never upgrade more than one primary simultaneously; wait for `master_link_status:up` between steps.

### Coordinated failover during upgrade

`SENTINEL FAILOVER <name> COORDINATED` (9.0+) drives the swap through the **primary** rather than sending `REPLICAOF NO ONE` to the replica:

```
MULTI
CLIENT PAUSE WRITE <ms>
FAILOVER TO <replica-host> <replica-port> TIMEOUT <ms>
EXEC
```

Primary pauses writes, waits for replica catch-up, atomically swaps. Fewer spurious `-REDIRECT`s at cutover; no risk of promoting a catching-up replica. **Prefer this over standard `SENTINEL FAILOVER` for planned upgrades.**

Needs `SRI_COORD_FAILOVER` on Sentinel (9.0+) AND `master_failover_state` in INFO on the Valkey instance (9.0+). Mixed versions fall back to classic.

### Mixed 8.x/9.0 cluster concerns

- **ASM is off** until every node is 9.0+. Any resharding during the upgrade window falls back to legacy key-by-key `MIGRATE`/`ASK`. Delay planned reshards until upgrade completes.
- **`CLUSTER SYNCSLOTS CAPA`** gates ASM availability. 9.0+ primaries advertise it; replicas and peer primaries gate behavior on the set.
- **Duplicate multi-meet packet bug** in mixed 8.x/9.0 meshes was fixed in **9.0.1** - if you hit gossip-storm symptoms during upgrade, that's the fix.

### Module ASM opt-in

Modules must explicitly declare ASM support. If any loaded module hasn't opted in, ASM is disabled **cluster-wide** (not just for that module). Audit modules before 9.0 upgrade:

```sh
valkey-cli MODULE LIST
# check each module's release notes or ValkeyModule_* flags for ASM capability
```

Plan module upgrades before the server upgrade, or accept legacy migration.

### `replica_version` gate on CLUSTER SETSLOT

`CLUSTER SETSLOT` replicates to eligible replicas before executing (topology-change resilience). Replicas must report `replica_version > 0x702ff` (i.e. > 7.2) to be eligible. During mixed Redis OSS 7.2 → Valkey 8.x+ upgrades, the replicated-before-executed path is skipped until replicas are on a version that supports it. Falls back cleanly.

### 9.0 production gotchas

- Use **9.0.3+**. Earlier 9.0.x had critical hash field expiration bugs.
- **RDB 80** (`VALKEY080` magic) is only read by 9.0+. A replica on 8.x can't load a snapshot from a 9.0 primary with keys requiring RDB 80 features (e.g., hash field TTL). Primary downgrades RDB to version 11 for older replicas automatically, but keys that can't be represented in RDB 11 fall back to their pre-TTL form. Audit hash field TTL usage before mixing versions.

## Zero-downtime host swap (non-HA)

For a standalone primary without Sentinel or cluster, use replication:

1. Start new instance with `--replicaof <old-primary> 6379`.
2. Wait for `master_link_status:up` + `master_sync_in_progress:0`.
3. `WAIT 1 5000` on the old primary to confirm the new replica has latest writes.
4. Flip client endpoints (DNS/LB/config).
5. `REPLICAOF NO ONE` on the new instance.
6. `SHUTDOWN NOSAVE` on the old one.

**The `WAIT` step is the one you skip at your peril** - client endpoint flips without it can leave straggler writes on the abandoned primary.

## Rollback

Downgrades work as long as you haven't crossed an RDB major. Valkey 9.0 writes RDB 80 once a hash-field-TTL key exists; a downgrade to 8.x after that point fails to load. **Keep an RDB from just before the upgrade and be prepared to restore rather than downgrade in place.**
