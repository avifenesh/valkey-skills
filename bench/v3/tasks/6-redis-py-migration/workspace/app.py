"""
Async application using redis-py (redis.asyncio).
Features: pipeline batching, pub/sub, Lua scripting, sorted set leaderboard, basic CRUD.
"""

import asyncio
from typing import Optional

import redis.asyncio as aioredis


# ---------------------------------------------------------------------------
# Basic CRUD
# ---------------------------------------------------------------------------

async def crud_set(client: aioredis.Redis, key: str, value: str, ttl: Optional[int] = None) -> bool:
    """Set a key. Optionally set TTL in seconds. Returns True on success."""
    if ttl is not None:
        return await client.set(key, value, ex=ttl)
    return await client.set(key, value)


async def crud_get(client: aioredis.Redis, key: str) -> Optional[str]:
    """Get a key value. Returns None if the key does not exist."""
    val = await client.get(key)
    if val is None:
        return None
    return val.decode() if isinstance(val, bytes) else str(val)


async def crud_delete(client: aioredis.Redis, *keys: str) -> int:
    """Delete one or more keys. Returns number of keys removed."""
    return await client.delete(*keys)


async def crud_exists(client: aioredis.Redis, *keys: str) -> int:
    """Check existence of one or more keys. Returns count of existing keys."""
    return await client.exists(*keys)


# ---------------------------------------------------------------------------
# Pipeline Batching
# ---------------------------------------------------------------------------

async def batch_set(client: aioredis.Redis, mapping: dict[str, str]) -> list:
    """Set multiple key-value pairs in a single pipeline round-trip."""
    pipe = client.pipeline(transaction=False)
    for key, value in mapping.items():
        pipe.set(key, value)
    return await pipe.execute()


async def batch_get(client: aioredis.Redis, keys: list[str]) -> list[Optional[str]]:
    """Get multiple keys in a single pipeline round-trip."""
    pipe = client.pipeline(transaction=False)
    for key in keys:
        pipe.get(key)
    results = await pipe.execute()
    return [v.decode() if isinstance(v, bytes) else v for v in results]


# ---------------------------------------------------------------------------
# Pub/Sub
# ---------------------------------------------------------------------------

async def subscribe_and_collect(
    client: aioredis.Redis,
    channel: str,
    max_messages: int = 3,
    timeout: float = 5.0,
) -> list[str]:
    """Subscribe to a channel and collect up to max_messages. Returns list of message strings."""
    pubsub = client.pubsub()
    await pubsub.subscribe(channel)
    messages: list[str] = []
    try:
        deadline = asyncio.get_event_loop().time() + timeout
        while len(messages) < max_messages:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                break
            msg = await asyncio.wait_for(
                pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0),
                timeout=remaining,
            )
            if msg and msg["type"] == "message":
                data = msg["data"]
                messages.append(data.decode() if isinstance(data, bytes) else str(data))
    finally:
        await pubsub.unsubscribe(channel)
        await pubsub.close()
    return messages


# ---------------------------------------------------------------------------
# Lua Scripting - Atomic Counter with Expiry
# ---------------------------------------------------------------------------

COUNTER_SCRIPT = """
local current = redis.call('INCR', KEYS[1])
if current == 1 then
    redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return current
"""


async def atomic_counter(client: aioredis.Redis, key: str, ttl: int = 60) -> int:
    """Atomically increment a counter and set expiry on first increment.
    Uses EVALSHA with automatic fallback to EVAL.
    Returns the new counter value.
    """
    script = client.register_script(COUNTER_SCRIPT)
    result = await script(keys=[key], args=[ttl])
    return int(result)


# ---------------------------------------------------------------------------
# Sorted Set Leaderboard
# ---------------------------------------------------------------------------

async def leaderboard_add(client: aioredis.Redis, board: str, entries: dict[str, float]) -> int:
    """Add entries to a leaderboard sorted set. Returns number of new entries added."""
    return await client.zadd(board, entries)


async def leaderboard_top(client: aioredis.Redis, board: str, count: int = 10) -> list[tuple[str, float]]:
    """Get top N entries from the leaderboard (highest scores first).
    Returns list of (member, score) tuples.
    """
    results = await client.zrevrange(board, 0, count - 1, withscores=True)
    return [(m.decode() if isinstance(m, bytes) else m, s) for m, s in results]


async def leaderboard_range_by_score(
    client: aioredis.Redis,
    board: str,
    min_score: float,
    max_score: float,
) -> list[tuple[str, float]]:
    """Get entries within a score range (inclusive). Returns list of (member, score) tuples."""
    results = await client.zrangebyscore(board, min_score, max_score, withscores=True)
    return [(m.decode() if isinstance(m, bytes) else m, s) for m, s in results]
