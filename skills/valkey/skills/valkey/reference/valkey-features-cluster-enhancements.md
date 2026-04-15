# Cluster Enhancements

Use when working with Valkey in cluster mode and you want to understand the new capabilities in 9.0 - numbered databases and atomic slot migration.

## Numbered Databases in Cluster Mode (Valkey 9.0+)

### Background

Before 9.0, cluster mode was restricted to database 0. `SELECT` returned an error, forcing applications to use key prefixes for namespace isolation.

Valkey 9.0 lifts this restriction. Configure via `cluster-databases` (default 1, only database 0). Set `cluster-databases 16` to enable databases 0-15.

### How It Works

```
SELECT 0
SET mykey "db0_value"

SELECT 5
SET mykey "db5_value"    # Different namespace, same key name, same slot
```

Each database is a separate namespace. The same key name in database 0 and database 5 are independent entries. Hash slot assignment still applies - `mykey` maps to the same slot regardless of database.

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

Constraints:

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

Traditional cluster resharding migrates keys one at a time. During migration, clients hitting the slot receive ASK redirects and must query both source and target, causing:

- Increased latency from redirects
- Potential errors from partial slot states
- Complex client redirect handling

### How Atomic Migration Works

Valkey 9.0 serializes the entire slot as an AOF-format payload and transfers it atomically. Clients redirect instantly to the target node with zero intermediate states.

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

Transparent to application code. Existing clients handling MOVED redirects work without changes.

---

## Configuration

Numbered databases in cluster mode use the `cluster-databases` configuration directive (default 1):

```
cluster-databases 16    # Enable 16 databases (0-15) in cluster mode
```

Atomic slot migration is enabled automatically in Valkey 9.0+ when using the cluster resharding tools. No special configuration is needed.

---

