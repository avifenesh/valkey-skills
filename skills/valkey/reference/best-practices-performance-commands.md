# Performance: Command Selection

Use when choosing between UNLINK and DEL, replacing KEYS with SCAN, or selecting the right iteration strategy for large data structures.

## Contents

- UNLINK vs DEL (line 13)
- SCAN vs KEYS (line 58)

---

## UNLINK vs DEL

`DEL` is synchronous by default - frees memory on the main thread. For large keys (hashes or sorted sets with millions of members), this blocks all clients for hundreds of milliseconds.

`UNLINK` removes the key reference in O(1) on the main thread and queues memory reclamation to a background thread.

```
# Always prefer UNLINK for large or unknown-size keys
UNLINK mykey

# DEL is fine for small keys, but UNLINK is never worse
DEL small_counter
```

**Valkey 8.0+ default behavior**: The config `lazyfree-lazy-user-del` defaults to `yes`, making `DEL` behave identically to `UNLINK`. However, explicitly using `UNLINK` is still recommended because:

1. It communicates intent clearly in your code
2. It protects against config changes - if someone sets `lazyfree-lazy-user-del no`, `UNLINK` calls remain non-blocking while `DEL` calls become blocking

DEL is acceptable for small keys (strings, hashes with a few fields). Overhead difference is negligible under a few hundred elements.

### Code Examples

**Node.js (ioredis)**:
```javascript
// Prefer UNLINK for cleanup operations
await redis.unlink('session:expired:abc123');

// Batch cleanup with pipeline
const pipeline = redis.pipeline();
expiredKeys.forEach(key => pipeline.unlink(key));
await pipeline.exec();
```

**Python (valkey-py)**:
```python
# Single key
await client.unlink('cache:user:1000')

# Multiple keys
await client.unlink('key1', 'key2', 'key3')
```

---

## SCAN vs KEYS

`KEYS pattern` blocks the server scanning the entire keyspace. Millions of keys = multi-second freeze. Never use in production.

`SCAN cursor [MATCH pattern] [COUNT hint]` iterates in small batches, allowing the server to process other commands between iterations.

```
# NEVER in production:
KEYS user:*

# ALWAYS use SCAN:
SCAN 0 MATCH user:* COUNT 100
# Returns: [next_cursor, [key1, key2, ...]]
# Continue with next_cursor until it returns 0
```

### SCAN Gotchas

- **Duplicates**: SCAN may return the same key in multiple iterations. Deduplicate in your application.
- **Empty pages**: SCAN may return zero results with a non-zero cursor. Keep iterating until cursor is 0.
- **COUNT is a hint**: The server may return more or fewer results than COUNT.
- **Consistency**: SCAN does not guarantee point-in-time snapshot. Keys added or removed during iteration may or may not appear.

### Data-Type Variants

| Command | Iterates Over |
|---------|---------------|
| `SCAN` | Top-level keyspace |
| `HSCAN key cursor` | Hash fields |
| `SSCAN key cursor` | Set members |
| `ZSCAN key cursor` | Sorted set members with scores |

### Code Examples

**Node.js (ioredis)**:
```javascript
async function scanAll(redis, pattern) {
  const results = [];
  let cursor = '0';
  do {
    const [nextCursor, keys] = await redis.scan(
      cursor, 'MATCH', pattern, 'COUNT', 100
    );
    cursor = nextCursor;
    results.push(...keys);
  } while (cursor !== '0');
  return [...new Set(results)]; // deduplicate
}
```

**Python (valkey-py)**:
```python
async def scan_all(client, pattern):
    results = set()
    cursor = 0
    while True:
        cursor, keys = await client.scan(cursor, match=pattern, count=100)
        results.update(keys)
        if cursor == 0:
            break
    return results
```

---
