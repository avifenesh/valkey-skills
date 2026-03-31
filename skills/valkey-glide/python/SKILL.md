---
name: valkey-glide-python
description: "Use when building Python applications with Valkey GLIDE. Covers async/sync APIs, GlideClient, GlideClusterClient, configuration, TLS, authentication, OpenTelemetry, error handling, batching, PubSub."
version: 1.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Python Client

Self-contained guide for building Python applications with Valkey GLIDE.

## Routing

- Install/setup -> Installation
- Async client -> Async API sections
- Sync client -> Sync API section
- TLS/auth -> TLS and Authentication
- Streams/PubSub -> Streams, PubSub sections
- Error handling -> Error Handling
- Batching/transactions -> Batching
- JSON/Search modules -> Server Modules
- OTel/tracing -> OpenTelemetry

## Installation

```bash
# Async API (asyncio, anyio, trio)
pip install valkey-glide

# Sync API (GLIDE 2.1+)
pip install valkey-glide-sync
```

**Requirements:** Python 3.9 - 3.14

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64). No Windows. No Alpine/MUSL (requires glibc 2.17+).

**Packages:** The async and sync clients are distributed as separate packages. `valkey-glide` provides the `glide` module (async). `valkey-glide-sync` provides the `glide_sync` module (sync).

---

## Client Classes

| Class | Module | Mode | Description |
|-------|--------|------|-------------|
| `GlideClient` | `glide` / `glide_sync` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | `glide` / `glide_sync` | Cluster | Valkey Cluster with auto-topology |

Both are created via `create()` and accept a configuration object.

---

## Async API - Standalone

```python
import asyncio
from glide import (
    GlideClient,
    GlideClientConfiguration,
    NodeAddress,
)

async def main():
    config = GlideClientConfiguration(
        addresses=[NodeAddress("localhost", 6379)],
        request_timeout=5000,
    )
    client = await GlideClient.create(config)

    try:
        await client.set("greeting", "Hello from GLIDE")
        value = await client.get("greeting")
        print(f"Got: {value.decode()}")  # GLIDE returns bytes
    finally:
        await client.close()

asyncio.run(main())
```

## Async API - Cluster

```python
from glide import (
    GlideClusterClient,
    GlideClusterClientConfiguration,
    NodeAddress,
    ReadFrom,
)

config = GlideClusterClientConfiguration(
    addresses=[
        NodeAddress("node1.example.com", 6379),
        NodeAddress("node2.example.com", 6380),
    ],
    read_from=ReadFrom.PREFER_REPLICA,
)
client = await GlideClusterClient.create(config)

await client.set("key", "value")
value = await client.get("key")
await client.close()
```

Only seed node addresses are needed - GLIDE discovers the full cluster topology automatically.

---

## Sync API (GLIDE 2.1+)

Import from `glide_sync` instead of `glide`. Same API surface, but blocks on each call.

```python
from glide_sync import (
    GlideClient,
    GlideClientConfiguration,
    NodeAddress,
)

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
)
client = GlideClient.create(config)

client.set("greeting", "Hello from GLIDE")
value = client.get("greeting")
print(f"Got: {value.decode()}")

client.close()
```

The sync client uses CFFI to call the Rust FFI layer directly, while the async client uses PyO3 with Unix socket IPC.

---

## Configuration - Standalone

```python
from glide import (
    GlideClientConfiguration,
    NodeAddress,
    ReadFrom,
    BackoffStrategy,
    ServerCredentials,
    ProtocolVersion,
)

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    use_tls=False,
    credentials=ServerCredentials(password="mypass"),
    read_from=ReadFrom.PRIMARY,
    request_timeout=5000,
    reconnect_strategy=BackoffStrategy(
        num_of_retries=5,
        factor=100,
        exponent_base=2,
    ),
    database_id=0,
    client_name="my-app",
    protocol=ProtocolVersion.RESP3,
    inflight_requests_limit=1000,
    lazy_connect=True,
)
```

## Configuration - Cluster

```python
from glide import (
    GlideClusterClientConfiguration,
    NodeAddress,
    ReadFrom,
    PeriodicChecksManualInterval,
)

config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("node1.example.com", 6379)],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
    periodic_checks=PeriodicChecksManualInterval(duration_in_sec=30),
)
```

---

## Authentication

### Password-Based

```python
creds = ServerCredentials(password="secret")
creds = ServerCredentials(username="myuser", password="secret")
```

### IAM Authentication

```python
from glide import IamAuthConfig, ServiceType

iam = IamAuthConfig(
    cluster_name="my-cluster",
    service=ServiceType.ELASTICACHE,
    region="us-east-1",
)
creds = ServerCredentials(username="myuser", iam_config=iam)
```

Password and IAM are mutually exclusive.

---

## Reconnection Strategy

```python
from glide import BackoffStrategy

strategy = BackoffStrategy(
    num_of_retries=5,
    factor=100,            # milliseconds
    exponent_base=2,
    jitter_percent=20,     # optional
)
```

Formula: `factor * (exponent_base ^ N)` where N is the attempt number. Optional `jitter_percent` adds randomness as a percentage of the computed duration.

---

## ReadFrom Options

| Value | Behavior |
|-------|----------|
| `ReadFrom.PRIMARY` | All reads to primary (default) |
| `ReadFrom.PREFER_REPLICA` | Round-robin replicas, fallback to primary |
| `ReadFrom.AZ_AFFINITY` | Prefer same-AZ replicas (requires `client_az`) |
| `ReadFrom.AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then same-AZ primary, then remote |

AZ Affinity requires Valkey 8.0+ and `client_az` must be set.

---

## Error Handling

All error classes are in `glide_shared.exceptions`:

| Error | Description |
|-------|-------------|
| `GlideError` | Base class for all errors |
| `RequestError` | Base for request-level failures |
| `TimeoutError` | Request exceeded `request_timeout` |
| `ConnectionError` | Connection lost (client auto-reconnects) |
| `ExecAbortError` | Transaction aborted (WATCH key changed) |
| `ConfigurationError` | Invalid client configuration (subclass of RequestError) |
| `ClosingError` | Client closed, no longer usable |

```python
from glide import (
    TimeoutError as GlideTimeoutError,
    ConnectionError as GlideConnectionError,
    RequestError,
)

try:
    value = await client.get("key")
except GlideTimeoutError:
    print("Request timed out")
except GlideConnectionError:
    print("Connection lost - client is reconnecting")
except RequestError as e:
    print(f"Request failed: {e}")
```

Import as `GlideTimeoutError` / `GlideConnectionError` to avoid shadowing Python builtins.

---

## Return Types

- String commands return `bytes` - decode with `.decode()`
- `GET` returns `Optional[bytes]` - `None` when key does not exist
- Numeric commands return `int` or `float`
- `SET` returns `Optional[str]` - `"OK"` on success

---

## Data Type Operations

### Strings

```python
from glide import ExpirySet, ExpiryType, ConditionalChange

await client.set("key", "value")
await client.set("key", "value", expiry=ExpirySet(ExpiryType.SEC, 60))
await client.set("key", "value",
    conditional_set=ConditionalChange.ONLY_IF_DOES_NOT_EXIST)
val = await client.get("key")          # returns bytes
val.decode()                           # "value"
count = await client.incr("counter")
count = await client.incrby("counter", 5)
await client.mset({"k1": "v1", "k2": "v2"})
vals = await client.mget(["k1", "k2"])
```

No separate `setnx`/`setex` - use `set()` with options.

### Hashes

```python
await client.hset("hash", {"field1": "value1"})
await client.hset("hash", {"f1": "v1", "f2": "v2"})
val = await client.hget("hash", "field1")       # bytes
all_vals = await client.hgetall("hash")          # {b"f1": b"v1", b"f2": b"v2"}
exists = await client.hexists("hash", "field1")  # bool
await client.hdel("hash", ["field1"])
keys = await client.hkeys("hash")
vals = await client.hvals("hash")
length = await client.hlen("hash")
```

### Lists

```python
await client.lpush("list", ["a", "b", "c"])     # list arg, not varargs
await client.rpush("list", ["x", "y"])
val = await client.lpop("list")                  # bytes
vals = await client.lrange("list", 0, -1)        # list of bytes
length = await client.llen("list")
await client.lset("list", 0, "new_value")
await client.ltrim("list", 0, 99)
```

### Sets

```python
await client.sadd("set", ["a", "b", "c"])       # list arg
await client.srem("set", ["a"])                  # list arg
members = await client.smembers("set")           # set of bytes
await client.sismember("set", "b")               # bool
count = await client.scard("set")
inter = await client.sinter(["set1", "set2"])
union = await client.sunion(["set1", "set2"])
```

### Sorted Sets

```python
from glide import RangeByIndex

await client.zadd("zset", {"alice": 1.0, "bob": 2.0})
await client.zrange_withscores("zset", RangeByIndex(0, -1))
await client.zscore("zset", "alice")
rank = await client.zrank("zset", "alice")
count = await client.zcard("zset")
await client.zrem("zset", ["alice"])
```

### Delete and Exists

```python
await client.delete(["k1", "k2", "k3"])         # list arg
await client.exists(["k1", "k2"])                # returns count
await client.expire("key", 60)
ttl = await client.ttl("key")
key_type = await client.type("key")
```

---

## Batching

### Pipeline (Non-Atomic)

```python
from glide import Batch

pipe = Batch(is_atomic=False)
pipe.set("k1", "v1")
pipe.set("k2", "v2")
pipe.get("k1")
results = await client.exec(pipe, raise_on_error=False)
```

### Transaction (Atomic)

```python
tx = Batch(is_atomic=True)
tx.set("k1", "v1")
tx.get("k1")
results = await client.exec(tx, raise_on_error=True)
```

---

## PubSub

```python
# Subscriptions configured at client creation or via dynamic subscribe (GLIDE 2.3+)
msg = await subscriber.get_pubsub_message()       # blocking
msg = subscriber.try_get_pubsub_message()          # non-blocking

# Callback-driven (set during config)
def on_message(msg, context):
    print(f"{msg.channel}: {msg.message}")
```

GLIDE automatically resubscribes on reconnection. Use a dedicated client for subscriptions.

---

## Server Modules (JSON and Vector Search)

Requires JSON and Search modules loaded on the Valkey server. Import `glide_json` for JSON document operations and `ft` for search/vector indexing. Both use `customCommand` internally and work with standalone and cluster clients.

### JSON - Store and Retrieve Documents

```python
from glide import glide_json

# Store a JSON document
await glide_json.set(client, "user:1", "$", '{"name":"Alice","age":30,"tags":["admin"]}')

# Read a nested value (JSONPath returns an array)
name = await glide_json.get(client, "user:1", "$.name")  # b'["Alice"]'

# Increment a numeric field
await glide_json.numincrby(client, "user:1", "$.age", 1)

# Append to an array
await glide_json.arrappend(client, "user:1", "$.tags", ['"developer"'])
```

### Vector Search - Create Index and Search

```python
from glide import (
    ft, FtCreateOptions, DataType, TextField, TagField,
    VectorField, VectorAlgorithm, VectorFieldAttributesHnsw,
    DistanceMetricType, VectorType,
)

# Create an index on HASH keys with text and tag fields
schema = [TextField("title"), TagField("category")]
options = FtCreateOptions(DataType.HASH, prefixes=["article:"])
await ft.create(client, "article_idx", schema, options)

# Search by tag filter
results = await ft.search(client, "article_idx", "@category:{tech}")
# results: [total_count, [{"key": ..., "fields": {...}}, ...]]
```

---

<!-- SHARED-GLIDE-SECTION: keep in sync with valkey-glide/SKILL.md -->

## Architecture

| Topic | Reference |
|-------|-----------|
| Three-layer design: Rust core, Protobuf IPC, language FFI bridges | [overview](reference/architecture/overview.md) |
| Multiplexed connections, inflight limits, request timeout, reconnect logic | [connection-model](reference/architecture/connection-model.md) |
| Cluster slot routing, MOVED/ASK handling, multi-slot splitting, ReadFrom | [cluster-topology](reference/architecture/cluster-topology.md) |


## Features

| Topic | Reference |
|-------|-----------|
| Batch API: atomic (MULTI/EXEC) and non-atomic (pipeline) modes | [batching](reference/features/batching.md) |
| PubSub: exact, pattern, and sharded subscriptions, dynamic callbacks | [pubsub](reference/features/pubsub.md) |
| Scripting: Lua EVAL/EVALSHA with SHA1 caching, FCALL Functions | [scripting](reference/features/scripting.md) |
| OpenTelemetry: per-command tracing spans, metrics export | [opentelemetry](reference/features/opentelemetry.md) |
| AZ affinity: availability-zone-aware read routing, cross-zone savings | [az-affinity](reference/features/az-affinity.md) |
| TLS, mTLS, custom CA certificates, password auth, IAM tokens | [tls-auth](reference/features/tls-auth.md) |
| Compression: transparent Zstd/LZ4 for large values (SET/GET) | [compression](reference/features/compression.md) |
| Streams: XADD, XREAD, XREADGROUP, consumer groups, XCLAIM, XAUTOCLAIM | [streams](reference/features/streams.md) |
| Server modules: GlideJson (JSON), GlideFt (Search/Vector) | [server-modules](reference/features/server-modules.md) |
| Logging: log levels, file rotation, GLIDE_LOG_DIR, debug output | [logging](reference/features/logging.md) |
| Geospatial: GEOADD, GEOSEARCH, GEODIST, proximity queries | [geospatial](reference/features/geospatial.md) |
| Bitmaps and HyperLogLog: BITCOUNT, BITFIELD, PFADD, PFCOUNT | [bitmaps-hyperloglog](reference/features/bitmaps-hyperloglog.md) |
| Hash field expiration: HSETEX, HGETEX, HEXPIRE (Valkey 9.0+) | [hash-field-expiration](reference/features/hash-field-expiration.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Performance: benchmarks, GLIDE vs native clients, batching throughput | [performance](reference/best-practices/performance.md) |
| Error handling: exception types, reconnection, retry, batch errors | [error-handling](reference/best-practices/error-handling.md) |
| Production: timeout config, connection management, cloud defaults | [production](reference/best-practices/production.md) |

<!-- END SHARED-GLIDE-SECTION -->

## Cross-References

- `valkey` skill - Valkey server commands, data types, patterns
