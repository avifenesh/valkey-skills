# Distributed Lock Patterns

Use when implementing mutual exclusion across distributed services, preventing duplicate processing, or coordinating access to shared resources.

---

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

Only release if you still hold the lock. Without this check, a slow client could release a lock that another client has since acquired.

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

Long-running tasks may need to extend the lock before it expires. Only the lock owner should be able to extend.

**Valkey 8.1+ (SET IFEQ)**:
```
# Extend TTL only if we still hold the lock
SET lock:resource <my_random_value> IFEQ <my_random_value> PX 30000
# IFEQ = only if key exists AND current value matches
```

**Pre-8.1 (Lua script)**:
```lua
if server.call('GET', KEYS[1]) == ARGV[1] then
    return server.call('PEXPIRE', KEYS[1], ARGV[2])
else
    return 0
end
```

### Auto-Renewal Pattern

For long-running tasks, use a background timer to renew the lock at intervals shorter than the TTL:

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

For scenarios where a single Valkey instance failure could violate mutual exclusion, Redlock acquires locks on multiple independent instances.

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

- A single Valkey instance with Sentinel failover is sufficient for most use cases
- The lock protects an idempotent operation (duplicate execution is harmless)
- Performance matters more than strict mutual exclusion

### Crash Recovery Considerations

- **Without persistence**: A restarted node may allow duplicate lock acquisition. Mitigate by keeping crashed nodes unavailable for at least max-TTL duration before rejoining.
- **With AOF (fsync always)**: Safe but impacts performance.
- **With AOF (fsync every second)**: May lose the last second of data after a power outage.
- **Delayed restart**: Safest option without persistence - keep the node down for at least max-TTL after a crash.

### Retry Strategy

On failure, retry with a random delay to desynchronize competing clients. Use multiplexing to contact all N instances simultaneously rather than sequentially.

### Lock Extension

For long-running operations, extend the lock by sending a Lua script to all instances that extends the TTL if the key exists with the correct random value. Only consider the lock extended if a majority succeeded within the validity time. Limit reacquisition attempts to preserve liveness.

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

Locks can fail silently: a client holds a lock, pauses (GC, network delay), the lock expires, another client acquires it, and the original client resumes thinking it still has the lock. The lock alone does not guarantee a process still holds it when performing work.

A fencing token prevents this. Each lock acquisition increments a monotonic counter. The protected resource rejects operations with a token older than the last seen.

```
# Acquire lock and get fencing token
SET lock:resource <random_value> NX PX 30000
token = INCR lock:resource:fencing_token

# When writing to the protected resource, pass the token
# The resource server verifies: token >= last_seen_token
```

**Note**: Fencing requires the downstream resource (database, API) to support token validation. Not all systems can do this.

**Essential reading**: Martin Kleppmann's analysis ("How to do distributed locking") argues that fencing tokens are the only way to achieve strong safety guarantees with distributed locks. The antirez counterpoint defends Redlock's design assumptions. Both are required reading for production distributed lock implementations.

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

## See Also

- [String Commands](../basics/data-types.md) - SET NX PX for lock acquisition
- [Conditional Operations](../valkey-features/conditional-ops.md) - DELIFEQ for safe lock release, SET IFEQ for lock extension
- [Scripting and Functions](../basics/server-and-scripting.md) - Lua-based lock release (pre-9.0)
- [Counter Patterns](counters.md) - INCR for fencing tokens, idempotency keys as lock alternatives
- [Rate Limiting Patterns](rate-limiting.md) - related concurrency control patterns
- [Queue Patterns](queues.md) - reliable processing with acknowledgment (alternative to locking)
- [Caching Patterns](caching.md) - lock-based cache stampede prevention
- [Session Patterns](sessions.md) - session rotation requiring atomic operations
- [Performance Best Practices](../best-practices/performance.md) - pipelining and connection pooling
- [High Availability Best Practices](../best-practices/high-availability.md) - replication safety concerns for Redlock
- [Key Best Practices](../best-practices/keys.md) - key naming and TTL strategies for lock keys
- [Persistence Best Practices](../best-practices/persistence.md) - lock safety during crash recovery with AOF
- [Security: Auth and ACL](../security/auth-and-acl.md) - ACL restrictions for lock key namespaces
- Clients Overview (see valkey-glide skill) - connection patterns for lock acquisition and Redlock libraries
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - lock without TTL, DEL without value check
