# Leaderboard Patterns

Use when building real-time ranking systems, game leaderboards, top-N lists, or any feature that requires sorted scoring with efficient rank queries.

---

## Why Sorted Sets

Sorted sets are purpose-built for leaderboards. Every member has a numeric score, and the set is always maintained in sorted order. All ranking operations are O(log N) - no scanning, no sorting at query time.

| Operation | Command | Complexity |
|-----------|---------|------------|
| Add/update score | `ZADD` | O(log N) |
| Get rank (high to low) | `ZREVRANK` | O(log N) |
| Get top N | `ZREVRANGE` | O(log N + M) |
| Increment score | `ZINCRBY` | O(log N) |
| Get score | `ZSCORE` | O(1) |
| Count in score range | `ZCOUNT` | O(log N) |
| Remove member | `ZREM` | O(log N) |

---

## Basic Leaderboard

### Setup and Score Updates

```
# Add players with scores
ZADD leaderboard 1500 "player:alice"
ZADD leaderboard 2200 "player:bob"
ZADD leaderboard 1800 "player:charlie"

# Update score (ZADD overwrites existing score)
ZADD leaderboard 2500 "player:alice"

# Increment score atomically (preferred for live scoring)
ZINCRBY leaderboard 100 "player:alice"    # Alice scores 100 more points
```

### Querying Rankings

```
# Top 10 players (highest score first)
ZREVRANGE leaderboard 0 9 WITHSCORES
# Returns: ["player:alice", "2600", "player:bob", "2200", ...]

# Player's rank (0-indexed, highest score = rank 0)
ZREVRANK leaderboard "player:alice"
# Returns: 0

# Player's score
ZSCORE leaderboard "player:alice"
# Returns: "2600"

# Total players
ZCARD leaderboard
```

### Code Example

**Node.js**:
```javascript
class Leaderboard {
  constructor(redis, name) {
    this.redis = redis;
    this.key = `leaderboard:${name}`;
  }

  async addScore(playerId, score) {
    return this.redis.zincrby(this.key, score, playerId);
  }

  async getTop(count = 10) {
    const results = await this.redis.zrevrange(this.key, 0, count - 1, 'WITHSCORES');
    const entries = [];
    for (let i = 0; i < results.length; i += 2) {
      entries.push({ player: results[i], score: parseFloat(results[i + 1]) });
    }
    return entries;
  }

  async getRank(playerId) {
    const rank = await this.redis.zrevrank(this.key, playerId);
    return rank !== null ? rank + 1 : null; // 1-indexed for display
  }

  async getPlayerScore(playerId) {
    return this.redis.zscore(this.key, playerId);
  }
}
```

**Python**:
```python
class Leaderboard:
    def __init__(self, redis, name):
        self.redis = redis
        self.key = f"leaderboard:{name}"

    async def add_score(self, player_id: str, score: float):
        await self.redis.zincrby(self.key, score, player_id)

    async def get_top(self, count: int = 10):
        return await self.redis.zrevrange(
            self.key, 0, count - 1, withscores=True
        )

    async def get_rank(self, player_id: str) -> int | None:
        rank = await self.redis.zrevrank(self.key, player_id)
        return rank + 1 if rank is not None else None

    async def get_score(self, player_id: str) -> float | None:
        return await self.redis.zscore(self.key, player_id)
```

---

## Paginated Results

For leaderboards with thousands of players, use `ZREVRANGE` with offset and count:

```
# Page 1 (ranks 1-20)
ZREVRANGE leaderboard 0 19 WITHSCORES

# Page 2 (ranks 21-40)
ZREVRANGE leaderboard 20 39 WITHSCORES

# Page 3 (ranks 41-60)
ZREVRANGE leaderboard 40 59 WITHSCORES
```

### "Around Me" View

Show the player's rank plus neighbors above and below:

```python
async def get_around_player(self, player_id: str, context: int = 5):
    rank = await self.redis.zrevrank(self.key, player_id)
    if rank is None:
        return None
    start = max(0, rank - context)
    end = rank + context
    return await self.redis.zrevrange(self.key, start, end, withscores=True)
```

```
# Player at rank 50, with 5 above and 5 below
ZREVRANGE leaderboard 45 55 WITHSCORES
```

---

## Composite Scoring

When multiple factors determine ranking (e.g., score + time), encode them into a single score value.

### Score + Tiebreaker by Time

Higher score wins. Among equal scores, the earlier achievement wins (lower timestamp = higher priority).

```python
# Encode: score * 10^10 + (max_timestamp - actual_timestamp)
MAX_TS = 10_000_000_000  # far future epoch

def composite_score(points: int, timestamp: float) -> float:
    return points * 10_000_000_000 + (MAX_TS - int(timestamp))

# Player scores 500 points at time 1711670400
score = composite_score(500, 1711670400)
# ZADD leaderboard <score> "player:alice"
```

**Decoding**: Integer division by 10^10 gives points. Remainder gives time tiebreaker.

### Multi-Dimension Scoring

For complex scoring (wins, kills, deaths in a game), pack dimensions into a single float:

```
composite = wins * 1_000_000 + kills * 1_000 + (999 - deaths)
```

**Limitation**: Sorted set scores are IEEE 754 doubles. You have ~15 significant digits of precision. Plan your encoding to stay within this range.

---

## Time-Bucketed Leaderboards

### Daily/Weekly/Monthly

Use separate sorted sets per time period:

```
# Daily leaderboard
ZADD leaderboard:daily:2026-03-29 100 "player:alice"

# Weekly leaderboard
ZADD leaderboard:weekly:2026-W13 100 "player:alice"

# Monthly leaderboard
ZADD leaderboard:monthly:2026-03 100 "player:alice"
```

Set TTLs to auto-expire old leaderboards:

```
EXPIRE leaderboard:daily:2026-03-29 172800     # 2 days
EXPIRE leaderboard:weekly:2026-W13 1209600     # 14 days
EXPIRE leaderboard:monthly:2026-03 5184000     # 60 days
```

### Rolling Window Leaderboard

For a "last 24 hours" leaderboard, use timestamp-based members and trim periodically:

```
# Add score with timestamp as part of member
ZADD leaderboard:rolling <score> "player:alice:<timestamp>"

# Trim entries older than 24 hours
ZREMRANGEBYSCORE leaderboard:rolling -inf <24h_ago_timestamp>
```

**Warning**: This approach requires unique members per scoring event. Deduplication is the caller's responsibility.

---

## Union and Intersection for Combined Leaderboards

Aggregate scores across multiple sorted sets:

```
# Combine daily leaderboards into a weekly aggregate
ZUNIONSTORE leaderboard:weekly:combined 7 \
  leaderboard:daily:2026-03-23 \
  leaderboard:daily:2026-03-24 \
  leaderboard:daily:2026-03-25 \
  leaderboard:daily:2026-03-26 \
  leaderboard:daily:2026-03-27 \
  leaderboard:daily:2026-03-28 \
  leaderboard:daily:2026-03-29 \
  AGGREGATE SUM
```

| Aggregate | Behavior |
|-----------|----------|
| `SUM` | Sum scores across sets (default) |
| `MIN` | Take minimum score |
| `MAX` | Take maximum score |

---

## Scaling Considerations

**Memory**: Each sorted set member uses ~70 bytes of overhead plus the member string and score. A leaderboard with 1 million players uses ~100 MB.

**Operations**: All rank operations are O(log N). Even with 10 million players, `ZREVRANK` takes microseconds.

**Big leaderboards (10M+ members)**: `ZREVRANGE` with large ranges can be slow. Use pagination with small page sizes (20-50 entries).

**Cluster mode**: A single sorted set lives on one shard. For very large leaderboards (100M+ members), consider sharding by score range or using multiple sorted sets with `ZUNIONSTORE` for aggregation.

---

## See Also

- [Sorted Set Commands](../commands/sorted-sets.md) - ZADD, ZINCRBY, ZREVRANGE, ZREVRANK command reference
- [Performance Summary](../valkey-features/performance-summary.md) - ZRANK 45% faster in Valkey 8.1+
- [Key Best Practices](../best-practices/keys.md) - key naming for leaderboard keys
- [Performance Best Practices](../best-practices/performance.md) - pipelining bulk score updates
- [Memory Best Practices](../best-practices/memory.md) - sorted set encoding thresholds
