# Cluster Enhancements

Use when working with Valkey in cluster mode and you want to understand the new capabilities in 9.0 - numbered databases and atomic slot migration.

## Numbered Databases in Cluster Mode (Valkey 9.0+)

### Background

Before 9.0, cluster mode was restricted to database 0. `SELECT` returned an error, forcing applications to use key prefixes for namespace isolation.

Valkey 9.0 lifts this restriction. Configure via `cluster-databases` (default 1, only database 0). Set `cluster-databases 16` to enable databases 0-15.

`cluster-databases` is **immutable** - set it at startup in valkey.conf or on the command line; it cannot be changed with `CONFIG SET`. Changing the value requires a restart. Plan capacity up-front.

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

**Atomic key migration via MOVE**: Move a key atomically from one database to another within the same node.

```
# Prepare value in staging database
SELECT 1
SET mykey "new_value"

# Move to production database
MOVE mykey 0
```

MOVE reply semantics:

- Returns `1` on success.
- Returns `0` (not an error) if the source key doesn't exist, OR if the destination already holds that key. The caller must distinguish these cases themselves (e.g. with EXISTS before/after).
- Returns a cluster redirect error if the slot of `mykey` is currently being imported or exported on this node - MOVE is blocked during active slot migration touching that slot.

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

Traditional cluster resharding (`CLUSTER SETSLOT MIGRATING` + `MIGRATE` per key) moves keys one at a time. During the migration window clients hitting the slot receive per-key ASK redirects and must query both source and target, amplifying latency and requiring ASK/MOVED handling in the client.

### How atomic migration works

9.0 adds a new command family (`CLUSTER MIGRATESLOTS`, `CLUSTER GETSLOTMIGRATIONS`, `CLUSTER CANCELSLOTMIGRATIONS`) that moves whole slot ranges through a snapshot-and-stream protocol:

1. Source takes a snapshot of the slot's keys (uses an AOF-format rewrite internally).
2. Source streams the snapshot plus any live writes to the target.
3. When the target has caught up, the source pauses writes briefly on the slot.
4. Ownership transfers atomically via a failover of the slot to the target.
5. Clients that next hit the slot on the old owner get a single `MOVED` redirect.

During the migration window there are **no per-key ASK redirects**. There is a brief write pause at cutover (step 3-4) - typically milliseconds, but it's not instantaneous. Reads and writes on other slots are unaffected.

### How to invoke it

This is **not** triggered automatically by `valkey-cli --cluster reshard` in 9.0.x (valkey-cli's reshard in 9.0 still uses the traditional per-key path). You have to call the commands directly. Support in valkey-cli lands in 9.1+.

```
# Migrate slots 0-4095 from this node to target node <node-id>
CLUSTER MIGRATESLOTS SLOTSRANGE 0 4095 NODE <40-char-node-id>

# Multiple ranges and targets in one call
CLUSTER MIGRATESLOTS SLOTSRANGE 0 1000 NODE <node-id-A> \
                     SLOTSRANGE 5000 5500 NODE <node-id-B>
```

Ranges are inclusive. Node IDs are the 40-hex-char names from `CLUSTER NODES`.

### Monitoring

```
CLUSTER GETSLOTMIGRATIONS
```

Returns an array of maps, one per active or recently-finished migration. Useful fields per entry:

- `operation` - `IMPORT` or `EXPORT`
- `slot_ranges` - e.g. `"0-4095"`
- `source_node`, `target_node` - 40-char node IDs
- `state` - which phase of the state machine the job is in (snapshotting, streaming, paused, failover, cleaning up, finished, cancelled, failed)
- `last_update_time` - detect stalled jobs
- `remaining_repl_size` (9.1+) - bytes still to ship

### Cancelling

```
CLUSTER CANCELSLOTMIGRATIONS
```

Cancels all active migration jobs on the node. The slot stays with its original owner. Safe to call - cancelling after cutover has already completed is a no-op on that job.

### What this means for application code

| Before (traditional) | Atomic (9.0+) |
|----------------------|---------------|
| Per-key ASK redirects during migration | No ASK redirects |
| Client must handle interleaved ASK/MOVED | One `MOVED` per client after cutover |
| Key-by-key transfer (slow for large slots) | Bulk snapshot + stream |
| Writes to the migrating slot succeed throughout | Brief write pause at cutover (ms-scale) |

Transparent to most application code - clients that already refresh topology on `MOVED` work without changes. The brief cutover pause is short enough that retry-on-timeout clients tolerate it, but latency-sensitive systems should schedule migrations outside peak traffic.

