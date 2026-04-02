# Leaderboard Patterns

Use when building real-time ranking systems, game leaderboards, top-N lists, or any feature requiring sorted scoring with efficient rank queries.

## Core Pattern

Sorted sets are the standard structure: ZADD to add/update scores, ZINCRBY to increment atomically, ZREVRANK for rank (0-indexed), ZREVRANGE for top-N, ZSCORE for a member's score. All rank operations are O(log N).

```
ZADD leaderboard 2500 "player:alice"
ZINCRBY leaderboard 100 "player:alice"
ZREVRANK leaderboard "player:alice"    # 0 = top rank
ZREVRANGE leaderboard 0 9 WITHSCORES  # top 10
```

Paginate with offsets. For "around me" views, compute `ZREVRANK` then `ZREVRANGE start end`.

Aggregate daily buckets with `ZUNIONSTORE ... AGGREGATE SUM`. Use `EXPIRE` on time-bucketed keys to auto-clean.

## Composite Scores

IEEE 754 doubles give ~15 significant digits. Pack score + tiebreaker: `points * 10^10 + (MAX_TS - timestamp)`.

## Valkey-Specific Notes

No behavioral changes to sorted set commands vs Redis 7. For cluster deployments, a single sorted set is pinned to one shard - shard by score range for 100M+ members. Use GLIDE's batch API (atomic transaction or pipeline) for concurrent score updates.
