# Cluster Enhancements

Use when working with Valkey in cluster mode and you want to understand the new capabilities in 9.0 - numbered databases and atomic slot migration.

## Contents

- Numbered Databases in Cluster Mode (Valkey 9.0+) (line 14)
- Atomic Slot Migration (Valkey 9.0+) (line 66)
- Configuration (line 99)
- See Also (line 111)

---

## Numbered Databases in Cluster Mode (Valkey 9.0+)

### Background

In Redis and Valkey prior to 9.0, cluster mode was restricted to database 0. The `SELECT` command returned an error if you tried to switch databases. This was a long-standing limitation that forced applications to use key prefixes for namespace isolation instead of database numbers.

Valkey 9.0 lifts this restriction. Multiple databases are available in cluster mode when configured via the `cluster-databases` directive (default 1, meaning only database 0). Set `cluster-databases 16` to enable databases 0-15.

### How It Works

```
SELECT 0
SET mykey "db0_value"

SELECT 5
SET mykey "db5_value"    # Different namespace, same key name, same slot
```

Each database is a separate namespace. The same key name in database 0 and database 5 are independent entries. Hash slot assignment still applies - `mykey` maps to the same slot regardless of which database you are in.

### Use Cases

**Logical data separation**: Separate cache data (database 0) from session data (database 1) without key prefix conventions.

**Testing and debugging**: Compare behavior of the same keys across databases. Use one database for production traffic and another for shadow testing.

**Atomic key migration via MOVE**: Move a key atomically from one database to another within the same node. MOVE fails if the key already exists in the destination database.

```
# Prepare value in staging database
SELECT 1
SET mykey "new_value"

# Move to production database (succeeds only if mykey does not exist in db 0)
MOVE mykey 0
```

### Limitations

Applications should be aware of these constraints:

| Limitation | Detail |
|-----------|--------|
| No resource isolation | All databases share the same memory, CPU, and connections (noisy neighbor risk) |
| Limited ACL controls | ACLs can restrict database access but the granularity is coarse |
| Per-node scope | `FLUSHDB`, `SCAN`, and `DBSIZE` operate on the current node only, not cluster-wide |
| Client complexity | Most client libraries default to database 0; ensure your client supports SELECT in cluster mode |

For strong isolation between workloads, separate Valkey instances or clusters remain the recommended approach. Numbered databases are best for lightweight namespace separation.

---

## Atomic Slot Migration (Valkey 9.0+)

### Background

In traditional Valkey/Redis cluster resharding, keys are migrated one at a time from a source node to a target node. During migration, clients hitting the slot receive ASK redirects and must query both the source and target. This causes:

- Increased client latency from redirects
- Potential errors from partial slot states
- Complexity in client redirect handling during resharding

### How Atomic Migration Works

Valkey 9.0 introduces atomic slot migration. Instead of moving keys individually, the entire slot is serialized as an AOF-format payload and transferred atomically. Once complete, clients redirect instantly to the target node with zero intermediate states.

### What This Means for Application Developers

| Before (Traditional) | After (Atomic, 9.0+) |
|----------------------|----------------------|
| ASK redirects during migration | No redirects - instant cutover |
| Possible transient errors during resharding | Clean switch |
| Client must handle ASK/MOVED interleaving | Standard MOVED redirect only |
| Key-by-key transfer (slow for large slots) | Bulk transfer (faster) |

### Practical Impact

- **Cluster scaling is smoother** - adding or removing nodes causes less disruption to running applications
- **Simpler client behavior** - no need to handle ASK redirects during slot migration
- **Faster resharding** - bulk transfer is faster than key-by-key migration for slots with many keys

This is transparent to application code. Existing clients that handle MOVED redirects (which all production-grade clients do) work without changes.

---

## Configuration

Numbered databases in cluster mode use the `cluster-databases` configuration directive (default 1):

```
cluster-databases 16    # Enable 16 databases (0-15) in cluster mode
```

Atomic slot migration is enabled automatically in Valkey 9.0+ when using the cluster resharding tools. No special configuration is needed.

---

## See Also

- [What is Valkey](../overview/what-is-valkey.md) - overview and Valkey-only feature list
- [Compatibility and Migration](../overview/compatibility.md) - migrating from Redis to Valkey
- [Conditional Operations](conditional-ops.md) - SET IFEQ and DELIFEQ
- [Hash Field Expiration](hash-field-ttl.md) - per-field TTL on hash entries
- [Polygon Geospatial Queries](geospatial.md) - GEOSEARCH BYPOLYGON (also 9.0)
- [Performance Summary](performance-summary.md) - atomic slot migration performance context
- [Server Commands](../basics/server-and-scripting.md) - SELECT, DBSIZE, and CONFIG GET for cluster-databases
- [Transaction Commands](../basics/server-and-scripting.md) - all keys in a transaction must share the same hash slot
- [Pub/Sub Commands](../basics/data-types.md) - sharded pub/sub routes within the owning shard
- [Key Best Practices](../best-practices/keys.md) - cluster hash tags for key co-location
- [Security: Auth and ACL](../security/auth-and-acl.md) - ACL database restrictions in cluster mode
- For cluster operations: see valkey-ops `reference/cluster/resharding.md` and `reference/cluster/operations.md`
- For cluster internals: see valkey-dev `reference/cluster/slot-migration.md`
