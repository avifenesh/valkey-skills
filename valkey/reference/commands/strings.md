# String Commands

Use when storing simple values, counters, cached objects, flags, or serialized data. Strings are Valkey's most fundamental data type - binary-safe byte sequences up to 512 MB.

---

## Basic Read/Write

### GET

```
GET key
```

Returns the string value stored at `key`, or nil if the key does not exist. Returns an error if the value is not a string.

**Complexity**: O(1)

```
SET user:1000:name "Alice"
GET user:1000:name
-- "Alice"

GET nonexistent
-- (nil)
```

### SET

```
SET key value [NX | XX | IFEQ comparison] [GET] [EX seconds | PX milliseconds | EXAT unix-seconds | PXAT unix-ms | KEEPTTL]
```

Sets `key` to hold `value`. Overwrites any existing value and type. Creates the key if it does not exist.

**Complexity**: O(1)

**Options**:

| Option | Effect |
|--------|--------|
| `EX seconds` | Set expiration in seconds |
| `PX milliseconds` | Set expiration in milliseconds |
| `EXAT unix-seconds` | Set expiration as Unix timestamp (seconds) |
| `PXAT unix-ms` | Set expiration as Unix timestamp (milliseconds) |
| `KEEPTTL` | Retain the existing TTL (do not reset it) |
| `NX` | Only set if key does not exist |
| `XX` | Only set if key already exists |
| `IFEQ value` | Only set if current value equals `value` (Valkey 8.1+) |
| `GET` | Return the old value before overwriting |

```
-- Basic set with 1-hour TTL
SET cache:product:42 '{"name":"Widget"}' EX 3600

-- Set only if key does not exist (distributed lock acquire)
SET lock:checkout "owner:txn:8832" NX PX 30000

-- Conditional update: only set if current value matches (Valkey 8.1+)
SET config:version "v2" IFEQ "v1"
-- OK if current value was "v1", nil otherwise

-- Atomic swap: get old value while setting new
SET counter "0" GET
-- Returns previous value (or nil if key was new)
```

**Valkey-specific**: The `IFEQ` option (since 8.1.0) enables atomic compare-and-swap without Lua scripts. This eliminates the GET-compare-SET race condition pattern.

### SETNX

```
SETNX key value
```

Sets `key` to `value` only if `key` does not already exist. Returns 1 if set, 0 if not. Equivalent to `SET key value NX` but without expiration options.

**Complexity**: O(1)

```
SETNX mykey "hello"    -- 1 (set)
SETNX mykey "world"    -- 0 (not set, key exists)
GET mykey              -- "hello"
```

Prefer `SET key value NX EX seconds` over SETNX when you need a TTL (common for locks).

### SETEX / PSETEX

```
SETEX key seconds value
PSETEX key milliseconds value
```

Atomic set-with-TTL. Equivalent to SET + EXPIRE in one command. SETEX uses seconds, PSETEX uses milliseconds.

**Complexity**: O(1)

```
SETEX session:abc 1800 '{"user":1000}'    -- expires in 30 minutes
PSETEX temp:data 500 "brief"               -- expires in 500ms
```

These are older forms. Prefer `SET key value EX seconds` in new code.

---

## Bulk Operations

### MGET

```
MGET key [key ...]
```

Returns values for all specified keys. For keys that do not exist or hold non-string values, nil is returned in that position.

**Complexity**: O(N) where N is the number of keys

```
SET name "Alice"
SET age "30"
MGET name age missing
-- 1) "Alice"
-- 2) "30"
-- 3) (nil)
```

### MSET

```
MSET key value [key value ...]
```

Sets multiple keys to their values atomically. Never fails - always returns OK. Replaces existing values.

**Complexity**: O(N) where N is the number of keys

```
MSET user:1:name "Alice" user:1:email "alice@example.com" user:1:role "admin"
```

**Cluster note**: All keys must hash to the same slot, or use hash tags: `MSET {user:1}:name "Alice" {user:1}:email "alice@example.com"`.

### MSETNX

```
MSETNX key value [key value ...]
```

Sets multiple keys atomically, but only if none of the keys exist. All-or-nothing: if any key exists, no key is set. Returns 1 if all keys were set, 0 if none were set.

**Complexity**: O(N)

```
MSETNX key1 "v1" key2 "v2"    -- 1 (both set)
MSETNX key2 "v3" key3 "v4"    -- 0 (key2 exists, neither set)
```

---

## Counters

### INCR / DECR

```
INCR key
DECR key
```

Atomically increment or decrement the integer stored at `key` by 1. If the key does not exist, it is initialized to 0 first. Returns the new value. Errors if the value is not an integer.

**Complexity**: O(1)

```
SET visits 100
INCR visits      -- 101
INCR visits      -- 102
DECR visits      -- 101

-- Auto-initialize
INCR new:counter -- 1
```

### INCRBY / DECRBY

```
INCRBY key increment
DECRBY key decrement
```

Atomically increment or decrement by a specified integer amount.

**Complexity**: O(1)

```
SET balance 1000
INCRBY balance 250     -- 1250
DECRBY balance 100     -- 1150
```

### INCRBYFLOAT

```
INCRBYFLOAT key increment
```

Atomically increment by a floating-point number. The value and increment can be exponential notation. There is no DECRBYFLOAT - use a negative increment.

**Complexity**: O(1)

```
SET temperature 36.5
INCRBYFLOAT temperature 0.3     -- "36.8"
INCRBYFLOAT temperature -1.0    -- "35.8"
```

---

## String Manipulation

### APPEND

```
APPEND key value
```

Appends `value` to the end of the string at `key`. Creates the key if it does not exist. Returns the length of the string after the append.

**Complexity**: O(1) amortized

```
APPEND log "2024-01-01 event1\n"    -- 19
APPEND log "2024-01-02 event2\n"    -- 38
```

### STRLEN

```
STRLEN key
```

Returns the length of the string at `key`. Returns 0 if the key does not exist.

**Complexity**: O(1)

```
SET greeting "hello"
STRLEN greeting    -- 5
STRLEN missing     -- 0
```

### GETRANGE

```
GETRANGE key start end
```

Returns the substring between positions `start` and `end` (inclusive, zero-based). Negative offsets count from the end.

**Complexity**: O(N) where N is the length of the returned string

```
SET message "Hello, World!"
GETRANGE message 0 4       -- "Hello"
GETRANGE message -6 -1     -- "World!"
```

### SETRANGE

```
SETRANGE key offset value
```

Overwrites part of the string at `key` starting at `offset`. Pads with zero-bytes if the offset exceeds the current length. Returns the new string length.

**Complexity**: O(1) when not extending the string

```
SET greeting "Hello World"
SETRANGE greeting 6 "Valkey"    -- 12
GET greeting                     -- "Hello Valkey"
```

---

## Atomic Get-and-Modify

### GETDEL

```
GETDEL key
```

Returns the value at `key` and deletes the key atomically. Returns nil if the key does not exist. Available since 6.2.0.

**Complexity**: O(1)

```
SET one-time-token "abc123"
GETDEL one-time-token    -- "abc123"
GET one-time-token        -- (nil)
```

Use for one-time tokens, claim-once vouchers, or any value that should be consumed exactly once.

### GETEX

```
GETEX key [EX seconds | PX milliseconds | EXAT unix-seconds | PXAT unix-ms | PERSIST]
```

Returns the value at `key` and optionally sets or removes its expiration. Available since 6.2.0.

**Complexity**: O(1)

```
SET session:abc "data" EX 1800
GETEX session:abc EX 3600    -- "data" (TTL refreshed to 1 hour)
GETEX session:abc PERSIST    -- "data" (TTL removed, key persists forever)
```

Use for session access patterns where reading should refresh the timeout.

---

## Practical Patterns

**Cache-aside with TTL**:
```
-- Read through cache
value = GET cache:user:42
if value is nil:
    value = fetch_from_database(42)
    SET cache:user:42 value EX 3600
```

**Distributed counter**:
```
-- Page view counter (auto-creates, atomic)
INCR pageviews:2024-03-29:/products
```

**Rate limit token**:
```
key = "ratelimit:" + user_id + ":" + current_minute
count = INCR key
if count == 1: EXPIRE key 60
if count > 100: reject
```

**Compare-and-swap (Valkey 8.1+)**:
```
-- Update config only if unchanged since last read
old = GET config:feature-flags
-- ... compute new value ...
SET config:feature-flags new_value IFEQ old
```

---

## See Also

- [Hash Commands](hashes.md) - alternative modeling with multiple fields in a single key
- [Caching Patterns](../patterns/caching.md) - cache-aside with SET/GET and TTL
- [Lock Patterns](../patterns/locks.md) - distributed locks using SET NX PX
- [Rate Limiting Patterns](../patterns/rate-limiting.md) - INCR-based rate limiters
- [Counter Patterns](../patterns/counters.md) - atomic counting with INCR/INCRBY
- [Session Patterns](../patterns/sessions.md) - session storage with string values
- [Conditional Operations](../valkey-features/conditional-ops.md) - SET IFEQ and DELIFEQ details
- [Key Best Practices](../best-practices/keys.md) - key naming conventions
- [Memory Best Practices](../best-practices/memory.md) - string encoding rules (int, embstr, raw)
- [Performance Best Practices](../best-practices/performance.md) - pipelining for bulk GET/SET operations
- [Anti-Patterns](../anti-patterns/quick-reference.md) - storing large serialized objects without compression
