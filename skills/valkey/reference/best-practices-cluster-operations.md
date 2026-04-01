# Cluster Operations

Use when handling MOVED/ASK redirects, reading from replicas, pipelining in cluster mode, or scanning keys across a Valkey Cluster.

## Contents

- MOVED and ASK Redirects (line 13)
- Read-From-Replica Strategies (line 53)
- Pipelining in Cluster Mode (line 127)
- SCAN in Cluster Mode (line 159)
- Quick Reference: Cluster Pitfalls (line 223)

---

## MOVED and ASK Redirects

A client may connect to any node and be told to try a different one. Client libraries handle this automatically - understanding it helps with debugging.

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

Redirect errors in logs mean the slot mapping cache is stale - normal during topology changes. Excessive redirects indicate ongoing resharding or frequent failovers.

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

**Replication lag**: Sub-millisecond under normal load. Can spike to seconds under heavy writes or during full resync. Never assume zero lag.

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

Pipelining works in cluster mode. Each node receives only commands for keys it owns. Cluster-aware clients group commands by slot/node automatically.

### How Clients Handle It

1. Client builds the pipeline
2. Client computes the hash slot for each command's key
3. Client groups commands by target node
4. Client sends one pipeline per node in parallel
5. Client reassembles results in original order

Transparent to application code:

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

`SCAN` iterates keys on a single node. In a cluster, scan each primary node individually to cover the full keyspace.

### CLUSTERSCAN (Valkey 9.1+)

Valkey provides `CLUSTERSCAN` which handles cluster-wide iteration:

```
CLUSTERSCAN 0 MATCH user:* COUNT 100
# Returns: [next_cursor, [key1, key2, ...]]
# Cursor encodes both node and position - just keep calling until cursor is 0
```

`CLUSTERSCAN` abstracts per-node iteration. Use when your client supports it.

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
