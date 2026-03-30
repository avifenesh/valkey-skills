# Hash Commands

Use when storing objects with named fields - user profiles, session data, configuration maps, or any entity with multiple attributes. Hashes are memory-efficient for small field counts due to compact listpack encoding.

---

## Basic Operations

### HSET

```
HSET key field value [field value ...]
```

Sets one or more field-value pairs in the hash at `key`. Creates the key if it does not exist. Overwrites existing fields. Returns the number of new fields added (not updated).

**Complexity**: O(N) where N is the number of field-value pairs

```
HSET user:1000 name "Alice" email "alice@example.com" role "admin"
-- 3

HSET user:1000 role "moderator"
-- 0 (field updated, not new)
```

### HGET

```
HGET key field
```

Returns the value of `field` in the hash at `key`. Returns nil if the field or key does not exist.

**Complexity**: O(1)

```
HGET user:1000 name      -- "Alice"
HGET user:1000 missing   -- (nil)
```

### HMGET

```
HMGET key field [field ...]
```

Returns values for multiple fields. Returns nil in the position of any field that does not exist.

**Complexity**: O(N) where N is the number of fields

```
HMGET user:1000 name email phone
-- 1) "Alice"
-- 2) "alice@example.com"
-- 3) (nil)
```

Prefer HMGET over multiple HGET calls to reduce round-trips.

### HGETALL

```
HGETALL key
```

Returns all fields and values in the hash. Returns an empty list if the key does not exist.

**Complexity**: O(N) where N is the hash size

```
HGETALL user:1000
-- 1) "name"
-- 2) "Alice"
-- 3) "email"
-- 4) "alice@example.com"
-- 5) "role"
-- 6) "moderator"
```

**Warning**: Blocks the server for large hashes. Use HSCAN for hashes with thousands of fields.

### HSETNX

```
HSETNX key field value
```

Sets `field` to `value` only if `field` does not already exist in the hash. Returns 1 if set, 0 if not.

**Complexity**: O(1)

```
HSETNX user:1000 name "Bob"    -- 0 (field exists)
HSETNX user:1000 bio "New"     -- 1 (field created)
```

---

## Field Inspection

### HEXISTS

```
HEXISTS key field
```

Returns 1 if `field` exists in the hash, 0 otherwise.

**Complexity**: O(1)

```
HEXISTS user:1000 email    -- 1
HEXISTS user:1000 phone    -- 0
```

### HLEN

```
HLEN key
```

Returns the number of fields in the hash. Returns 0 if key does not exist.

**Complexity**: O(1)

```
HLEN user:1000    -- 4
```

### HKEYS

```
HKEYS key
```

Returns all field names in the hash.

**Complexity**: O(N)

```
HKEYS user:1000
-- 1) "name"
-- 2) "email"
-- 3) "role"
-- 4) "bio"
```

### HVALS

```
HVALS key
```

Returns all values in the hash (without field names).

**Complexity**: O(N)

---

## Deletion

### HDEL

```
HDEL key field [field ...]
```

Removes one or more fields from the hash. Returns the number of fields actually removed.

**Complexity**: O(N) where N is the number of fields to remove

```
HDEL user:1000 bio phone    -- 1 (bio removed, phone didn't exist)
```

---

## Counters

### HINCRBY

```
HINCRBY key field increment
```

Atomically increments the integer value of `field` by `increment`. Creates the field with value 0 if it does not exist. Returns the new value.

**Complexity**: O(1)

```
HSET product:42 views 0
HINCRBY product:42 views 1      -- 1
HINCRBY product:42 views 5      -- 6
HINCRBY product:42 stock -1     -- -1 (auto-created at 0, decremented)
```

### HINCRBYFLOAT

```
HINCRBYFLOAT key field increment
```

Atomically increments the float value of `field`. Works the same as HINCRBY but for floating-point numbers.

**Complexity**: O(1)

```
HSET item:1 price 19.99
HINCRBYFLOAT item:1 price 0.50    -- "20.49"
HINCRBYFLOAT item:1 price -2.00   -- "18.49"
```

---

## Random and Scan

### HRANDFIELD

```
HRANDFIELD key [count [WITHVALUES]]
```

Returns one or more random fields from the hash. With positive `count`, returns up to `count` distinct fields. With negative `count`, may return duplicates (allows more results than fields exist).

**Complexity**: O(N) where N is the number of fields returned

```
HRANDFIELD user:1000                   -- "email" (random field)
HRANDFIELD user:1000 2                 -- 1) "name" 2) "role"
HRANDFIELD user:1000 2 WITHVALUES     -- 1) "name" 2) "Alice" 3) "role" 4) "admin"
```

### HSCAN

```
HSCAN key cursor [MATCH pattern] [COUNT hint] [NOVALUES]
```

Incrementally iterates over fields in the hash. Returns a cursor and a batch of field-value pairs. Continue calling with the returned cursor until it returns 0.

**Complexity**: O(1) per call, O(N) for full iteration

```
HSCAN user:1000 0 MATCH "e*" COUNT 10
-- 1) "0"             (cursor - 0 means iteration complete)
-- 2) 1) "email"
--    2) "alice@example.com"
```

Use HSCAN instead of HGETALL for large hashes.

---

## Hash Field Expiration (Valkey 9.0+)

These commands set TTLs on individual hash fields rather than the entire key. This is a Valkey-only feature.

### HEXPIRE

```
HEXPIRE key seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

Sets a TTL in seconds on one or more hash fields.

**Conditions**: NX (only if no TTL), XX (only if TTL exists), GT (only if new TTL is greater), LT (only if new TTL is less).

**Returns**: Array of integers per field: 1 = TTL set, 0 = condition not met, -2 = field does not exist, 2 = field deleted (0-second TTL).

```
HSET session:abc user_id 1000 csrf_token "xyz" auth_token "tok123"

-- CSRF token expires in 5 minutes
HEXPIRE session:abc 300 FIELDS 1 csrf_token
-- 1) 1

-- Auth token expires in 1 hour
HEXPIRE session:abc 3600 FIELDS 1 auth_token
-- 1) 1
```

### HEXPIREAT

```
HEXPIREAT key unix-time-seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

Sets field expiration as an absolute Unix timestamp in seconds.

### HPEXPIRE

```
HPEXPIRE key milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

Sets field TTL in milliseconds.

### HPEXPIREAT

```
HPEXPIREAT key unix-time-milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

Sets field expiration as an absolute Unix timestamp in milliseconds.

### HTTL

```
HTTL key FIELDS numfields field [field ...]
```

Returns the remaining TTL in seconds for each specified field. Returns -1 if the field has no TTL, -2 if the field does not exist.

```
HTTL session:abc FIELDS 2 csrf_token auth_token
-- 1) 287
-- 2) 3592
```

### HPTTL

```
HPTTL key FIELDS numfields field [field ...]
```

Returns the remaining TTL in milliseconds for each field.

### HEXPIRETIME

```
HEXPIRETIME key FIELDS numfields field [field ...]
```

Returns the absolute Unix expiration timestamp in seconds for each field. Returns -1 (no TTL) or -2 (field does not exist).

### HPEXPIRETIME

```
HPEXPIRETIME key FIELDS numfields field [field ...]
```

Returns the absolute Unix expiration timestamp in milliseconds.

### HPERSIST

```
HPERSIST key FIELDS numfields field [field ...]
```

Removes the TTL from specified fields, making them persist indefinitely. Returns 1 per field if TTL was removed, -1 if field had no TTL, -2 if field does not exist.

```
HPERSIST session:abc FIELDS 1 auth_token
-- 1) 1
```

### HSETEX (Valkey 9.0+)

```
HSETEX key [NX | XX] [FNX | FXX] [EX seconds | PX ms | EXAT ts | PXAT ts | KEEPTTL] FIELDS numfields field value [field value ...]
```

Sets one or more field-value pairs with optional field-level TTL in a single command. Combines HSET and HEXPIRE atomically.

**Key conditions**: NX (only if key does not exist), XX (only if key exists).
**Field conditions**: FNX (only set if none of the specified fields exist), FXX (only set if all specified fields already exist).
**TTL options**: EX (seconds), PX (milliseconds), EXAT (Unix timestamp seconds), PXAT (Unix timestamp ms), KEEPTTL (preserve existing field TTLs).

Returns `1` if all fields were set, `0` if a condition prevented setting.

```
-- Create session fields with 1-hour TTL
HSETEX session:abc EX 3600 FIELDS 2 auth_token "tok123" csrf_token "xyz"

-- Only set if fields do NOT exist (prevents overwriting)
HSETEX session:abc FNX EX 300 FIELDS 1 csrf_token "new_tok"
-- 0 (csrf_token already exists, FNX fails)

-- Only set if fields already exist (update-only semantics)
HSETEX session:abc FXX EX 300 FIELDS 1 csrf_token "new_tok"
-- 1 (csrf_token exists, FXX succeeds)

-- Update values without changing existing field TTLs
HSETEX session:abc FXX KEEPTTL FIELDS 1 auth_token "tok456"
```

**Gotcha**: Plain HSET on a field that has a TTL strips the expiration. Use HSETEX with KEEPTTL when updating volatile fields to preserve their TTL.

### HGETEX (Valkey 9.0+)

```
HGETEX key [EX seconds | PX ms | EXAT ts | PXAT ts | PERSIST] FIELDS numfields field [field ...]
```

Gets field values and optionally sets or removes their TTL atomically. Useful for "read and refresh timeout" patterns.

```
-- Read auth token and refresh its TTL to 1 hour
HGETEX session:abc EX 3600 FIELDS 1 auth_token
-- 1) "tok123"
```

### HGETDEL (Valkey 9.1+)

```
HGETDEL key FIELDS numfields field [field ...]
```

Returns field values and deletes those fields atomically. Returns nil for fields that do not exist. When the last field is deleted, the key itself is also deleted.

**Complexity**: O(N) where N is the number of fields

```
HGETDEL session:abc FIELDS 1 csrf_token
-- 1) "xyz"
-- (csrf_token field is now deleted)

HGETDEL session:abc FIELDS 1 csrf_token
-- 1) (nil)
-- (already deleted)
```

Use for claim-and-consume patterns where reading a field should also remove it - one-time tokens, temporary authorization grants, or dequeuing items from a hash.

---

## Practical Patterns

**User profile as hash**:
```
HSET user:1000 name "Alice" email "alice@example.com" plan "pro" created 1711670400
HMGET user:1000 name plan
```

**Session with per-field expiration (Valkey 9.0+)**:
```
HSETEX session:abc EX 1800 FIELDS 3 user_id "1000" role "admin" csrf_token "xyz"
HEXPIRE session:abc 300 FIELDS 1 csrf_token    -- CSRF expires faster
```

**Object counter fields**:
```
HINCRBY article:42 views 1
HINCRBY article:42 likes 1
HMGET article:42 views likes
```

**Memory-efficient small hashes**: Hashes with up to 512 fields and values under 64 bytes use compact listpack encoding, saving up to 10x memory versus separate string keys. Structure your data to stay under these thresholds when practical.

---

## See Also

- [String Commands](strings.md) - alternative modeling with separate keys per field
- [Session Patterns](../patterns/sessions.md) - session storage using hashes with per-field TTL
- [Counter Patterns](../patterns/counters.md) - HINCRBY-based object counters
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - per-field TTL details (Valkey 9.0+)
- [Conditional Operations](../valkey-features/conditional-ops.md) - HSETEX FNX/FXX for conditional field writes
- [Memory Best Practices](../best-practices/memory.md) - hash encoding thresholds and bucketing
- [Key Best Practices](../best-practices/keys.md) - key naming for hash keys
- [Performance Best Practices](../best-practices/performance.md) - HSCAN vs HGETALL for large hashes
- [Anti-Patterns](../anti-patterns/quick-reference.md) - HGETALL on large hashes, plain HSET stripping field TTLs
