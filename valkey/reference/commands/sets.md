# Set Commands

Use when you need unordered collections of unique strings - tags, membership tracking, deduplication, feature flags, social relationships, or computing intersections/unions/differences across collections.

---

## Add and Remove

### SADD

```
SADD key member [member ...]
```

Adds one or more members to the set at `key`. Creates the key if it does not exist. Ignores members that already exist. Returns the number of members actually added (not already present).

**Complexity**: O(N) where N is the number of members added

```
SADD tags:article:42 "valkey" "database" "performance"    -- 3
SADD tags:article:42 "valkey" "caching"                    -- 1 (only "caching" is new)
```

### SREM

```
SREM key member [member ...]
```

Removes one or more members from the set. Returns the number of members actually removed.

**Complexity**: O(N) where N is the number of members removed

```
SREM tags:article:42 "performance" "missing"    -- 1 (only "performance" existed)
```

### SPOP

```
SPOP key [count]
```

Removes and returns one or more random members from the set. Without `count`, returns a single member. With `count`, returns up to `count` members. Returns nil if the set is empty.

**Complexity**: O(N) where N is the number of members returned

```
SADD lottery "alice" "bob" "charlie" "diana"
SPOP lottery          -- "charlie" (random)
SPOP lottery 2        -- 1) "diana" 2) "alice" (random)
```

---

## Membership

### SISMEMBER

```
SISMEMBER key member
```

Returns 1 if `member` is in the set, 0 otherwise.

**Complexity**: O(1)

```
SADD admins "alice" "bob"
SISMEMBER admins "alice"     -- 1
SISMEMBER admins "charlie"   -- 0
```

### SMISMEMBER

```
SMISMEMBER key member [member ...]
```

Returns an array of 1/0 values indicating membership for each specified member. More efficient than multiple SISMEMBER calls.

**Complexity**: O(N) where N is the number of members checked

```
SMISMEMBER admins "alice" "charlie" "bob"
-- 1) 1
-- 2) 0
-- 3) 1
```

---

## Retrieval

### SMEMBERS

```
SMEMBERS key
```

Returns all members of the set. Returns an empty set if the key does not exist.

**Complexity**: O(N) where N is the set size

```
SADD colors "red" "green" "blue"
SMEMBERS colors
-- 1) "red"
-- 2) "green"
-- 3) "blue"
```

**Warning**: Blocks the server for large sets. Use SSCAN for sets with thousands of members.

### SRANDMEMBER

```
SRANDMEMBER key [count]
```

Returns one or more random members without removing them. Positive `count` returns up to `count` distinct members. Negative `count` may return duplicates.

**Complexity**: O(N) where N is the absolute value of count

```
SRANDMEMBER colors          -- "green" (random)
SRANDMEMBER colors 2        -- 1) "red" 2) "blue" (distinct)
SRANDMEMBER colors -5       -- 5 elements, may repeat
```

### SCARD

```
SCARD key
```

Returns the number of members in the set. Returns 0 if the key does not exist.

**Complexity**: O(1)

```
SCARD colors    -- 3
```

---

## Set Operations

### SDIFF

```
SDIFF key [key ...]
```

Returns members present in the first set but not in any subsequent sets.

**Complexity**: O(N) where N is the total number of members across all sets

```
SADD set1 "a" "b" "c"
SADD set2 "b" "c" "d"
SDIFF set1 set2        -- "a"
```

### SINTER

```
SINTER key [key ...]
```

Returns members present in all specified sets.

**Complexity**: O(N*M) worst case where N is the smallest set size and M is the number of sets

```
SADD set1 "a" "b" "c"
SADD set2 "b" "c" "d"
SINTER set1 set2       -- "b", "c"
```

### SUNION

```
SUNION key [key ...]
```

Returns all members present in any of the specified sets (deduplicated).

**Complexity**: O(N) where N is the total number of members across all sets

```
SUNION set1 set2       -- "a", "b", "c", "d"
```

### SINTERCARD

```
SINTERCARD numkeys key [key ...] [LIMIT limit]
```

Returns the cardinality (count) of the intersection without materializing it. The optional `LIMIT` stops counting early - useful when you only need to know if the intersection exceeds a threshold. Available since 7.0.

**Complexity**: O(N*M) worst case

```
SINTERCARD 2 set1 set2           -- 2
SINTERCARD 2 set1 set2 LIMIT 1   -- 1 (stopped early)
```

---

## Store Operations

### SDIFFSTORE

```
SDIFFSTORE destination key [key ...]
```

Computes the difference and stores the result in `destination`. Returns the size of the resulting set. Overwrites `destination` if it exists.

**Complexity**: O(N)

```
SDIFFSTORE result set1 set2
-- 1
SMEMBERS result    -- "a"
```

### SINTERSTORE

```
SINTERSTORE destination key [key ...]
```

Computes the intersection and stores the result. Returns the size of the resulting set.

**Complexity**: O(N*M)

```
SINTERSTORE common set1 set2
-- 2
```

### SUNIONSTORE

```
SUNIONSTORE destination key [key ...]
```

Computes the union and stores the result. Returns the size of the resulting set.

**Complexity**: O(N)

```
SUNIONSTORE all set1 set2
-- 4
```

---

## Scanning

### SSCAN

```
SSCAN key cursor [MATCH pattern] [COUNT hint]
```

Incrementally iterates over set members. Returns a cursor and a batch of members. Continue calling with the returned cursor until it returns 0. May return duplicates across calls - your application must deduplicate.

**Complexity**: O(1) per call, O(N) for full iteration

```
SSCAN myset 0 MATCH "user:*" COUNT 100
-- 1) "42"          (next cursor)
-- 2) 1) "user:100"
--    2) "user:200"
```

---

## Practical Patterns

**Tag system**:
```
-- Tag articles
SADD tags:article:1 "valkey" "database"
SADD tags:article:2 "valkey" "performance"

-- Articles tagged with both "valkey" AND "database"
-- (use tag-to-article reverse index)
SADD tag:valkey "article:1" "article:2"
SADD tag:database "article:1"
SINTER tag:valkey tag:database    -- "article:1"
```

**Online presence tracking**:
```
SADD online:users "user:100" "user:200" "user:300"
SREM online:users "user:200"
SCARD online:users             -- 2
SISMEMBER online:users "user:100"   -- 1
```

**Unique visitor counting**:
```
SADD visitors:2024-03-29 "ip:1.2.3.4"
SADD visitors:2024-03-29 "ip:5.6.7.8"
SADD visitors:2024-03-29 "ip:1.2.3.4"    -- 0 (duplicate)
SCARD visitors:2024-03-29                  -- 2
```

**Social graph - mutual friends**:
```
SADD friends:alice "bob" "charlie" "diana"
SADD friends:bob "alice" "charlie" "eve"
SINTER friends:alice friends:bob    -- "charlie"
```

**Feature flag rollout**:
```
SADD feature:dark-mode "user:100" "user:200" "user:300"
SISMEMBER feature:dark-mode "user:100"    -- 1 (enabled)
SISMEMBER feature:dark-mode "user:999"    -- 0 (not enabled)
```

**Deduplication**:
```
-- Process each event only once
SADD processed:events event_id
-- Returns 1 if new (process it), 0 if already seen (skip)
```

---

## See Also

- [Memory Best Practices](../best-practices/memory.md) - set encoding thresholds (listpack, intset, hashtable)
- [Key Best Practices](../best-practices/keys.md) - key naming for set-based tracking
- [Anti-Patterns](../anti-patterns/quick-reference.md) - SMEMBERS on huge sets
