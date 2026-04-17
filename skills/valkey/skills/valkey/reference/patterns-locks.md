# Distributed Lock Patterns

Use when implementing mutual exclusion across distributed services, preventing duplicate processing, or coordinating access to shared resources.

## Simple Lock (Single Instance)

The fundamental building block: a key that represents ownership of a resource.

### Acquire

Use `SET` with `NX` (only if not exists) and `PX` (millisecond TTL):

```
SET lock:resource <random_value> NX PX 30000
# Returns OK if acquired, nil if already held
```

**Critical rules**:

1. **Always use a random value** as the lock value (UUID or cryptographic random). This identifies the lock owner for safe release.
2. **Always set a TTL**. Without it, a crashed client holds the lock forever.
3. **NX is atomic** - the check-and-set happens in a single operation, preventing race conditions.

### Release

Only release if you still hold the lock. Without this check, a slow client could release another client's lock.

**Valkey 9.0+ (DELIFEQ)**:
```
DELIFEQ lock:resource <my_random_value>
# Returns 1 if deleted (you were the owner)
# Returns 0 if not deleted (someone else holds it now)
```

`DELIFEQ` atomically checks the value and deletes - no Lua script needed.

**Pre-9.0 (Lua script)**:
```lua
if server.call('GET', KEYS[1]) == ARGV[1] then
    return server.call('DEL', KEYS[1])
else
    return 0
end
```

Usage:
```
EVALSHA <sha1> 1 lock:resource <my_random_value>
```

### Code Examples

**Node.js**:
```javascript
const crypto = require('crypto');

async function acquireLock(redis, resource, ttlMs = 30000) {
  const value = crypto.randomUUID();
  const result = await redis.set(
    `lock:${resource}`, value, 'NX', 'PX', ttlMs
  );
  return result === 'OK' ? value : null;
}

async function releaseLock(redis, resource, value) {
  // Valkey 9.0+: use DELIFEQ
  const result = await redis.sendCommand(
    ['DELIFEQ', `lock:${resource}`, value]
  );
  return result === 1;
}
```

**Python**:
```python
import uuid

async def acquire_lock(redis, resource: str, ttl_ms: int = 30000):
    value = str(uuid.uuid4())
    acquired = await redis.set(
        f"lock:{resource}", value, nx=True, px=ttl_ms
    )
    return value if acquired else None

async def release_lock(redis, resource: str, value: str) -> bool:
    # Valkey 9.0+: use DELIFEQ
    result = await redis.execute_command(
        "DELIFEQ", f"lock:{resource}", value
    )
    return result == 1
```

---

## Lock Extension (Renewal)

Long-running tasks may need to extend the lock before it expires. Only the lock owner can extend.

**Valkey 8.1+ (SET IFEQ)**:
```
# Extend TTL only if we still hold the lock
SET lock:resource <my_random_value> IFEQ <my_random_value> PX 30000
# IFEQ = only if key exists AND current value matches
```

**Handling the reply**: IFEQ aborts (returns `nil`) in two cases - value mismatch (someone else holds the lock) **or** the key is missing (your lock already expired). IFEQ never creates a missing key. Either way, `nil` means "you no longer own this lock" - stop the protected work and bail out. A worker that ignores a `nil` renewal will keep operating on a resource a competing client now owns.

**Pre-8.1 (Lua script)**:
```lua
if server.call('GET', KEYS[1]) == ARGV[1] then
    return server.call('PEXPIRE', KEYS[1], ARGV[2])
else
    return 0
end
```

### Auto-Renewal Pattern

Renew the lock at intervals shorter than the TTL:

```javascript
function withLock(redis, resource, fn, ttlMs = 30000) {
  return new Promise(async (resolve, reject) => {
    const value = await acquireLock(redis, resource, ttlMs);
    if (!value) return reject(new Error('Failed to acquire lock'));

    // Renew at 2/3 of TTL
    const renewInterval = setInterval(async () => {
      const renewed = await redis.set(
        `lock:${resource}`, value, 'IFEQ', value, 'PX', ttlMs
      );
      if (!renewed) clearInterval(renewInterval);
    }, ttlMs * 2 / 3);

    try {
      const result = await fn();
      resolve(result);
    } finally {
      clearInterval(renewInterval);
      await releaseLock(redis, resource, value);
    }
  });
}
```

---

## Redlock (Distributed Multi-Instance)

When a single Valkey instance failure could violate mutual exclusion, Redlock acquires locks on multiple independent instances.

### Why Replication Alone Is Unsafe

```
1. Client A acquires lock on primary
2. Primary crashes before replicating the write
3. Replica promoted to primary
4. Client B acquires the same lock -> SAFETY VIOLATION
```

This is why Redlock uses N independent primaries instead of replicated instances.

### Algorithm (5 Steps)

**Setup**: N=5 independent Valkey primaries (no replication between them).

1. **Get current time** in milliseconds (T1)
2. **Try to acquire the lock** on all N instances sequentially, using the same key name and random value. Use a small per-instance timeout (5-50ms for a 10-second TTL) to avoid blocking on failed nodes.
3. **Check majority**: The lock is acquired if the client holds the lock on at least N/2 + 1 instances AND the total elapsed time (T2 - T1) is less than the lock TTL.
4. **Compute effective TTL**: If acquired, the effective validity time = initial TTL - (T2 - T1).
5. **On failure**: If the lock was NOT acquired (fewer than majority, or too much time elapsed), release the lock on ALL instances - including those believed to have failed.

### Safety Properties

- **Mutual exclusion**: Only one client holds the lock at any time
- **Deadlock-free**: Keys expire even if the holder crashes
- **Fault-tolerant**: Works as long as a majority of nodes are up

### When to Use Redlock

- Multiple independent Valkey instances (not replicas of each other)
- You need lock safety even if one Valkey instance goes down
- The cost of duplicate processing justifies the complexity

### When NOT to Use Redlock

- The lock protects an idempotent operation (duplicate execution is harmless - a single instance is fine)
- Best-effort exclusion is acceptable (rate-limiting, deduplicating "mostly unique" work) - a single primary is enough
- Performance matters more than strict mutual exclusion - Redlock's majority contact adds round-trips

Note: Sentinel failover on a single replicated deployment does **not** give you Redlock-grade safety. Replication is asynchronous, so the failure mode in "Why Replication Alone Is Unsafe" above applies. If you need true mutual exclusion across a primary crash, you need Redlock (or a CP coordination system like ZooKeeper/etcd).

### Crash Recovery Considerations

- **Without persistence**: A restarted node may allow duplicate lock acquisition. Mitigate by keeping crashed nodes unavailable for at least max-TTL duration before rejoining.
- **With AOF (fsync always)**: Safe but impacts performance.
- **With AOF (fsync every second)**: May lose the last second of data after a power outage.
- **Delayed restart**: Safest option without persistence - keep the node down for at least max-TTL after a crash.

### Retry Strategy

On failure, retry with a random delay to desynchronize competing clients. The canonical algorithm contacts instances **sequentially** with a small per-instance timeout, so one slow node can't stall the whole acquisition (the timeout trips and you move on). Some libraries parallelize the fan-out; this is an implementation trade-off - parallel is faster but harder to reason about when partial failures interact with the elapsed-time check in step 3.

### Unlocking

To release, issue `DELIFEQ lock:resource <your_random_value>` on every instance you contacted (including ones whose acquire reply you're unsure about - network glitches can leave "maybe acquired" state).

**A `0` reply from any instance is expected, not an error.** It means either the lock already expired there, or a different owner now holds it - from this client's perspective that instance is released. Continue through the remaining instances without retrying the `0` one.

### Lock Extension

For long-running operations, extend the lock by sending `SET key value IFEQ value PX new_ttl` (8.1+) to all instances - same semantics as the classic Lua extend-if-owner script, one round-trip. Consider the lock extended only if a majority succeeded within the remaining validity time. Limit reacquisition attempts to preserve liveness.

Pre-8.1: send the extend-if-owner Lua script (`if server.call('GET', K) == V then return server.call('PEXPIRE', K, T) else return 0 end`).

### Implementation Libraries

| Language | Library | Notes |
|----------|---------|-------|
| Node.js | node-redlock | Lock extension support |
| Python | Redlock-py | Standard implementation |
| Go | Redsync | Standard Go implementation |
| Java | Redisson | Feature-rich, built-in Redlock |
| Rust | Rslock | Async + lock extension |
| C# | RedLock.net | Async + lock extension |
| Ruby | Redlock-rb | Reference implementation |

---

## Fencing Tokens

Locks can fail silently: a client holds a lock, pauses (GC, network delay), the lock expires, another client acquires it, and the original client resumes thinking it still holds the lock.

A fencing token prevents this: each lock acquisition increments a monotonic counter, and the protected resource rejects operations with a token older than the last seen.

The acquire + INCR must be **atomic** - otherwise you can acquire the lock but fail the INCR (partition, timeout), or burn a token without getting the lock, and the downstream will see out-of-order or missing tokens.

**Atomic acquire + token, single round-trip (Lua)**:

```lua
-- KEYS[1] = lock key, KEYS[2] = token counter key
-- ARGV[1] = random value, ARGV[2] = TTL ms
if server.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then
    return server.call('INCR', KEYS[2])
else
    return nil  -- did not acquire; do not bump token
end
```

Usage (result is the fencing token, or `nil` if the lock was already held):
```
EVAL "..." 2 lock:resource lock:resource:fencing_token <random_value> 30000
```

When writing to the protected resource, pass the token. The resource server verifies `token >= last_seen_token` before applying the operation.

Fencing requires the downstream resource (database, API) to support token validation. Not all systems can do this.

Martin Kleppmann's analysis ("How to do distributed locking") argues fencing tokens are the only way to achieve strong safety with distributed locks. The antirez counterpoint defends Redlock's design assumptions. Both are required reading for production implementations.

---

## Lock Anti-Patterns

| Anti-Pattern | Risk | Fix |
|-------------|------|-----|
| Lock without TTL | Dead client holds lock forever | Always set PX or EX |
| Fixed lock value | Any client can release any lock | Use random UUID per acquisition |
| DEL without value check | Wrong client releases the lock | Use DELIFEQ (9.0+) or Lua script |
| Lock TTL shorter than task | Lock expires mid-task, another client enters | Use auto-renewal or generous TTL |
| Sleeping in a retry loop | Thundering herd on lock release | Exponential backoff + random jitter |
| Lock on replica reads | Replicas can serve stale data | Lock on the primary only |

---

## Retry Strategy

When lock acquisition fails, retry with exponential backoff and jitter:

```javascript
async function acquireWithRetry(redis, resource, maxRetries = 5) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    const value = await acquireLock(redis, resource);
    if (value) return value;

    // Exponential backoff with jitter
    const delay = Math.min(100 * Math.pow(2, attempt), 5000);
    const jitter = Math.random() * delay * 0.5;
    await sleep(delay + jitter);
  }
  return null; // Failed to acquire
}
```

---

