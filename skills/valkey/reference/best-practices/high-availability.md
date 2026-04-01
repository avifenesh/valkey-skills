# High Availability Best Practices

Use when connecting to Valkey through Sentinel, handling failovers in application code, implementing retry strategies for connection drops, or ensuring read-after-write consistency with replication.

## Contents

- Connecting via Sentinel (line 16)
- What Happens During Failover (line 76)
- Retry Strategies for Connection Drops (line 110)
- Read-After-Write Consistency (line 195)
- Architecture Decision: Sentinel vs Cluster (line 263)

---

## Connecting via Sentinel

Sentinel provides automatic failover, monitoring, and service discovery. Your application never connects to a fixed Valkey address - instead it asks Sentinel for the current primary.

### Client Configuration

**Node.js (ioredis)**:
```javascript
const Redis = require('ioredis');

const redis = new Redis({
  sentinels: [
    { host: '10.0.0.1', port: 26379 },
    { host: '10.0.0.2', port: 26379 },
    { host: '10.0.0.3', port: 26379 },
  ],
  name: 'mymaster',           // Sentinel group name
  sentinelPassword: 'secret', // If Sentinel requires auth
  password: 'valkey-pass',    // Valkey instance password
  db: 0,
});
```

**Python (valkey-py)**:
```python
from valkey.sentinel import Sentinel

sentinel = Sentinel(
    [('10.0.0.1', 26379), ('10.0.0.2', 26379), ('10.0.0.3', 26379)],
    sentinel_kwargs={'password': 'sentinel-secret'},
)

# Get connection to current primary
primary = sentinel.master_for('mymaster', password='valkey-pass', db=0)

# Get connection to a replica (for reads)
replica = sentinel.slave_for('mymaster', password='valkey-pass', db=0)
```

**Valkey GLIDE**:
```javascript
// GLIDE handles Sentinel-like behavior internally for cluster mode.
// For standalone + Sentinel, configure with primary discovery:
const config = {
  addresses: [
    { host: '10.0.0.1', port: 26379 },
  ],
  // GLIDE reconnects automatically on failover
};
```

### Key Rules

1. **Always list multiple Sentinel addresses** - if one Sentinel is down, the client falls back to another.
2. **Use the Sentinel group name** (`name` in ioredis, first argument to `master_for` in valkey-py). This is the logical service name, not a hostname.
3. **Set Sentinel auth separately from Valkey auth** - they can have different passwords.
4. **Do not hardcode the primary address** - it changes on failover. Sentinel discovery is the only correct approach.

---

## What Happens During Failover

Understanding the failover timeline helps you design appropriate retry logic.

### Timeline

```
T+0s     Primary becomes unreachable
T+0-5s   Sentinel detects failure (configurable: down-after-milliseconds)
T+5-10s  Sentinel quorum agrees primary is down
T+10-15s Sentinel promotes a replica to primary
T+15s    Clients receive notification of new primary
```

Total outage window: typically 5-30 seconds depending on Sentinel configuration.

### What Your Application Sees

1. **Connection errors**: Commands in flight fail with connection reset errors.
2. **Brief period of no primary**: New connections are refused until a new primary is elected.
3. **Sentinel notification**: Clients subscribed to Sentinel reconnect to the new primary automatically.
4. **Possible stale reads from replicas**: The promoted replica may be missing the last few writes from the old primary (replication is asynchronous).

### Data Loss Window

Valkey replication is asynchronous by default. Writes acknowledged by the old primary but not yet replicated to any replica are lost during failover. This window depends on:

- Replication lag (typically sub-millisecond, but variable)
- Time between primary failure and last replicated write

For most applications, this is acceptable. For scenarios where write loss is critical, see the WAIT/WAITAOF section below.

---

## Retry Strategies for Connection Drops

### ioredis Built-in Retry

ioredis retries automatically with configurable behavior:

```javascript
const redis = new Redis({
  sentinels: [...],
  name: 'mymaster',
  retryStrategy(times) {
    // Exponential backoff: 50ms, 100ms, 200ms, ..., capped at 2s
    const delay = Math.min(times * 50, 2000);
    return delay;
    // Return null to stop retrying
  },
  maxRetriesPerRequest: 3,       // Fail fast per command (null = infinite)
  enableOfflineQueue: true,      // Queue commands while disconnected
});
```

### valkey-py Retry

```python
from valkey.backoff import ExponentialBackoff
from valkey.retry import Retry
from valkey.exceptions import ConnectionError, TimeoutError

retry = Retry(ExponentialBackoff(), retries=3)

client = valkey.Valkey(
    host='primary',
    port=6379,
    retry=retry,
    retry_on_error=[ConnectionError, TimeoutError],
    socket_connect_timeout=5,
    socket_timeout=5,
)
```

### Application-Level Retry Pattern

For critical operations, wrap Valkey calls with application-level retry:

```javascript
async function withRetry(fn, maxRetries = 3) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      const isRetryable = (
        err.message.includes('READONLY') ||
        err.message.includes('LOADING') ||
        err.code === 'ECONNREFUSED' ||
        err.code === 'ECONNRESET'
      );

      if (!isRetryable || attempt === maxRetries - 1) throw err;

      const delay = Math.min(100 * Math.pow(2, attempt), 2000);
      await new Promise(r => setTimeout(r, delay + Math.random() * delay * 0.5));
    }
  }
}

// Usage
const result = await withRetry(() => redis.get('user:1000'));
```

### Key Error Signals

| Error | Meaning | Action |
|-------|---------|--------|
| `READONLY` | You are talking to a replica that was just promoted or you followed a stale mapping | Retry - client will rediscover primary |
| `LOADING` | Server is loading dataset from disk after restart | Retry after delay |
| `ECONNREFUSED` | Server is down | Retry with backoff |
| `ECONNRESET` | Connection dropped mid-command | Retry (idempotent commands only) |
| `CLUSTERDOWN` | Cluster cannot serve requests (not enough nodes) | Alert ops team, retry with long backoff |

### Idempotency Warning

Only retry commands that are idempotent. `SET`, `GET`, `HSET`, `ZADD` are safe to retry. `INCR`, `LPUSH`, `RPUSH` are NOT idempotent - retrying them can cause double-counting or duplicate entries. For non-idempotent operations, use the idempotency key pattern (see [Counter Patterns](../patterns/counters.md)).

---

## Read-After-Write Consistency

### WAIT

`WAIT` blocks the current client until previous write commands have been replicated to a specified number of replicas, or until the timeout expires.

```
SET user:1000:email "alice@example.com"
WAIT 1 100
# Blocks until at least 1 replica acknowledged the write, or 100ms timeout
# Returns: number of replicas that acknowledged (0 if timeout)
```

**Node.js**:
```javascript
async function writeWithConsistency(redis, key, value) {
  await redis.set(key, value);
  const acks = await redis.wait(1, 100); // 1 replica, 100ms timeout
  if (acks === 0) {
    console.warn('Write not yet replicated - failover could lose this write');
  }
}
```

**Python**:
```python
async def write_with_consistency(redis, key: str, value: str):
    await redis.set(key, value)
    acks = await redis.wait(1, 100)
    if acks == 0:
        logger.warning('Write not yet replicated')
```

### WAITAOF (since 7.2)

`WAITAOF` blocks until previous writes have been fsynced to disk on the primary and/or replicas. Stronger guarantee than `WAIT`, which only confirms in-memory replication.

```
SET critical:transaction:9876 "committed"
WAITAOF 1 1 500
# Blocks until: 1 local fsync + 1 replica fsync, or 500ms timeout
# Returns: [local_fsyncs, replica_fsyncs]
```

Arguments: `WAITAOF <local_fsyncs> <replica_fsyncs> <timeout_ms>`

- `local_fsyncs`: Number of local AOF fsyncs to wait for (0 or 1)
- `replica_fsyncs`: Number of replica AOF fsyncs to wait for
- `timeout_ms`: Maximum wait time in milliseconds

### When to Use WAIT/WAITAOF

| Scenario | Command | Trade-off |
|----------|---------|-----------|
| Read-after-write from replica | `WAIT 1 100` | Adds up to 100ms latency per write |
| Financial transactions | `WAITAOF 1 1 500` | Strongest durability, higher latency |
| Normal application writes | Neither | Accept async replication risk |
| Cache writes | Neither | Loss is harmless (refetch from source) |

### Gotchas

- **WAIT does not make replication synchronous** - it only blocks the calling client. Other clients can still read stale data from replicas during the wait.
- **Timeout of 0 blocks forever** - always set a reasonable timeout.
- **WAIT in a pipeline**: WAIT applies to all preceding writes in the connection. Place it after the last write you care about.
- **Performance impact**: Do not use WAIT on every write. Reserve it for critical paths where data loss is unacceptable.

---

## Architecture Decision: Sentinel vs Cluster

| Factor | Sentinel | Cluster |
|--------|----------|---------|
| Data size | Fits in one node's memory | Exceeds one node's memory |
| Throughput | One primary handles the load | Need to distribute writes |
| Failover | Automatic (5-30s) | Automatic (faster, built-in) |
| Multi-key commands | All work (single primary) | Only within same hash slot |
| Client complexity | Sentinel-aware client needed | Cluster-aware client needed |
| Operational complexity | Moderate (3+ Sentinels) | Higher (6+ nodes minimum) |

**Start with Sentinel** unless you need sharding for capacity. Migrate to Cluster when a single primary cannot handle your data size or write throughput.

---

