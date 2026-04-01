---
name: migrate-redis-py
description: "redis-py to Valkey GLIDE migration for Python. Covers async-first API, bytes returns (no decode_responses), list args, PubSub, ExpirySet/ConditionalChange. Not for greenfield Python apps - use valkey-glide-python instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from redis-py to Valkey GLIDE (Python)

Use when migrating a Python application from redis-py to the GLIDE client library.

## Routing

- String, hash, list, set, sorted set, delete, exists, cluster -> API Mapping
- Pipeline, transaction, Batch API -> Advanced Patterns
- PubSub, subscribe, publish, dynamic subscriptions -> Advanced Patterns

## Key Differences

| Area | redis-py | GLIDE |
|------|----------|-------|
| Default mode | Synchronous | Async-first (sync API from GLIDE 2.1) |
| Return type | Strings (with decode_responses=True) | Bytes always - call .decode() |
| Multi-arg commands | Varargs: delete("k1", "k2") | List args: delete(["k1", "k2"]) |
| Expiry | Keyword args: ex=60 | ExpirySet objects |
| Conditional SET | Separate setnx(), setex() | Enum options on set() |
| Connection model | Connection pool (default 10 conns) | Single multiplexed connection per node |
| Cluster client | redis.RedisCluster() | GlideClusterClient with auto-topology |

## Quick Start - Connection Setup

**redis-py:**
```python
import redis
r = redis.Redis(host="localhost", port=6379, db=0, decode_responses=True)
r.ping()
```

**GLIDE (async):**
```python
from glide import GlideClient, GlideClientConfiguration, NodeAddress
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)], database_id=0, request_timeout=5000)
client = await GlideClient.create(config)
await client.ping()
```

**GLIDE (sync - 2.1+):**
```python
from glide_sync import GlideClient, GlideClientConfiguration, NodeAddress
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)], database_id=0)
client = GlideClient.create(config)
client.ping()
```

## Configuration Mapping

| redis-py parameter | GLIDE equivalent |
|--------------------|------------------|
| host, port | NodeAddress(host, port) in addresses list |
| db | database_id |
| password | ServerCredentials(password=...) in credentials |
| username | ServerCredentials(username=..., password=...) |
| socket_timeout | request_timeout (milliseconds, not seconds) |
| ssl=True | use_tls=True |
| retry_on_timeout | Built-in reconnection with BackoffStrategy |
| decode_responses | No equivalent - always returns bytes |

## Incremental Migration Strategy

No drop-in replacement or compatibility layer exists for Python. Migration approach:

1. Install `valkey-glide` alongside `redis-py`
2. Create a wrapper/adapter that abstracts the client interface
3. Migrate command-by-command behind the adapter
4. Use `asyncio.gather()` or the Batch API for bulk operations
5. Swap out the adapter once all commands are migrated
6. Remove `redis-py` dependency

## Reference

| Topic | File |
|-------|------|
| Command-by-command API mapping (strings, hashes, lists, sets, sorted sets, delete, exists, cluster) | [api-mapping](reference/api-mapping.md) |
| Pipelines, transactions, Pub/Sub, platform notes | [advanced-patterns](reference/advanced-patterns.md) |

## See Also

- **valkey-glide-python** skill - full GLIDE Python API details
- PubSub (see valkey-glide skill) - subscription patterns and dynamic PubSub
- Batching (see valkey-glide skill) - pipeline and transaction patterns

## Gotchas

1. **Bytes everywhere.** GLIDE has no decode_responses option. All string values return as bytes. Call .decode() at each read site.
2. **List arguments.** Commands like delete, exists, lpush, sadd take a list, not varargs.
3. **No connection pool tuning.** GLIDE uses a single multiplexed connection per node.
4. **Async by default.** The primary API is async. The sync wrapper (glide_sync) is available from GLIDE 2.1.
5. **Timeout units.** redis-py uses seconds (float). GLIDE uses milliseconds (int). Default is 250ms.
6. **No decode_responses shortcut.** Add .decode() calls at each read site, or build a thin wrapper.
7. **Protobuf dependency conflict.** Requires `protobuf>=3.20` - pin versions carefully.
8. **Alpine Linux not supported.** GLIDE requires glibc 2.17+ - use Debian-based container images.
9. **Proxy incompatibility.** GLIDE runs INFO REPLICATION and CLIENT commands during connection setup.
