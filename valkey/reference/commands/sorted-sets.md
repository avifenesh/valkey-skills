# Sorted Set Commands

Use when you need ordered collections ranked by score - leaderboards, priority queues, time-series indexes, rate limiters, range queries, or any ranking system. Members are unique, and each has a floating-point score that determines ordering.

---

## Add and Update

### ZADD

```
ZADD key [NX | XX] [GT | LT] [CH] [INCR] score member [score member ...]
```

Adds members with scores to the sorted set. Creates the key if it does not exist. Returns the number of new members added (unless CH is specified).

**Options**:

| Option | Effect |
|--------|--------|
| `NX` | Only add new members (do not update existing) |
| `XX` | Only update existing members (do not add new) |
| `GT` | Only update if new score is greater than current |
| `LT` | Only update if new score is less than current |
| `CH` | Return count of members changed (added + updated) instead of just added |
| `INCR` | Act like ZINCRBY - increment score and return new score |

**Complexity**: O(log N) per member

```
ZADD leaderboard 100 "alice" 200 "bob" 150 "charlie"    -- 3

-- Update only if new score is higher
ZADD leaderboard GT CH 180 "alice" 50 "bob"
-- 1 (only alice updated, bob's 50 < 200)

-- Add only new members
ZADD leaderboard NX 300 "diana" 999 "alice"
-- 1 (diana added, alice skipped because NX)
```

### ZINCRBY

```
ZINCRBY key increment member
```

Atomically increments the score of `member` by `increment`. Creates the member with `increment` as its score if it does not exist. Returns the new score.

**Complexity**: O(log N)

```
ZINCRBY leaderboard 50 "alice"    -- "230"
ZINCRBY leaderboard -10 "bob"     -- "190"
```

---

## Retrieval by Rank

### ZRANGE

```
ZRANGE key min max [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]
```

The unified range command (since 6.2). Default behavior returns members by index (rank). With BYSCORE or BYLEX, queries by score or lexicographic order.

**Complexity**: O(log N + M) where M is the number of elements returned

**By index (default)**:
```
ZADD scores 10 "a" 20 "b" 30 "c" 40 "d" 50 "e"

-- First 3 (lowest scores)
ZRANGE scores 0 2 WITHSCORES
-- "a" 10, "b" 20, "c" 30

-- Last 3 (highest scores, reversed)
ZRANGE scores 0 2 REV WITHSCORES
-- "e" 50, "d" 40, "c" 30
```

**By score (BYSCORE)**:
```
-- Members with scores between 20 and 40
ZRANGE scores 20 40 BYSCORE WITHSCORES
-- "b" 20, "c" 30, "d" 40

-- Exclusive bounds with ( prefix
ZRANGE scores (20 40 BYSCORE
-- "c" 30, "d" 40

-- With pagination
ZRANGE scores 0 +inf BYSCORE LIMIT 2 3 WITHSCORES
-- Skip 2, return 3

-- Unbounded ranges: -inf and +inf
ZRANGE scores -inf +inf BYSCORE
```

**By lex (BYLEX)** - when all members have the same score:
```
ZADD names 0 "alice" 0 "bob" 0 "charlie" 0 "diana"
ZRANGE names [b [d BYLEX
-- "bob", "charlie", "diana"

-- Lex bounds: [ is inclusive, ( is exclusive, + and - are max/min
ZRANGE names [b (d BYLEX
-- "bob", "charlie"
```

### ZRANGEBYSCORE (legacy)

```
ZRANGEBYSCORE key min max [WITHSCORES] [LIMIT offset count]
```

Returns members with scores between `min` and `max`. Superseded by `ZRANGE ... BYSCORE` but still supported.

### ZRANGEBYLEX (legacy)

```
ZRANGEBYLEX key min max [LIMIT offset count]
```

Returns members in lexicographic range. Superseded by `ZRANGE ... BYLEX`.

---

## Score and Rank Lookup

### ZSCORE

```
ZSCORE key member
```

Returns the score of `member`. Returns nil if the member or key does not exist.

**Complexity**: O(1)

```
ZSCORE leaderboard "alice"    -- "230"
```

### ZMSCORE

```
ZMSCORE key member [member ...]
```

Returns scores for multiple members. Returns nil for non-existent members.

**Complexity**: O(N) where N is the number of members

```
ZMSCORE leaderboard "alice" "unknown" "bob"
-- 1) "230"
-- 2) (nil)
-- 3) "190"
```

### ZRANK

```
ZRANK key member [WITHSCORE]
```

Returns the rank of `member` (0-based, lowest score = rank 0). Returns nil if the member does not exist. The optional WITHSCORE flag also returns the score.

**Complexity**: O(log N)

```
ZRANK leaderboard "alice"              -- 2
ZRANK leaderboard "alice" WITHSCORE    -- 1) 2 2) "230"
```

### ZREVRANK

```
ZREVRANK key member [WITHSCORE]
```

Returns the reverse rank (0-based, highest score = rank 0). Same options as ZRANK.

**Complexity**: O(log N)

```
ZREVRANK leaderboard "alice"    -- 1
```

---

## Counting

### ZCARD

```
ZCARD key
```

Returns the number of members in the sorted set.

**Complexity**: O(1)

```
ZCARD leaderboard    -- 4
```

### ZCOUNT

```
ZCOUNT key min max
```

Returns the count of members with scores between `min` and `max`. Supports `(` for exclusive, `-inf` and `+inf` for unbounded.

**Complexity**: O(log N)

```
ZCOUNT leaderboard 100 300      -- 3
ZCOUNT leaderboard -inf +inf    -- 4
ZCOUNT leaderboard (100 200     -- 1 (exclusive 100)
```

### ZLEXCOUNT

```
ZLEXCOUNT key min max
```

Returns the count of members in the lexicographic range. All members must have the same score.

**Complexity**: O(log N)

```
ZLEXCOUNT names [a [d    -- 3
```

---

## Removal

### ZREM

```
ZREM key member [member ...]
```

Removes one or more members. Returns the number of members removed.

**Complexity**: O(M * log N)

```
ZREM leaderboard "alice" "unknown"    -- 1
```

### ZPOPMIN / ZPOPMAX

```
ZPOPMIN key [count]
ZPOPMAX key [count]
```

Removes and returns up to `count` members with the lowest (ZPOPMIN) or highest (ZPOPMAX) scores.

**Complexity**: O(log N * M)

```
ZPOPMIN leaderboard 2
-- 1) "charlie" 2) "150"
-- 3) "bob"     4) "190"

ZPOPMAX leaderboard 1
-- 1) "diana" 2) "300"
```

### BZPOPMIN / BZPOPMAX

```
BZPOPMIN key [key ...] timeout
BZPOPMAX key [key ...] timeout
```

Blocking variants. Wait for an element to be available or timeout expires. Returns a three-element array: key, member, score.

**Complexity**: O(log N)

```
BZPOPMIN priority:queue 30
-- 1) "priority:queue"
-- 2) "task_xyz"
-- 3) "1"
```

---

## Multi-Key Operations

### ZUNIONSTORE

```
ZUNIONSTORE destination numkeys key [key ...] [WEIGHTS weight ...] [AGGREGATE SUM | MIN | MAX]
```

Computes the union of multiple sorted sets and stores the result. Scores are combined using the AGGREGATE function (default: SUM). WEIGHTS multiplies scores before aggregation. Returns the size of the resulting set.

**Complexity**: O(N*log N) where N is the total elements across all sets

```
ZADD quiz1 80 "alice" 90 "bob"
ZADD quiz2 70 "alice" 95 "bob" 85 "charlie"

ZUNIONSTORE total 2 quiz1 quiz2
-- 3 (alice=150, bob=185, charlie=85)

ZUNIONSTORE weighted 2 quiz1 quiz2 WEIGHTS 0.4 0.6
-- 3 (alice=74, bob=93, charlie=51)
```

### ZINTERSTORE

```
ZINTERSTORE destination numkeys key [key ...] [WEIGHTS weight ...] [AGGREGATE SUM | MIN | MAX]
```

Computes the intersection - only members present in all sets. Stores result and returns its size.

**Complexity**: O(N*K*log N)

```
ZINTERSTORE common 2 quiz1 quiz2
-- 2 (alice=150, bob=185)
```

### ZDIFFSTORE

```
ZDIFFSTORE destination numkeys key [key ...]
```

Stores members in the first set but not in any subsequent set. Returns the size of the result.

### ZINTERCARD

```
ZINTERCARD numkeys key [key ...] [LIMIT limit]
```

Returns the cardinality of the intersection without storing it. LIMIT stops counting early. Available since 7.0.

**Complexity**: O(N*K) where N is the size of the smallest set and K is the number of sets

```
ZINTERCARD 2 quiz1 quiz2           -- 2
ZINTERCARD 2 quiz1 quiz2 LIMIT 1   -- 1
```

### ZRANGESTORE

```
ZRANGESTORE destination source min max [BYSCORE | BYLEX] [REV] [LIMIT offset count]
```

Stores a range of members from `source` into `destination`. Returns the number of members stored.

**Complexity**: O(log N + M)

```
ZRANGESTORE top3 leaderboard 0 2 REV
-- 3
```

---

## Range Removal

### ZREMRANGEBYSCORE

```
ZREMRANGEBYSCORE key min max
```

Removes all members with scores between `min` and `max` (inclusive). Supports `(` for exclusive bounds and `-inf`/`+inf` for unbounded.

**Complexity**: O(log N + M) where M is the number of elements removed

```
ZREMRANGEBYSCORE leaderboard 0 100    -- removes members with scores 0-100
ZREMRANGEBYSCORE leaderboard -inf (50 -- removes members with scores below 50
```

### ZREMRANGEBYRANK

```
ZREMRANGEBYRANK key start stop
```

Removes all members with rank between `start` and `stop` (inclusive, zero-based). Negative indexes count from the end.

**Complexity**: O(log N + M)

```
ZREMRANGEBYRANK leaderboard 0 1    -- removes the 2 lowest-scored members
```

### ZREMRANGEBYLEX

```
ZREMRANGEBYLEX key min max
```

Removes all members in the lexicographic range. All members must have the same score. Uses `[` for inclusive and `(` for exclusive bounds, `-` and `+` for min/max.

**Complexity**: O(log N + M)

```
ZREMRANGEBYLEX names "[a" "[c"    -- removes members from "a" through "c"
```

---

## Non-Store Set Operations (since 6.2.0)

### ZDIFF

```
ZDIFF numkeys key [key ...] [WITHSCORES]
```

Returns members in the first sorted set that are not in any subsequent set. Like ZDIFFSTORE but returns the result directly without storing it.

**Complexity**: O(L + (N-K) * log N) where L is the total elements across all sets

```
ZDIFF 2 quiz1 quiz2 WITHSCORES
-- Members in quiz1 but not in quiz2, with their scores
```

### ZUNION

```
ZUNION numkeys key [key ...] [WEIGHTS weight ...] [AGGREGATE SUM | MIN | MAX] [WITHSCORES]
```

Returns the union of multiple sorted sets. Like ZUNIONSTORE but returns the result directly without storing it.

**Complexity**: O(N*log N) where N is the total elements across all sets

```
ZUNION 2 quiz1 quiz2 WITHSCORES
-- All members from both sets with aggregated scores
```

### ZINTER

```
ZINTER numkeys key [key ...] [WEIGHTS weight ...] [AGGREGATE SUM | MIN | MAX] [WITHSCORES]
```

Returns the intersection of multiple sorted sets. Like ZINTERSTORE but returns the result directly without storing it.

**Complexity**: O(N*K*log N) where N is the smallest set

```
ZINTER 2 quiz1 quiz2 WITHSCORES
-- Members present in both sets with aggregated scores
```

---

## Multi-Pop

### ZMPOP

```
ZMPOP numkeys key [key ...] MIN | MAX [COUNT count]
```

Pops members with the lowest (MIN) or highest (MAX) scores from the first non-empty sorted set. Available since 7.0.

**Complexity**: O(K) + O(M*log N)

```
ZMPOP 1 leaderboard MIN COUNT 2
-- 1) "leaderboard"
-- 2) 1) 1) "charlie" 2) "150"
--    2) 1) "bob"     2) "190"
```

### BZMPOP

```
BZMPOP timeout numkeys key [key ...] MIN | MAX [COUNT count]
```

Blocking variant of ZMPOP. Available since 7.0.

---

## Random and Scan

### ZRANDMEMBER

```
ZRANDMEMBER key [count [WITHSCORES]]
```

Returns random members. Positive count returns distinct members, negative count may return duplicates.

**Complexity**: O(N)

```
ZRANDMEMBER leaderboard 2 WITHSCORES
```

### ZSCAN

```
ZSCAN key cursor [MATCH pattern] [COUNT hint] [NOSCORES]
```

Incrementally iterates over members and scores. Returns cursor and member-score pairs.

**Complexity**: O(1) per call

```
ZSCAN leaderboard 0 MATCH "player:*" COUNT 100
```

---

## Practical Patterns

**Leaderboard**:
```
ZADD leaderboard 1500 "player:alice"
ZINCRBY leaderboard 100 "player:alice"
ZRANGE leaderboard 0 9 REV WITHSCORES     -- top 10
ZREVRANK leaderboard "player:alice"        -- player's rank
```

**Priority queue**:
```
ZADD tasks 1 "critical:task1"
ZADD tasks 5 "low:task2"
ZADD tasks 3 "medium:task3"
BZPOPMIN tasks 30    -- gets "critical:task1" first
```

**Time-series index**:
```
ZADD events:user:1000 1711670400 "event:1"
ZADD events:user:1000 1711674000 "event:2"
ZRANGE events:user:1000 1711670000 1711675000 BYSCORE
```

**Sliding window rate limiter**:
```
-- Add request with timestamp as score
ZADD requests:user:42 1711670400.123 "req:uuid1"
-- Remove old entries
ZREMRANGEBYSCORE requests:user:42 0 (current_time - window)
-- Count requests in window
ZCARD requests:user:42
```

---

## See Also

- [Set Commands](sets.md) - when members do not need scores or ordering
- [Specialized Data Types](specialized.md) - geospatial indexes are stored as sorted sets internally
- [Leaderboard Patterns](../patterns/leaderboards.md) - real-time ranking with sorted sets
- [Rate Limiting Patterns](../patterns/rate-limiting.md) - sliding window log using sorted sets
- [Queue Patterns](../patterns/queues.md) - priority queues with ZPOPMIN
- [Counter Patterns](../patterns/counters.md) - time-series counting with sorted sets
- [Polygon Geospatial Queries](../valkey-features/geospatial.md) - GEOSEARCH BYPOLYGON on geo sorted sets (Valkey 9.0+)
- [Performance Summary](../valkey-features/performance-summary.md) - ZRANK optimization (45% faster in 8.1+)
- [Cluster Best Practices](../best-practices/cluster.md) - hash tags for multi-key sorted set operations (ZUNIONSTORE, ZINTERSTORE)
- [Memory Best Practices](../best-practices/memory.md) - sorted set encoding thresholds
- [Key Best Practices](../best-practices/keys.md) - key naming for leaderboards and indexes
