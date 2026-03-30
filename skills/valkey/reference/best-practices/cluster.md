# Cluster Best Practices

Use when building applications that run on Valkey Cluster - designing keys for multi-key operations, understanding redirects, reading from replicas, scanning, or pipelining in cluster mode.

---

## Hash Tags for Multi-Key Commands

Valkey Cluster distributes keys across 16,384 hash slots. Each key maps to exactly one slot based on a CRC16 hash. Multi-key commands (`MGET`, `MSET`, `SINTER`, `SUNION`, Lua scripts with multiple keys) only work when all keys are in the same slot.

Hash tags force the slot assignment to use only the substring between `{` and `}`:

```
# These all hash to the same slot (based on "user:1000")
{user:1000}.profile
{user:1000}.cart
{user:1000}.sessions

# Multi-key operations work
MGET {user:1000}.profile {user:1000}.cart
```

### Design Patterns

| Data Model | Key Pattern | Why |
|-----------|-------------|-----|
| User data | `{user:1000}.profile`, `{user:1000}.prefs` | MGET user data in one call |
| Order + items | `{order:5678}.header`, `{order:5678}.items` | Atomic transaction on order |
| Rate limit shards | `{ratelimit:api}.shard:0` ... `.shard:15` | MGET all shards to sum |
| Tag search indexes | `{tags}.electronics`, `{tags}.wireless` | SINTER across tag sets |

### Node.js

```javascript
// User data co-located with hash tags
async function getUserData(redis, userId) {
  const [profile, prefs, cart] = await redis.mget(
    `{user:${userId}}.profile`,
    `{user:${userId}}.prefs`,
    `{user:${userId}}.cart`
  );
  return { profile: JSON.parse(profile), prefs: JSON.parse(prefs), cart: JSON.parse(cart) };
}
```

### Python

```python
async def get_user_data(redis, user_id: str):
    profile, prefs, cart = await redis.mget(
        f'{{user:{user_id}}}.profile',
        f'{{user:{user_id}}}.prefs',
        f'{{user:{user_id}}}.cart',
    )
    return {
        'profile': json.loads(profile),
        'prefs': json.loads(prefs),
        'cart': json.loads(cart),
    }
```

### Gotchas

- **Empty hash tags**: `{}` is treated as no hash tag - the full key is hashed. `{}.foo` also hashes the full key (empty substring between braces is not a valid hash tag).
- **Hot slot risk**: If you co-locate too many keys under one hash tag (e.g., all user data for a very popular user), that slot becomes hot. Balance co-location needs against load distribution.
- **First `{...}` wins**: Only the first `{...}` pair is used. `{a}.{b}` hashes on `a`, not `b`.
- **Check with CLUSTER KEYSLOT**: Verify your key design during development: `CLUSTER KEYSLOT "{user:1000}.profile"`.

---

## Cross-Slot Errors

When a multi-key command references keys in different slots, Valkey returns a `CROSSSLOT` error:

```
SET user:1:name "Alice"
SET user:2:name "Bob"
MGET user:1:name user:2:name
# (error) CROSSSLOT Keys in request don't hash to the same slot
```

### Commands That Require Same Slot

- `MGET`, `MSET`, `MSETNX`
- `SINTER`, `SUNION`, `SDIFF` and their `STORE` variants
- `ZINTER`, `ZUNION`, `ZDIFF` and their `STORE` variants
- `LMOVE`, `SMOVE`, `RENAME`, `RENAMENX`
- `EVAL` / `FCALL` with multiple KEYS
- `COPY`

### Commands That Work Across Slots

- Any single-key command (`GET`, `SET`, `HGET`, `ZADD`, etc.)
- `DEL` and `UNLINK` with multiple keys (executed per-slot internally by most clients)
- `SCAN` / `CLUSTERSCAN` (iterates the whole keyspace or specific nodes)

### Fixing Cross-Slot Issues

1. **Add hash tags**: Redesign keys to co-locate related data (see above)
2. **Split into single-key operations**: Replace `MGET key1 key2` with individual `GET` calls in a pipeline
3. **Client-side fan-out**: Most cluster-aware clients automatically split multi-key commands across nodes. Valkey GLIDE does this transparently.

---

## MOVED and ASK Redirects

In cluster mode, a client may connect to any node and be told to try a different one. Your client library handles this automatically - understanding it helps with debugging.

### MOVED Redirect

The key permanently lives on a different node:

```
GET user:1000
# -MOVED 3999 10.0.0.2:6379
```

Meaning: Slot 3999 is owned by 10.0.0.2:6379. The client should update its slot-to-node mapping and retry there. All future requests for this slot go to the new node.

### ASK Redirect

The key is temporarily being migrated to another node:

```
GET user:2000
# -ASK 8901 10.0.0.3:6379
```

Meaning: Slot 8901 is being migrated to 10.0.0.3:6379. The client should send `ASKING` followed by the command to the target node - but only for this one request. Future requests still go to the original node until migration completes.

**Valkey 9.0+ note**: Atomic slot migration eliminates ASK redirects. Slots move atomically, so clients only see MOVED redirects after the migration completes.

### What Your Client Does

All production clients (ioredis, Valkey GLIDE, valkey-py, Jedis, go-redis) handle MOVED/ASK automatically:
- Maintain an internal slot-to-node mapping
- Refresh the mapping on MOVED
- Follow ASK with the ASKING prefix
- Retry transparently

**When you see redirect errors in logs**: Usually means the slot mapping cache is stale. This is normal during cluster topology changes. If redirects are excessive, check for ongoing resharding or frequent failovers.

---

## Read-From-Replica Strategies

By default, all reads go to the primary that owns the slot. Reading from replicas reduces primary load at the cost of potential staleness.

### Enabling Replica Reads

```
# Tell the replica to accept read commands
READONLY

# Switch back to primary-only
READWRITE
```

### Client Configuration

**ioredis**:
```javascript
const cluster = new Redis.Cluster(nodes, {
  scaleReads: 'slave',    // Read from replicas
  // Options: 'master' (default), 'slave', 'all', custom function
});
```

**Valkey GLIDE**:
```javascript
const config = new ClusterClientConfiguration({
  addresses: nodes,
  readFrom: ReadFrom.PreferReplica,
  // Options: Primary, PreferReplica, AZAffinity
});
```

**valkey-py**:
```python
from valkey.cluster import ValkeyCluster, ReadFrom
client = ValkeyCluster(
    startup_nodes=nodes,
    read_from_replicas=True,
)
```

### Consistency Trade-offs

| Strategy | Latency | Consistency | Use Case |
|----------|---------|-------------|----------|
| Primary only (default) | Higher | Strong (read-your-writes) | Transactions, user-facing writes |
| Prefer replica | Lower | Eventual (replication lag) | Dashboards, analytics, cache reads |
| AZ-affinity | Lowest | Eventual | Multi-AZ deployments, minimize cross-AZ traffic |

**Replication lag**: Typically sub-millisecond under normal load. Can spike to seconds under heavy write load or during full resync. Never assume zero lag.

### When to Read from Replicas

- Read-heavy workloads where slight staleness is acceptable
- Analytics dashboards and reporting
- Geographically distributed deployments (read from local replica)

### When NOT to Read from Replicas

- After a write where the application immediately reads back the value
- Session validation (user just logged in, checking session on next request)
- Inventory checks before purchase (stale count could oversell)

For critical read-after-write scenarios, use `WAIT` to block until the write has replicated:

```
SET order:5678:status "confirmed"
WAIT 1 100
# Blocks until at least 1 replica has acknowledged the write, or 100ms timeout
```

---

## Pipelining in Cluster Mode

Pipelining works in cluster mode, but with a constraint: each node receives only the commands for keys it owns. Cluster-aware clients handle this by grouping commands by slot/node.

### How Clients Handle It

1. Client builds the pipeline
2. Client computes the hash slot for each command's key
3. Client groups commands by target node
4. Client sends one pipeline per node in parallel
5. Client reassembles results in original order

This is transparent to your code. Pipeline normally:

```javascript
// ioredis in cluster mode - works identically to standalone
const pipeline = cluster.pipeline();
pipeline.get('user:1');    // Node A
pipeline.get('user:2');    // Node B
pipeline.get('user:3');    // Node A
const results = await pipeline.exec();
// Results in original order: [user:1, user:2, user:3]
```

**Valkey GLIDE**: Handles this automatically with its multiplexed connection design. No explicit pipeline needed.

### Performance Note

Pipeline depth per-node is what matters. A 100-command pipeline across 3 nodes sends ~33 commands per node. The throughput improvement is proportional to per-node batch size, not total pipeline size.

---

## SCAN in Cluster Mode

### The Problem

`SCAN` iterates keys on a single node. In a cluster, each node holds a subset of keys. To scan the entire keyspace, you must scan each primary node individually.

### CLUSTERSCAN (Valkey 9.1+)

Valkey provides `CLUSTERSCAN` which handles cluster-wide iteration:

```
CLUSTERSCAN 0 MATCH user:* COUNT 100
# Returns: [next_cursor, [key1, key2, ...]]
# Cursor encodes both node and position - just keep calling until cursor is 0
```

`CLUSTERSCAN` abstracts away the per-node iteration. Use it when your client supports it.

### Per-Node SCAN (Fallback)

If your client does not support CLUSTERSCAN, iterate each primary node individually:

**Node.js (ioredis)**:
```javascript
async function clusterScan(cluster, pattern) {
  const results = [];
  const nodes = cluster.nodes('master');

  for (const node of nodes) {
    let cursor = '0';
    do {
      const [nextCursor, keys] = await node.scan(
        cursor, 'MATCH', pattern, 'COUNT', 100
      );
      cursor = nextCursor;
      results.push(...keys);
    } while (cursor !== '0');
  }
  return results;
}
```

**Python (valkey-py)**:
```python
async def cluster_scan(client, pattern: str):
    results = set()
    for node in client.get_primaries():
        cursor = 0
        while True:
            cursor, keys = await node.scan(cursor, match=pattern, count=100)
            results.update(keys)
            if cursor == 0:
                break
    return results
```

### Gotchas

- **SCAN on replicas**: Works but may return slightly stale data. Use primary nodes for consistent results.
- **Cluster topology changes during scan**: If a node goes down or slots move during iteration, you may miss keys or see duplicates. For critical scans, pause resharding.
- **KEYS is still forbidden**: `KEYS *` in cluster mode only hits one node and blocks it. Never use it.

---

## Quick Reference: Cluster Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Multi-key command without hash tags | CROSSSLOT error | Add `{tag}` prefix to related keys |
| All data under one hash tag | One node overloaded | Distribute hash tags across entities |
| Reading stale data from replica | Inconsistent results after write | Use primary reads or WAIT |
| SCAN missing keys | Partial results | Use CLUSTERSCAN or per-node iteration |
| Large Lua script touching many keys | Slow, blocks node | Limit script to keys in one slot |
| Pub/Sub in cluster | Messages not received | Use sharded pub/sub (SSUBSCRIBE/SPUBLISH) |

---

## See Also

**Best Practices**:
- [Key Best Practices](keys.md) - key naming, hash tag design, namespace conventions
- [Performance Best Practices](performance.md) - pipelining and connection pooling
- [High Availability Best Practices](high-availability.md) - Sentinel vs Cluster decision, failover behavior
- [Memory Best Practices](memory.md) - encoding thresholds apply per-key across all shards
- [Persistence Best Practices](persistence.md) - RDB/AOF behavior across cluster nodes

**Commands**:
- [Scripting and Functions](../commands/scripting.md) - Lua scripts in cluster require all keys in one slot
- [Server Commands](../commands/server.md) - CLUSTER INFO, CLUSTER KEYSLOT for debugging

**Patterns**:
- [Counter Patterns](../patterns/counters.md) - sharded counters to spread hot keys across nodes
- [Lock Patterns](../patterns/locks.md) - Redlock for distributed locking across cluster nodes
- [Pub/Sub Patterns](../patterns/pubsub-patterns.md) - sharded pub/sub (SSUBSCRIBE/SPUBLISH) for cluster mode
- [Rate Limiting Patterns](../patterns/rate-limiting.md) - hash tag routing for rate limit keys
- [Caching Patterns](../patterns/caching.md) - co-locating cache keys with hash tags
- [Search and Autocomplete Patterns](../patterns/search-autocomplete.md) - co-locating index keys for multi-key operations
- [Session Patterns](../patterns/sessions.md) - co-locating session data with hash tags

**Security**:
- [Security: Auth and ACL](../security/auth-and-acl.md) - ACL restrictions per cluster node

**Clients**:
- [Clients Overview](../clients/overview.md) - cluster-aware client behavior, redirect handling, and replica reads

**Valkey Features**: [Cluster Enhancements](../valkey-features/cluster-enhancements.md) - Valkey 9.0 atomic slot migration and numbered databases

**Anti-Patterns**: [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - CROSSSLOT errors, hot slots, Lua in cluster pitfalls

**Ops**: valkey-ops [cluster/setup](../../../valkey-ops/reference/cluster/setup.md), [cluster/operations](../../../valkey-ops/reference/cluster/operations.md), [cluster/resharding](../../../valkey-ops/reference/cluster/resharding.md)
