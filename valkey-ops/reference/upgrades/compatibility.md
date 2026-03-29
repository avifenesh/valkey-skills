# Version Compatibility

Use when planning upgrades between Valkey versions, checking replication compatibility, or evaluating whether a version jump is safe.

---

## Semantic Versioning

Valkey uses `major.minor.patch` versioning:

| Component | Scope | Cluster mixing | Upgrade risk |
|-----------|-------|----------------|--------------|
| Patch | Bug fixes only | Safe to mix | Minimal |
| Minor | Backward-compatible features | Avoid mixing long-term | Low |
| Major | May break compatibility | Not safe to mix | Review release notes |

## Support Policy

- **Maintenance**: 3 years from first minor release of each major - bug fixes and security fixes
- **Extended security**: 5 years for the latest minor of each major - security fixes only

## RDB Version Compatibility

Replication and RDB loading depend on RDB format versions. Verified from `src/rdb.h`:

| RDB Version | Introduced In | Magic String |
|-------------|---------------|--------------|
| 9 | Redis 5.0 | `REDIS` |
| 10 | Redis 7.0 | `REDIS` |
| 11 | Redis 7.2 / Valkey 7.2 | `REDIS` |
| 80 | Valkey 9.0 | `VALKEY` |

RDB versions 12-79 are reserved as a "foreign version" range. Valkey rejects RDB files in this range under strict mode. This prevents loading RDB files from Redis CE 7.4+ (which uses versions in this range).

Source: `src/rdb.h` defines `RDB_FOREIGN_VERSION_MIN=12` and `RDB_FOREIGN_VERSION_MAX=79`.

## Replication Version Negotiation

The primary selects the highest RDB version the replica understands, based on `RDB_VERSION_MAP` in `src/rdb.h`:

```
{11, 0x070200}   -- Replicas reporting version >= 7.2 get RDB 11
{80, 0x090000}   -- Replicas reporting version >= 9.0 get RDB 80
```

If a replica does not report its version (Redis 7.2 and older), the primary falls back to RDB 11.

Source: `replicaRdbVersion()` in `src/replication.c`.

### Replication Compatibility Matrix

| Primary | Replica | Works | RDB version sent |
|---------|---------|-------|------------------|
| Valkey 9.x | Valkey 9.x | Yes | 80 |
| Valkey 9.x | Valkey 8.x | Yes | 11 (downgraded) |
| Valkey 9.x | Redis 7.2 | Yes | 11 (fallback) |
| Valkey 8.x | Valkey 9.x | Yes | 11 |
| Redis 7.2 | Valkey 8.x | Yes | 11 |
| Redis 7.2 | Valkey 9.x | Yes | 11 |
| Redis CE 7.4+ | Valkey any | No | Foreign RDB range |
| Valkey any | Redis CE 7.4+ | No | Foreign RDB range |

Key rule: replica RDB version must be >= primary RDB version for data to load. Higher-version primaries send downgraded RDB to older replicas automatically.

## RDB Version Check Modes

The `rdb-version-check` config (modifiable at runtime) controls how strictly Valkey validates RDB versions:

| Mode | Behavior |
|------|----------|
| `strict` (default) | Rejects future versions and foreign range (12-79) |
| `relaxed` | Accepts any version >= 1, allows loading foreign RDB files |

Use `relaxed` only for migration from forks that use the reserved range.

Source: `rdbIsVersionAccepted()` in `src/rdb.c`.

## RDB File Magic Strings

Starting with RDB version 80 (Valkey 9.0), files use the `VALKEY` magic string instead of `REDIS`. The `rdbUseValkeyMagic()` function returns true for RDB versions > 79.

- RDB <= 11: `REDIS` magic string
- RDB >= 80: `VALKEY` magic string
- RDB 12-79: reserved/foreign

## Feature Compatibility Between Versions

| Feature | Minimum Version | Notes |
|---------|----------------|-------|
| I/O threads | 8.0+ | `io-threads` config |
| Dual-channel replication | 8.0+ | Parallel RDB + backlog transfer |
| Atomic slot migration | 9.0+ | `CLUSTER MIGRATESLOTS` command |
| Coordinated Sentinel failover | 9.0+ | `SENTINEL FAILOVER ... COORDINATED` |
| Memory prefetching for pipelines | 9.0+ | Up to 40% throughput improvement |
| Zero-copy responses | 9.0+ | Up to 20% improvement for large payloads |
| SIMD optimizations | 9.0+ | BITCOUNT, HyperLogLog |
| Multipath TCP | 9.0+ | `mptcp` config |
| 2000-node clusters | 9.0+ | 1B+ RPS capable |
| `extended-redis-compatibility` | 8.0+ | Reports as Redis for client compatibility |

## Deprecated Configurations

These config directives are silently ignored (verified from `src/config.c`):

| Deprecated Config | Reason |
|-------------------|--------|
| `list-max-ziplist-entries` | Replaced by listpack-based configs |
| `list-max-ziplist-value` | Replaced by listpack-based configs |
| `lua-replicate-commands` | Always enabled now |
| `io-threads-do-reads` | Always enabled when I/O threads are configured |
| `dynamic-hz` | Always enabled |

## See Also

- [Rolling Upgrades](rolling-upgrade.md) - zero-downtime upgrade procedures
- [Redis Migration](migration.md) - migrating from Redis to Valkey
- [Production Checklist](../production-checklist.md) - pre-upgrade verification
- [See valkey-dev: replication overview](../valkey-dev/reference/replication/overview.md) - replication protocol internals
- [See valkey-dev: rdb](../valkey-dev/reference/persistence/rdb.md) - RDB format details
- [See valkey-dev: cluster/failover](../valkey-dev/reference/cluster/failover.md) - cluster failover mechanics
