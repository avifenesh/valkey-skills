# Redis → Valkey Migration

Use when moving a running Redis deployment to Valkey.

## Compatibility baseline

Valkey is compatible with Redis OSS 7.2 and earlier. **Redis CE 7.4+ is not compatible** - it uses RDB versions in Valkey's reserved "foreign" range (12-79), which Valkey rejects under `rdb-version-check strict` (default). Using `relaxed` mode will *attempt* to load but can't guarantee compatibility for Redis CE-specific features.

| What changes | What doesn't |
|--------------|--------------|
| Binary names: `redis-*` → `valkey-*` (symlinks preserve old names) | RESP wire protocol |
| Config file: `redis.conf` → `valkey.conf` (format identical) | Redis 7.2 command set |
| Data dir: `/var/lib/redis` → `/var/lib/valkey` | RDB/AOF file formats (both load) |
| Service unit: `redis.service` → `valkey.service` | Client library compatibility |
| Default user: `redis` → `valkey` | Ports (6379, 26379, bus +10000) |
| Server identity: INFO/HELLO/LOLWUT report "valkey" | ACL syntax |
| RDB magic (9.0+): `REDIS` → `VALKEY` for version 80+ | Lua scripting |
|  | Module API (Redis modules load) |

## `extended-redis-compatibility` - identity mask

```
CONFIG SET extended-redis-compatibility yes
```

When `yes`, Valkey reports `redis_version: 7.2.4` in `INFO`, `HELLO`, `LOLWUT`, and `CLIENT SETNAME` responses. Useful transition knob for clients that check the server identity string. Runtime-modifiable; turn off once every client is updated.

## Three migration paths

### 1. Binary replacement (minutes of downtime)

Stop Redis, copy `dump.rdb` (or `appendonlydir/`) into Valkey's data dir, update paths in `valkey.conf`, fix ownership, start Valkey. Safest for simple single-instance deployments where you own a maintenance window. Downtime equals AOF replay time on large datasets.

### 2. Replication-based (seconds of switchover)

Spin up Valkey as a replica of the running Redis primary:

```
REPLICAOF redis-host 6379
```

Wait for `master_link_status:up` and `master_sync_in_progress:0`. Verify `DBSIZE` matches. Flip client endpoints. Promote Valkey with `REPLICAOF NO ONE`. Shut down Redis. Downtime is the client endpoint-flip window only.

Valkey's `replicaof` accepts and follows a Redis primary; the old `slaveof` keyword also works as an alias. Works for Redis OSS 7.2 and below.

### 3. Cluster migration (zero downtime per shard)

For Redis Cluster deployments. For each Redis primary, add a Valkey node as its replica (`--cluster add-node ... --cluster-replica --cluster-master-id <redis-primary-node-id>`). Wait for all Valkey replicas to sync. Failover each shard by running `CLUSTER FAILOVER` on the Valkey replica. Remove old Redis nodes with `--cluster del-node`. Verify with `valkey-cli --cluster check`.

Cross-version caveat: during the mixed window, any resharding uses legacy key-by-key MIGRATE (ASM requires all nodes on Valkey 9.0+).

## Immutable configs - restart required

These cannot be changed at runtime (`IMMUTABLE_CONFIG`):

`cluster-enabled`, `daemonize`, `databases`, `cluster-config-file`, `unixsocket`, `logfile`, `syslog-enabled`, `aclfile`, `appendfilename`, `appenddirname`, `tcp-backlog`, `cluster-port`, `supervised`, `pidfile`, `disable-thp`. Get them right in the migrated `valkey.conf` before start.

`bind` and `port` ARE runtime-modifiable despite what some Redis docs claim.

## Validation after migration

1. **Key count**: `INFO keyspace` - `db0:keys` match source and target.
2. **Spot check**: pull a handful via `RANDOMKEY` + `TYPE` + `GET`/`HGETALL`/`LRANGE` on both sides.
3. **TTL**: compare `PTTL` on samples - should be within a few seconds.
4. **Replication offset** (if using method 2): `master_repl_offset` matches before promotion.
5. **Cluster check** (method 3): `valkey-cli --cluster check` - all 16384 slots covered, no errors.
6. **commandstats**: `INFO commandstats` - no unexpected `failed_calls` climbing post-cutover.
7. **Application tests**: run your own smoke tests, compare p50/p99 latency, monitor error rates.

## Migration checklist

- [ ] Verify source is Redis OSS ≤ 7.2 (not Redis CE 7.4+).
- [ ] Install Valkey on target hosts; confirm allocator (`mem_allocator`) and build flags match target workload.
- [ ] Translate `redis.conf` → `valkey.conf`, update paths, review Valkey-specific defaults (lazyfree all `yes`, COMMANDLOG, hide-user-data-from-log).
- [ ] Enable `extended-redis-compatibility yes` temporarily if any client does identity checks.
- [ ] Test the flow in staging with a sample of production data.
- [ ] Update monitoring/alerts for new binary names, new INFO fields, COMMANDLOG replacing SLOWLOG.
- [ ] Execute the chosen migration method.
- [ ] Post-cutover: disable `extended-redis-compatibility`, update backup scripts for new paths.
