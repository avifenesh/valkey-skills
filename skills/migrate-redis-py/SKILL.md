---
name: migrate-redis-py
description: "Use when migrating Python applications from redis-py to Valkey GLIDE. Covers async-first API, bytes returns (no decode_responses), list args, PubSub, ExpirySet/ConditionalChange. Not for greenfield Python apps - use valkey-glide-python instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from redis-py to Valkey GLIDE (Python)

Use when migrating a Python application from redis-py to the GLIDE client library.

---

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

---

## Connection Setup

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
    addresses=[NodeAddress("localhost", 6379)],
    database_id=0,
    request_timeout=5000,
)
client = await GlideClient.create(config)
await client.ping()
```

**GLIDE (sync - 2.1+):**
```python
from glide_sync import GlideClient, GlideClientConfiguration, NodeAddress

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    database_id=0,
)
client = GlideClient.create(config)
client.ping()
```

---

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

---

## String Operations

**redis-py:**
```python
r.set("key", "value")
r.set("key", "value", ex=60)          # expire in 60s
r.set("key", "value", nx=True)        # only if not exists
r.setnx("key", "value")               # same as nx=True
r.setex("key", 60, "value")           # set + expire
val = r.get("key")                     # returns str
```

**GLIDE:**
```python
from glide import ExpirySet, ExpiryType, ConditionalChange

await client.set("key", "value")
await client.set("key", "value", expiry=ExpirySet(ExpiryType.SEC, 60))
await client.set("key", "value", conditional_set=ConditionalChange.ONLY_IF_DOES_NOT_EXIST)
# No separate setnx/setex - use set() with options
val = await client.get("key")          # returns bytes
val.decode()                           # "value"
```

---

## Hash Operations

**redis-py:**
```python
r.hset("hash", "field1", "value1")
r.hset("hash", mapping={"f1": "v1", "f2": "v2"})
val = r.hget("hash", "field1")
all_vals = r.hgetall("hash")           # {"f1": "v1", "f2": "v2"}
```

**GLIDE:**
```python
await client.hset("hash", {"field1": "value1"})
await client.hset("hash", {"f1": "v1", "f2": "v2"})
val = await client.hget("hash", "field1")       # bytes
all_vals = await client.hgetall("hash")          # {b"f1": b"v1", b"f2": b"v2"}
```

---

## List Operations

**redis-py:**
```python
r.lpush("list", "a", "b", "c")
r.rpush("list", "x", "y")
val = r.lpop("list")
vals = r.lrange("list", 0, -1)
```

**GLIDE:**
```python
await client.lpush("list", ["a", "b", "c"])     # list arg, not varargs
await client.rpush("list", ["x", "y"])
val = await client.lpop("list")                  # bytes
vals = await client.lrange("list", 0, -1)        # list of bytes
```

---

## Set Operations

**redis-py:**
```python
r.sadd("set", "a", "b", "c")
r.srem("set", "a")
members = r.smembers("set")
r.sismember("set", "b")
```

**GLIDE:**
```python
await client.sadd("set", ["a", "b", "c"])       # list arg
await client.srem("set", ["a"])                  # list arg
members = await client.smembers("set")           # set of bytes
await client.sismember("set", "b")               # bool
```

---

## Sorted Set Operations

**redis-py:**
```python
r.zadd("zset", {"alice": 1.0, "bob": 2.0})
r.zrange("zset", 0, -1, withscores=True)
r.zscore("zset", "alice")
```

**GLIDE:**
```python
await client.zadd("zset", {"alice": 1.0, "bob": 2.0})
await client.zrange_withscores("zset", RangeByIndex(0, -1))
await client.zscore("zset", "alice")
```

---

## Delete and Exists

**redis-py:**
```python
r.delete("k1", "k2", "k3")           # varargs
r.exists("k1", "k2")                  # returns count
```

**GLIDE:**
```python
await client.delete(["k1", "k2", "k3"])         # list arg
await client.exists(["k1", "k2"])                # returns count
```

---

## Cluster Mode

**redis-py:**
```python
rc = redis.RedisCluster(
    host="node1.example.com",
    port=6379,
    skip_full_coverage_check=True,
)
```

**GLIDE:**
```python
from glide import GlideClusterClient, GlideClusterClientConfiguration, ReadFrom

config = GlideClusterClientConfiguration(
    addresses=[
        NodeAddress("node1.example.com", 6379),
        NodeAddress("node2.example.com", 6380),
    ],
    read_from=ReadFrom.PREFER_REPLICA,
)
client = await GlideClusterClient.create(config)
```

GLIDE discovers the full cluster topology from seed nodes automatically. No need to enumerate all nodes.

---

## Pub/Sub

**redis-py:**
```python
p = r.pubsub()
p.subscribe("channel")
p.psubscribe("events:*")
for message in p.listen():
    print(message["data"])
```

**GLIDE (static subscriptions - at client creation):**
```python
from glide import GlideClientConfiguration, NodeAddress, PubSubMsg

def on_message(msg: PubSubMsg, context):
    print(f"[{msg.channel}] {msg.message} (pattern={msg.pattern})")

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    pubsub_subscriptions=GlideClientConfiguration.PubSubSubscriptions(
        channels_and_patterns={
            GlideClientConfiguration.PubSubChannelModes.Exact: {"channel"},
            GlideClientConfiguration.PubSubChannelModes.Pattern: {"events:*"},
        },
        callback=on_message,
    ),
)
subscriber = await GlideClient.create(config)
```

**GLIDE (dynamic subscriptions - GLIDE 2.3+):**
```python
subscriber = await GlideClient.create(config)

# Blocking - waits for server confirmation
await subscriber.subscribe({"channel"}, timeout_ms=5000)
await subscriber.psubscribe({"events:*"}, timeout_ms=5000)

# Non-blocking - returns immediately, reconciliation happens async
await subscriber.subscribe_lazy({"channel"})
await subscriber.psubscribe_lazy({"events:*"})

# Receive messages via polling
msg = await subscriber.get_pubsub_message()       # async, blocks until message
msg = subscriber.try_get_pubsub_message()          # non-blocking, returns None if empty

# Unsubscribe
await subscriber.unsubscribe({"channel"})
await subscriber.punsubscribe({"events:*"})
await subscriber.unsubscribe()                     # all exact channels
```

GLIDE automatically resubscribes on reconnection. Use a dedicated client for subscriptions - a subscribing client enters a special mode where most regular commands are unavailable. Callback and polling modes are mutually exclusive on the same client.

---

## Pipelines and Transactions

**redis-py:**
```python
# Pipeline
pipe = r.pipeline(transaction=False)
pipe.set("k1", "v1")
pipe.set("k2", "v2")
pipe.get("k1")
results = pipe.execute()

# Transaction
tx = r.pipeline(transaction=True)
tx.set("k1", "v1")
tx.get("k1")
results = tx.execute()
```

**GLIDE:**
```python
from glide import Batch

# Pipeline (non-atomic)
pipe = Batch(is_atomic=False)
pipe.set("k1", "v1")
pipe.set("k2", "v2")
pipe.get("k1")
results = await client.exec(pipe, raise_on_error=False)

# Transaction (atomic)
tx = Batch(is_atomic=True)
tx.set("k1", "v1")
tx.get("k1")
results = await client.exec(tx, raise_on_error=True)
```

---

## Incremental Migration Strategy

No drop-in replacement or compatibility layer exists for Python. The recommended approach:

1. Install `valkey-glide` alongside `redis-py`
2. Create a wrapper/adapter that abstracts the client interface
3. Migrate command-by-command behind the adapter
4. Use `asyncio.gather()` or the Batch API for bulk operations
5. Swap out the adapter once all commands are migrated
6. Remove `redis-py` dependency
7. Review `best-practices/production.md` for timeout tuning, connection management, and observability setup

---

## See Also

- **valkey-glide-python** skill - full GLIDE Python API details
- PubSub (see valkey-glide skill) - subscription patterns and dynamic PubSub
- Batching (see valkey-glide skill) - pipeline and transaction patterns
- TLS and authentication (see valkey-glide skill) - TLS setup and credential management
- Production deployment (see valkey-glide skill) - timeout tuning, connection management, observability
- Error handling (see valkey-glide skill) - error types, reconnection, batch error semantics

---

## Gotchas

1. **Bytes everywhere.** GLIDE has no decode_responses option. Every string value comes back as bytes. You must call .decode() yourself or handle bytes throughout.

2. **List arguments.** Commands like delete, exists, lpush, sadd take a list, not varargs. Forgetting the brackets is a common first-day mistake.

3. **No connection pool tuning.** GLIDE uses a single multiplexed connection per node. Do not create connection pools - creating multiple client instances is only needed for blocking commands or WATCH isolation.

4. **Async by default.** The primary API is async. The sync wrapper (glide_sync) is available from GLIDE 2.1 but the async API is the recommended path.

5. **Timeout units.** redis-py uses seconds (float). GLIDE uses milliseconds (int). The default is 250ms.

6. **No decode_responses shortcut.** If you relied on decode_responses=True globally, you need to add .decode() calls at each read site, or build a thin wrapper.

---

## Additional Notes

1. **Protobuf dependency conflict.** The async package requires `protobuf>=3.20`, which can conflict with other packages (gRPC stubs, etc.). The sync package (`valkey-glide-sync`) also requires `>=3.20` but has fewer transitive conflicts. Pin protobuf versions carefully in your requirements.

2. **Alpine Linux not supported.** GLIDE Python requires glibc 2.17+ - MUSL-based distributions like Alpine are not supported. Use Debian-based container images instead.

3. **Proxy incompatibility.** GLIDE runs `INFO REPLICATION`, `CLIENT SETINFO`, and `CLIENT SETNAME` during connection setup. Proxies like Envoy that do not support these commands will fail at connect time.

4. **Trio and anyio support.** GLIDE transparently supports asyncio, anyio, and trio as of GLIDE 2.0.1. No special configuration needed if your application uses trio.
