# Cluster Hash Tags and Cross-Slot Errors

Use when designing key patterns for multi-key commands in Valkey Cluster, resolving CROSSSLOT errors, or co-locating related keys in the same hash slot.

## Contents

- Hash Tags for Multi-Key Commands (line 14)
- Cross-Slot Errors (line 78)

---

## Hash Tags for Multi-Key Commands

Valkey Cluster distributes keys across 16,384 hash slots via CRC16 hash. Multi-key commands (`MGET`, `MSET`, `SINTER`, `SUNION`, Lua scripts with multiple keys) only work when all keys are in the same slot.

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

Multi-key commands referencing keys in different slots return a `CROSSSLOT` error:

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
