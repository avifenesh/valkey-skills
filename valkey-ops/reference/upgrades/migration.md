# Redis to Valkey Migration

Use when migrating from Redis OSS to Valkey, planning a migration strategy, or understanding what changes between the two systems.

---

## Compatibility Baseline

Valkey is compatible with Redis OSS 7.2 and all earlier versions. Redis CE 7.4+ is NOT compatible - it uses RDB versions in the reserved foreign range (12-79) that Valkey rejects by default.

Source: `src/rdb.h` reserves versions 12-79 as `RDB_FOREIGN_VERSION_MIN` to `RDB_FOREIGN_VERSION_MAX`.

## What Changes

| Area | Change |
|------|--------|
| Binary names | `redis-server` -> `valkey-server`, `redis-cli` -> `valkey-cli` |
| Config file | `redis.conf` -> `valkey.conf` (format identical) |
| Data directory | Typically `/var/lib/redis` -> `/var/lib/valkey` |
| Service name | `redis.service` -> `valkey.service` |
| Default user | `redis` -> `valkey` |
| Server identity | Reports as "valkey" in `INFO`, `HELLO`, `LOLWUT` |
| RDB magic (9.0+) | `REDIS` -> `VALKEY` for RDB version 80+ |

## What Does NOT Change

- RESP protocol - identical wire format
- Command set - all Redis OSS 7.2 commands work
- Data formats - RDB and AOF files are compatible
- Client libraries - all Redis clients work with Valkey
- Port defaults - still 6379 (client), 26379 (Sentinel), +10000 (cluster bus)
- ACL format - identical syntax
- Lua scripting - fully compatible
- Module API - Redis modules load in Valkey

## Extended Redis Compatibility Mode

For clients that check the server identity string, Valkey provides `extended-redis-compatibility` mode:

```
CONFIG SET extended-redis-compatibility yes
```

When enabled, Valkey reports as "redis" and shows `REDIS_VERSION` (7.2.4) in `HELLO`, `INFO`, `LOLWUT`, and `CLIENT SETNAME` responses.

Source: verified across `src/networking.c`, `src/lolwut.c`, `src/debug.c`, `src/server.c`. The `REDIS_VERSION` is "7.2.4" (`src/version.h`).

This is a runtime-modifiable config - no restart needed.

## Method 1: Binary Replacement (Downtime Required)

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

## Method 2: Replication-Based (Minimal Downtime)

Best for: production systems where downtime must be minimized.

```bash
# 1. Install Valkey on a separate host or port
# Configure valkey.conf with appropriate settings

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

## Method 3: Cluster Migration

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

## Configuration Changes Without Restart

Most Valkey parameters support runtime modification via CONFIG SET. This is relevant during migration when tuning the new deployment.

```bash
# Change at runtime
valkey-cli CONFIG SET maxmemory 4gb

# Persist to config file
valkey-cli CONFIG REWRITE
```

### Immutable Configs (Require Restart)

These cannot be changed at runtime (verified from `src/config.c` IMMUTABLE_CONFIG flag):

| Config | Description |
|--------|-------------|
| `cluster-enabled` | Toggle cluster mode |
| `daemonize` | Run as daemon |
| `databases` | Number of databases |
| `cluster-config-file` | Cluster state file |
| `unixsocket` | Unix socket path |
| `logfile` | Log file path |
| `syslog-enabled` | Syslog output |
| `aclfile` | ACL file path |
| `appendfilename` | AOF filename |
| `appenddirname` | AOF directory name |
| `tcp-backlog` | TCP listen backlog |
| `cluster-port` | Cluster bus port |
| `supervised` | Supervision mode |
| `pidfile` | PID file path |
| `disable-thp` | THP disabling |

Note: `bind` and `port` ARE modifiable at runtime despite some documentation stating otherwise. Verified from source: both use MODIFIABLE_CONFIG flag.

### Runtime-Modifiable Configs (Common Tuning)

| Config | Description |
|--------|-------------|
| `maxmemory` | Memory limit |
| `maxmemory-policy` | Eviction policy |
| `maxclients` | Connection limit |
| `timeout` | Idle client timeout |
| `tcp-keepalive` | Keepalive interval |
| `hz` | Server tick frequency |
| `appendonly` | Toggle AOF |
| `appendfsync` | AOF sync policy |
| `save` | RDB snapshot triggers |
| `bind` | Network bind addresses |
| `port` | Client port |
| `protected-mode` | External connection protection |
| `loglevel` | Logging verbosity |
| `slowlog-log-slower-than` | Slow log threshold |
| `latency-monitor-threshold` | Latency monitor threshold |
| `extended-redis-compatibility` | Redis identity mode |
| `rdb-version-check` | RDB version strictness |

## Migration Checklist

1. [ ] Verify source is Redis OSS 7.2 or earlier (not Redis CE 7.4+)
2. [ ] Install Valkey on target hosts
3. [ ] Translate config file (update paths, review new features)
4. [ ] Enable `extended-redis-compatibility` if clients check server identity
5. [ ] Test replication between Redis primary and Valkey replica
6. [ ] Verify DBSIZE and spot-check keys after sync
7. [ ] Update monitoring to use Valkey binary names
8. [ ] Switch application connections
9. [ ] Promote Valkey instances
10. [ ] Disable `extended-redis-compatibility` once clients are updated
11. [ ] Update backup scripts to reference new paths

## See Also

- [Version Compatibility](compatibility.md) - RDB versions and replication compatibility
- [Rolling Upgrades](rolling-upgrade.md) - zero-downtime upgrade procedures
- [Production Checklist](../production-checklist.md) - post-migration verification
- [See valkey-dev: cluster/overview](../valkey-dev/reference/cluster/overview.md) - cluster protocol internals
- [See valkey-dev: replication overview](../valkey-dev/reference/replication/overview.md) - replication protocol internals
