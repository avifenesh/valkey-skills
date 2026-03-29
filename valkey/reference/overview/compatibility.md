# Redis Compatibility and Migration

Use when migrating from Redis to Valkey, evaluating compatibility of existing applications, or planning a migration strategy.

---

## Compatibility Baseline

Valkey is compatible with Redis OSS versions 2.x through 7.2.x. This means:

- **Protocol**: RESP2 and RESP3 wire formats are identical
- **Commands**: All Redis OSS commands through 7.2 work unchanged
- **Data files**: RDB and AOF files from Redis OSS <= 7.2 load directly into Valkey
- **Configuration**: Most `valkey.conf` directives match `redis.conf` (same format, same defaults)
- **Client libraries**: ioredis, Jedis, redis-py, go-redis, Lettuce, StackExchange.Redis - all work without modification
- **Lua scripts**: All existing scripts work unchanged
- **Module API**: Redis modules load in Valkey

---

## What Changes in Migration

| Area | Redis | Valkey |
|------|-------|--------|
| Binary names | `redis-server`, `redis-cli` | `valkey-server`, `valkey-cli` |
| Config file | `redis.conf` | `valkey.conf` (identical format) |
| Data directory | `/var/lib/redis` | `/var/lib/valkey` |
| Service name | `redis.service` | `valkey.service` |
| System user | `redis` | `valkey` |
| Server identity | Reports "redis" in INFO | Reports "valkey" in INFO |
| RDB magic (9.0+) | `REDIS` header | `VALKEY` header for RDB version 80+ |
| Default lazy-free | `lazyfree-lazy-user-del no` | `lazyfree-lazy-user-del yes` (8.0+) |

### Extended Redis Compatibility Mode

For clients that check the server identity string, Valkey provides a compatibility mode:

```
CONFIG SET extended-redis-compatibility yes
```

When enabled, Valkey reports as "redis" and shows `REDIS_VERSION` (7.2.4) in `HELLO`, `INFO`, `LOLWUT`, and `CLIENT SETNAME` responses. This is runtime-modifiable - no restart needed.

---

## What Does NOT Change

These work identically before and after migration:

- RESP protocol wire format
- All Redis OSS 7.2 commands
- RDB and AOF data formats (from Redis <= 7.2)
- Port defaults: 6379 (client), 26379 (Sentinel), +10000 (cluster bus)
- ACL syntax and format
- Lua scripting and Functions
- Pub/Sub including sharded pub/sub
- Client-side caching (CLIENT TRACKING)
- Connection pooling behavior

---

## Migration Strategies

### Method 1: Binary Replacement (Downtime Required)

Best for: single-instance setups, development environments, short maintenance windows.

```bash
# 1. Stop Redis
systemctl stop redis

# 2. Copy data files
cp /var/lib/redis/dump.rdb /var/lib/valkey/dump.rdb
# If using AOF:
cp -r /var/lib/redis/appendonlydir /var/lib/valkey/appendonlydir

# 3. Migrate config
# Copy redis.conf -> valkey.conf, update paths:
#   dir /var/lib/valkey
#   logfile /var/log/valkey/valkey.log
#   pidfile /var/run/valkey/valkey.pid

# 4. Set ownership
chown -R valkey:valkey /var/lib/valkey /var/log/valkey

# 5. Start Valkey
systemctl start valkey

# 6. Verify
valkey-cli ping
valkey-cli DBSIZE
valkey-cli INFO server | grep valkey_version
```

Downtime: seconds to minutes depending on dataset size (AOF replay time).

### Method 2: Replication-Based (Minimal Downtime)

Best for: production systems where downtime must be minimized.

```bash
# 1. Install Valkey on a separate host or port

# 2. Start Valkey as a replica of Redis
valkey-server /etc/valkey/valkey.conf
valkey-cli REPLICAOF redis-host 6379

# 3. Wait for initial sync to complete
valkey-cli INFO replication
# Watch for:
#   master_link_status:up
#   master_sync_in_progress:0
#   master_repl_offset matches the Redis primary offset

# 4. Verify data integrity
valkey-cli DBSIZE     # should match Redis DBSIZE
# Spot-check critical keys

# 5. Switch application connections to Valkey
# Update connection strings, DNS, or load balancer

# 6. Promote Valkey to primary
valkey-cli REPLICAOF NO ONE

# 7. Stop Redis
redis-cli SHUTDOWN
```

Downtime: effectively zero for reads, brief (connection switch time) for writes.

### Method 3: Cluster Migration

Best for: Redis Cluster deployments.

```bash
# 1. For each Redis primary, add a Valkey node as its replica
valkey-cli --cluster add-node valkey-host:7000 redis-host:7000 \
  --cluster-replica --cluster-master-id <redis-primary-node-id>

# 2. Wait for all Valkey replicas to sync
valkey-cli -p 7000 CLUSTER NODES
# Verify all Valkey nodes show as connected replicas

# 3. Failover each shard to promote Valkey replicas
# On each Valkey replica:
valkey-cli -p 7000 CLUSTER FAILOVER

# 4. Verify all Valkey nodes are now primaries
valkey-cli -p 7000 CLUSTER NODES
# All Valkey nodes should show "master" flag

# 5. Remove old Redis nodes
valkey-cli --cluster del-node valkey-host:7000 <redis-node-id>
# Repeat for each Redis node

# 6. Final verification
valkey-cli --cluster check valkey-host:7000
```

---

## Incompatible Versions

Redis Community Edition 7.4+ (post-license-change) is NOT compatible with Valkey:

- Uses proprietary code paths
- RDB versions in the reserved foreign range (12-79) that Valkey rejects by default
- New proprietary data formats

Migration from Redis CE 7.4+ requires third-party tools like RIOT or RedisShake - direct file copy or replication will not work.

---

## Client Library Compatibility

All major Redis clients work with Valkey out of the box:

| Language | Client | Status |
|----------|--------|--------|
| Node.js | ioredis | Works unchanged |
| Node.js | node-redis | Works unchanged |
| Python | redis-py | Works unchanged |
| Python | valkey-py | Fork with Valkey-specific features |
| Java | Jedis | Works unchanged |
| Java | Lettuce | Works unchanged |
| Java | Redisson | Works unchanged |
| Go | go-redis | Works unchanged |
| Go | rueidis | Works unchanged |
| .NET | StackExchange.Redis | Works unchanged |

For new projects or when upgrading, consider Valkey GLIDE - see [clients overview](../clients/overview.md).

---

## Application Code Changes

In most cases, no application code changes are needed. The two exceptions:

1. **Connection strings** - update hostname/port if Valkey runs on different infrastructure
2. **Server identity checks** - if your code inspects `INFO` output for "redis", either update the check or enable `extended-redis-compatibility`

All data structures, commands, scripting, and patterns work identically.

---

## See Also

- [What is Valkey](what-is-valkey.md) - overview, version history, and feature comparison
- [Clients Overview](../clients/overview.md) - GLIDE and existing Redis client compatibility
- [Conditional Operations](../valkey-features/conditional-ops.md) - Valkey-only SET IFEQ and DELIFEQ commands
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - Valkey-only per-field TTL on hash entries
- [Cluster Enhancements](../valkey-features/cluster-enhancements.md) - Valkey-only numbered databases and atomic slot migration
- [Polygon Geospatial Queries](../valkey-features/geospatial.md) - Valkey-only GEOSEARCH BYPOLYGON
- [Performance Summary](../valkey-features/performance-summary.md) - version-by-version throughput and latency gains
- [String Commands](../commands/strings.md) - all Redis OSS string commands work unchanged; SET IFEQ is Valkey-only
- [Hash Commands](../commands/hashes.md) - all Redis OSS hash commands work unchanged; field TTL commands are Valkey-only
- [Scripting and Functions](../commands/scripting.md) - Lua scripts and Functions work unchanged after migration
- [Server Commands](../commands/server.md) - INFO, CONFIG GET, and extended-redis-compatibility mode
- [Module Commands](../commands/modules.md) - Redis modules load in Valkey via the compatible module API
- For operational migration procedures: see valkey-ops `reference/upgrades/migration.md`
