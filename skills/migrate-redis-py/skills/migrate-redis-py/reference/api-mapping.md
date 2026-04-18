# redis-py to GLIDE: where signatures diverge

Use when translating redis-py calls and the signature is NOT obvious. Where GLIDE mirrors redis-py 1:1 (most commands), just replace `r.` with `await client.` - that pattern is not listed here.

## Three universal changes

Apply to every command:

1. **Bytes not str**: all string returns are `bytes`. `.decode()` at each read site.
2. **Awaitable not blocking** (async API): prefix `await`, use `glide`. For sync use `glide_sync` with no `await`.
3. **List args not varargs**: multi-key / multi-value commands take a list, not positional args.

```python
# redis-py varargs:
r.delete("k1", "k2", "k3")
r.exists("k1", "k2")
r.lpush("list", "a", "b", "c")
r.sadd("set", "a", "b", "c")
r.srem("set", "a", "b")

# GLIDE: wrap the extra args in a list:
await client.delete(["k1", "k2", "k3"])
await client.exists(["k1", "k2"])
await client.lpush("list", ["a", "b", "c"])
await client.sadd("set", ["a", "b", "c"])
await client.srem("set", ["a", "b"])
```

## SET: typed options replace kwargs

redis-py combines everything on `set()` / has specialized `setnx` / `setex`. GLIDE routes them through typed options and drops the aliases.

| redis-py | GLIDE |
|----------|-------|
| `r.set(k, v, ex=60)` | `await client.set(k, v, expiry=ExpirySet(ExpiryType.SEC, 60))` |
| `r.set(k, v, px=500)` | `await client.set(k, v, expiry=ExpirySet(ExpiryType.MILLSEC, 500))` |
| `r.set(k, v, exat=ts)` | `await client.set(k, v, expiry=ExpirySet(ExpiryType.UNIX_SEC, ts))` |
| `r.set(k, v, pxat=ms_ts)` | `await client.set(k, v, expiry=ExpirySet(ExpiryType.UNIX_MILLSEC, ms_ts))` |
| `r.set(k, v, nx=True)` or `r.setnx(k, v)` | `await client.set(k, v, conditional_set=ConditionalChange.ONLY_IF_DOES_NOT_EXIST)` |
| `r.set(k, v, xx=True)` | `await client.set(k, v, conditional_set=ConditionalChange.ONLY_IF_EXISTS)` |
| `r.setex(k, 60, v)` | `await client.set(k, v, expiry=ExpirySet(ExpiryType.SEC, 60))` |
| `r.set(k, v, keepttl=True)` | `await client.set(k, v, expiry=ExpirySet(ExpiryType.KEEP_TTL))` |

`ExpiryType` has five values: `SEC`, `MILLSEC`, `UNIX_SEC`, `UNIX_MILLSEC`, `KEEP_TTL`. **Note the upstream typo - `MILLSEC` is missing the `I`. Grep for `MILLSEC`, not `MILLISEC`.**

`ConditionalChange` has exactly two values: `ONLY_IF_EXISTS` and `ONLY_IF_DOES_NOT_EXIST`. Valkey 9.0's `IFEQ` is a separate `OnlyIfEqual(comparison_value=...)` dataclass (not part of the `ConditionalChange` enum).

Imports: `from glide import ExpirySet, ExpiryType, ConditionalChange, OnlyIfEqual`.

## HSET: mapping is positional

redis-py accepts `hset(k, "f", "v")` and `hset(k, mapping={...})`. GLIDE drops the two-string form - always pass a dict:

```python
await client.hset("hash", {"f1": "v1", "f2": "v2"})
```

## ZRANGE variants: separate methods, not flags

redis-py uses kwargs on one method; GLIDE has separate methods for the withscores variant, and takes typed range objects instead of raw indexes/scores:

| redis-py | GLIDE |
|----------|-------|
| `r.zrange(k, 0, -1)` | `await client.zrange(k, RangeByIndex(0, -1))` |
| `r.zrange(k, 0, -1, withscores=True)` | `await client.zrange_withscores(k, RangeByIndex(0, -1))` |
| `r.zrange(k, 1.0, 2.0, byscore=True)` | `await client.zrange(k, RangeByScore(ScoreBoundary(1.0), ScoreBoundary(2.0)))` |
| `r.zrevrange(k, 0, -1)` | `await client.zrange(k, RangeByIndex(0, -1, reverse=True))` |

`RangeByLex` exists too for BYLEX queries.

## Cluster: `RedisCluster` -> `GlideClusterClient`

`redis.RedisCluster(host=, port=, skip_full_coverage_check=True)` has no direct translation. GLIDE's `GlideClusterClient` does full-topology auto-discovery from any seed nodes; `skip_full_coverage_check` has no equivalent (GLIDE always discovers the full shard set). `read_from` replaces redis-py's read replica routing behavior.

## Everything else is named the same

For 95% of commands (`get`, `hget`, `hgetall`, `lpop`, `lrange`, `smembers`, `sismember`, `zadd`, `zscore`, `exists`, `ttl`, `expire`, `keys`, `type`, `incr`/`decr` and friends, `xadd`/`xread`/`xreadgroup`/`xack`, `publish`, etc.) the only changes are the three universal ones at the top of this file (bytes, await, list args). Just translate.
