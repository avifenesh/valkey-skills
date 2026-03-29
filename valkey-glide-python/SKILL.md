---
name: valkey-glide-python
description: "Use when building Python applications with Valkey GLIDE. Covers async/sync APIs, GlideClient, GlideClusterClient, configuration, TLS, authentication, OpenTelemetry, error handling, batching, PubSub, and migration from redis-py."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey GLIDE Python Client

Self-contained guide for building Python applications with Valkey GLIDE. Covers async and sync APIs, configuration, error handling, batching, PubSub, and migration from redis-py. For architecture concepts shared across all languages (connection model, topology discovery, protocol details), see the `valkey-glide` skill.

## Installation

```bash
pip install valkey-glide
```

**Requirements:** Python 3.9 - 3.14

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64). No Windows. No Alpine/MUSL (requires glibc 2.17+).

**Modules:**
- `glide` - async API (asyncio, anyio, trio)
- `glide_sync` - sync API (GLIDE 2.1+)

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

## Migration from redis-py

### Key Differences

| Area | redis-py | GLIDE |
|------|----------|-------|
| Default mode | Synchronous | Async-first (sync from 2.1) |
| Return type | Strings (decode_responses=True) | Bytes always |
| Multi-arg commands | Varargs: `delete("k1", "k2")` | List args: `delete(["k1", "k2"])` |
| Expiry | Keyword args: `ex=60` | ExpirySet objects |
| Conditional SET | `setnx()`, `setex()` | Enum options on `set()` |
| Connection model | Connection pool (default 10) | Single multiplexed conn per node |
| Timeout units | Seconds (float) | Milliseconds (int), default 250ms |

### Configuration Mapping

| redis-py | GLIDE |
|----------|-------|
| `host, port` | `NodeAddress(host, port)` in addresses list |
| `db` | `database_id` |
| `password` | `ServerCredentials(password=...)` |
| `socket_timeout` | `request_timeout` (ms, not seconds) |
| `ssl=True` | `use_tls=True` |
| `retry_on_timeout` | Built-in reconnection with `BackoffStrategy` |
| `decode_responses` | No equivalent - always returns bytes |

### Side-by-Side: Connection Setup

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

**GLIDE (sync):**
```python
from glide_sync import GlideClient, GlideClientConfiguration, NodeAddress
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    database_id=0,
)
client = GlideClient.create(config)
client.ping()
```

### Side-by-Side: String Operations

**redis-py:**
```python
r.set("key", "value", ex=60)
r.setnx("key", "value")
val = r.get("key")               # str
```

**GLIDE:**
```python
from glide import ExpirySet, ExpiryType, ConditionalChange
await client.set("key", "value", expiry=ExpirySet(ExpiryType.SEC, 60))
await client.set("key", "value",
    conditional_set=ConditionalChange.ONLY_IF_DOES_NOT_EXIST)
val = await client.get("key")    # bytes - call .decode()
```

### Side-by-Side: Pipelines and Transactions

**redis-py:**
```python
pipe = r.pipeline(transaction=False)
pipe.set("k1", "v1")
pipe.get("k1")
results = pipe.execute()

tx = r.pipeline(transaction=True)
tx.set("k1", "v1")
tx.get("k1")
results = tx.execute()
```

**GLIDE:**
```python
from glide import Batch

pipe = Batch(is_atomic=False)
pipe.set("k1", "v1")
pipe.get("k1")
results = await client.exec(pipe, raise_on_error=False)

tx = Batch(is_atomic=True)
tx.set("k1", "v1")
tx.get("k1")
results = await client.exec(tx, raise_on_error=True)
```

### Side-by-Side: Cluster Mode

**redis-py:**
```python
rc = redis.RedisCluster(
    host="node1.example.com", port=6379,
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

### Incremental Migration Strategy

1. Install `valkey-glide` alongside `redis-py`
2. Create a wrapper/adapter that abstracts the client interface
3. Migrate command-by-command behind the adapter
4. Use `asyncio.gather()` or the Batch API for bulk operations
5. Swap the adapter once all commands are migrated
6. Remove the `redis-py` dependency

No drop-in replacement or compatibility layer exists for Python.


## Streams

### Adding and Reading

```python
# Add entries
entry_id = await client.xadd("mystream", [("sensor", "temp"), ("value", "23.5")])

# Add with trimming
from glide import StreamAddOptions, TrimByMaxLen
entry_id = await client.xadd(
    "mystream",
    [("data", "value")],
    options=StreamAddOptions(trim=TrimByMaxLen(exact=False, threshold=1000)),
)

# Read from streams (entries after the given ID)
entries = await client.xread({"mystream": "0"})

# Read with blocking and count
from glide import StreamReadOptions
entries = await client.xread(
    {"mystream": "0"},
    options=StreamReadOptions(count=10, block_ms=5000),
)
```

### Range Queries

```python
from glide import MinId, MaxId
entries = await client.xrange("mystream", MinId(), MaxId())
entries = await client.xrange("mystream", MinId(), MaxId(), 100)
entries = await client.xrevrange("mystream", MaxId(), MinId())
length = await client.xlen("mystream")
```

### Consumer Groups

```python
# Create group (MKSTREAM creates stream if needed)
from glide import StreamGroupOptions
await client.xgroup_create("mystream", "mygroup", "0",
    StreamGroupOptions(make_stream=True))

# Read as consumer
from glide import StreamReadGroupOptions
messages = await client.xreadgroup(
    {"mystream": ">"}, "mygroup", "consumer1",
    StreamReadGroupOptions(count=10, block_ms=5000),
)

# Acknowledge processed entries
ack_count = await client.xack("mystream", "mygroup", ["1234567890123-0"])

# Inspect pending entries
pending = await client.xpending("mystream", "mygroup")

# Claim idle entries from failed consumers
claimed = await client.xclaim(
    "mystream", "mygroup", "consumer2",
    min_idle_time_ms=60000,
    ids=["1234567890123-0"],
)

# Auto-claim idle entries (Valkey 6.2+)
result = await client.xautoclaim(
    "mystream", "mygroup", "consumer2",
    min_idle_time_ms=60000, start="0",
)
```

Use a dedicated client for blocking XREAD/XREADGROUP to avoid blocking the multiplexed connection.

---

## OpenTelemetry Configuration

```python
from glide import (
    OpenTelemetryConfig,
    OpenTelemetryTracesConfig,
    OpenTelemetryMetricsConfig,
    OpenTelemetry,
)

config = OpenTelemetryConfig(
    traces=OpenTelemetryTracesConfig(
        endpoint="http://localhost:4317",
        sample_percentage=5,  # 0-100, defaults to 1
    ),
    metrics=OpenTelemetryMetricsConfig(
        endpoint="http://localhost:4317",
    ),
    flush_interval_ms=5000,
)

OpenTelemetry.init(config)
```

OTel can only be initialized once per process. Subsequent calls to `init()` are ignored. Emits per-command trace spans and metrics (timeouts, retries, MOVED errors) with no code changes beyond setup.

Sampling recommendations: development 100%, staging 10-25%, production 1-5%.

---

## TLS Configuration

### Basic TLS

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("valkey.example.com", 6380)],
    use_tls=True,
)
```

### Custom CA Certificates

```python
from glide import (
    AdvancedGlideClientConfiguration,
    TlsAdvancedConfiguration,
)

with open("/path/to/ca.pem", "rb") as f:
    ca_cert = f.read()

advanced = AdvancedGlideClientConfiguration(
    tls_config=TlsAdvancedConfiguration(root_pem_cacerts=ca_cert)
)
config = GlideClientConfiguration(
    addresses=[NodeAddress("valkey.example.com", 6380)],
    use_tls=True,
    advanced_config=advanced,
)
```

### Mutual TLS (GLIDE 2.3+)

```python
with open("/path/to/client-cert.pem", "rb") as f:
    client_cert = f.read()
with open("/path/to/client-key.pem", "rb") as f:
    client_key = f.read()

advanced = AdvancedGlideClientConfiguration(
    tls_config=TlsAdvancedConfiguration(
        root_pem_cacerts=ca_cert,
        client_cert_pem=client_cert,
        client_key_pem=client_key,
    )
)
```

Both `client_cert_pem` and `client_key_pem` must be provided together.

### TLS + Auth Combined

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("valkey.example.com", 6380)],
    use_tls=True,
    credentials=ServerCredentials(username="myuser", password="mypass"),
    advanced_config=AdvancedGlideClientConfiguration(
        tls_config=TlsAdvancedConfiguration(root_pem_cacerts=ca_cert)
    ),
)
```

---

## PubSub Patterns

```python
# Create separate subscriber and publisher clients
subscriber = await GlideClient.create(config)
publisher = await GlideClient.create(config)

# Dynamic subscribe (GLIDE 2.3+)
await subscriber.subscribe({"news", "events"})
await subscriber.psubscribe({"user:*"})

# Receive messages
msg = await subscriber.get_pubsub_message()
print(f"Channel: {msg.channel}, Message: {msg.message}")

# Non-blocking poll
msg = subscriber.try_get_pubsub_message()

# Unsubscribe
await subscriber.unsubscribe({"news"})

# Publish
await publisher.publish("Hello subscribers!", "events")
```

Always use a dedicated client for subscriptions - it enters subscriber mode where regular commands are unavailable.

---

## Batch Error Handling

```python
from glide import Batch

batch = Batch(is_atomic=False)
batch.set("k1", "v1")
batch.get("nonexistent")
batch.incr("k1")  # will fail - not numeric

# raise_on_error=False returns errors inline
results = await client.exec(batch, raise_on_error=False)
# results[0] = "OK", results[1] = None, results[2] = RequestError

# raise_on_error=True throws on first error
try:
    results = await client.exec(batch, raise_on_error=True)
except RequestError as e:
    print(f"Batch failed: {e}")
```

---

## GLIDE-Only Features in Python

### AZ Affinity

```python
config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("node1.example.com", 6379)],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
)
```

Requires Valkey 8.0+. See the `valkey-glide` skill for cross-language AZ Affinity details.

### IAM Authentication for AWS

```python
from glide import IamAuthConfig, ServiceType, ServerCredentials

iam = IamAuthConfig(
    cluster_name="my-cluster",
    service=ServiceType.ELASTICACHE,
    region="us-east-1",
    refresh_interval_seconds=300,
)
config = GlideClientConfiguration(
    addresses=[NodeAddress("my-cluster.amazonaws.com", 6379)],
    credentials=ServerCredentials(username="myuser", iam_config=iam),
    use_tls=True,
)
```

---

## Ecosystem Integrations

- AWS Lambda Powertools for Python - GLIDE support in the idempotency feature

For FastAPI, manually create the async client at startup and inject as a dependency. Since GLIDE uses a single multiplexed connection per node, create separate instances only for blocking commands in multi-worker deployments.

No official Django or FastAPI integration exists.

---

## Architecture Notes

- **Async client**: PyO3-based native extension, Unix socket IPC with Rust core
- **Sync client**: CFFI-based FFI calls directly to Rust core via `glide-ffi`
- Single multiplexed connection per node - no connection pool management
- Lazy connections opt-in via `lazy_connect=True` - default connects during `create()`

---

## Gotchas

1. **Bytes everywhere.** No `decode_responses` option. Every string value returns as bytes. Call `.decode()` at every read site or build a thin wrapper.

2. **List arguments.** Commands like `delete`, `exists`, `lpush`, `sadd` take a list, not varargs. Forgetting brackets is the most common first-day mistake.

3. **No connection pool tuning.** Single multiplexed connection per node. Do not create connection pools. Multiple client instances only needed for blocking commands or WATCH isolation.

4. **Async by default.** The primary API is async. The sync wrapper (`glide_sync`) is available from GLIDE 2.1 but async is the recommended path.

5. **Timeout units.** redis-py uses seconds (float). GLIDE uses milliseconds (int). Default is 250ms.

6. **Protobuf dependency.** The async package requires `protobuf>=3.20`, which can conflict with gRPC stubs. Pin versions carefully.

7. **Alpine Linux not supported.** GLIDE requires glibc 2.17+. Use Debian-based container images.

8. **Proxy incompatibility.** GLIDE runs `INFO REPLICATION`, `CLIENT SETINFO`, and `CLIENT SETNAME` during connection setup. Proxies that do not support these commands will fail at connect time.

9. **Trio and anyio.** GLIDE transparently supports asyncio, anyio, and trio as of GLIDE 2.0.1. No special configuration needed.

---

## Cross-References

- `valkey-glide` skill - architecture, connection model, features shared across all languages
- `valkey` skill - Valkey server commands, data types, patterns
