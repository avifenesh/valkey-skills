---
name: migrate-redis-py
description: "Use when migrating Python from redis-py to Valkey GLIDE. Covers API-shape divergences (bytes returns, list args, ExpirySet/ConditionalChange, ZRANGE variants), PubSub mental-model switch, Batch API, platform constraints. Not for greenfield Python apps - use valkey-glide-python instead."
version: 1.1.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from redis-py to Valkey GLIDE (Python)

Use when moving an existing redis-py application to GLIDE. Assumes you already know redis-py. Covers what breaks or changes shape; the 95% of commands that translate literally (just `r.` -> `await client.` with bytes returns) are not listed here.

## Divergences that actually matter

| Area | redis-py | GLIDE |
|------|----------|-------|
| Default mode | Sync | Async-first; sync via `glide_sync` package (GLIDE 2.1+) |
| Return types | `str` with `decode_responses=True` | `bytes` always - call `.decode()` at each read site |
| Multi-arg commands | Varargs: `r.delete("k1", "k2")` | List args: `await client.delete(["k1", "k2"])` |
| SET expiry/conditional | Kwargs `ex=60`, `nx=True` | Typed `ExpirySet(ExpiryType.SEC, 60)`, `ConditionalChange.ONLY_IF_DOES_NOT_EXIST` |
| ZRANGE variants | `withscores=True` kwarg | Separate method `zrange_withscores`; typed `RangeByIndex` / `RangeByScore` / `RangeByLex` |
| Pipeline | `pipe = r.pipeline(); pipe.execute()` | `batch = Batch(is_atomic=False); await client.exec(batch, raise_on_error=...)` - verb is a client method, not the batch |
| Transaction | `r.pipeline(transaction=True)` | `Batch(is_atomic=True)` - same class, flag-selected |
| Connection pool | `max_connections=N` | Multiplexer - no pool knob; one client per process |
| Blocking commands | Share the pool | Occupy the single connection - use a dedicated client |
| Cluster | `redis.RedisCluster(skip_full_coverage_check=...)` | `GlideClusterClient` with auto-topology discovery |
| PubSub | `p = r.pubsub(); p.subscribe(...)`; `p.listen()` | Static config OR dynamic `subscribe()` (2.3+); callback OR polling |
| `publish` | `r.publish(channel, message)` | `await client.publish(message, channel)` - **arguments REVERSED**; top silent-bug source in migration |
| `decode_responses` | Kwarg | No equivalent - handle bytes at boundary |
| `socket_timeout` | Seconds float | `request_timeout` milliseconds int |
| `retry_on_timeout` | Bool | `reconnect_strategy=BackoffStrategy(...)` |

## Config translation

```python
# redis-py:
r = redis.Redis(host="h", port=6379, db=0, password="pw",
                ssl=True, socket_timeout=5, decode_responses=True)

# GLIDE async:
from glide import (
    GlideClient, GlideClientConfiguration, NodeAddress,
    ServerCredentials,
)
config = GlideClientConfiguration(
    addresses=[NodeAddress("h", 6379)],
    database_id=0,
    credentials=ServerCredentials(password="pw"),
    use_tls=True,
    request_timeout=5000,  # ms not seconds
)
client = await GlideClient.create(config)

# GLIDE sync (2.1+):
from glide_sync import GlideClient, GlideClientConfiguration, NodeAddress
client = GlideClient.create(config)  # no await
```

## Migration strategy

No compatibility layer exists for Python (unlike Java's jedis compat layer). Migrate incrementally via an adapter:

1. Install `valkey-glide` alongside `redis-py`.
2. Build a thin adapter covering every `r.*` call in your app.
3. Start with the GLIDE side of the adapter implemented command-by-command.
4. Swap services to the GLIDE adapter behind a feature flag.
5. Remove `redis-py` only after every call site is migrated and canaried.

Big-bang migration trips on bytes-vs-str, blocking-command semantics, WATCH, and timeout unit changes.

## Reference

| Topic | File |
|-------|------|
| Three universal changes (bytes, await, list args), SET typed options, HSET mapping, ZRANGE variants, cluster | [api-mapping](reference/api-mapping.md) |
| PubSub mental-model switch, Batch API, migration strategy, platform notes | [advanced-patterns](reference/advanced-patterns.md) |

## Gotchas (the short list)

1. **Bytes everywhere** - no `decode_responses` option.
2. **Timeout units** - `request_timeout` is milliseconds (default 250 ms), redis-py `socket_timeout` is seconds.
3. **No connection pool** - single multiplexer per process; blocking commands (`BLPOP`, `BRPOP`, `BLMOVE`, `BZPOPMAX`/`MIN`, `BRPOPLPUSH`, `BLMPOP`, `BZMPOP`, `XREAD`/`XREADGROUP` with `BLOCK`) and WATCH/MULTI/EXEC need a dedicated client.
4. **Async by default** - sync via `glide_sync` from 2.1+.
5. **`protobuf>=3.20`** required - conflicts surface as import errors.
6. **Alpine not supported** - glibc 2.17+ required.
7. **Proxy incompatibility** - GLIDE sends `INFO REPLICATION`, `CLIENT SETINFO`, `CLIENT SETNAME` at connect; strict proxies break this.
8. **PubSub static subscriptions require RESP3** - `ConfigurationError` otherwise.
9. **`TimeoutError` / `ConnectionError` shadow Python built-ins** - import with aliases.
10. **Reconnection is infinite** - `BackoffStrategy.num_of_retries` only caps the backoff sequence length.
11. **`publish()` argument order is REVERSED** - GLIDE is `publish(message, channel)`, redis-py is `publish(channel, message)`. Silent bug during migration.

## Cross-references

- `valkey-glide-python` - full Python skill for GLIDE features beyond the migration scope
- `glide-dev` - GLIDE core internals if you need to debug binding-level issues
