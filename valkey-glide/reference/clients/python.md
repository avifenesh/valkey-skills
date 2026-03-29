# Python Client

Use when building Python applications with Valkey GLIDE - async (asyncio) and sync APIs for standalone and cluster modes.

## Installation

```bash
pip install valkey-glide
```

**Requirements:** Python 3.9 - 3.14

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64). No Windows support. No Alpine/MUSL support.

The package ships separate async and sync modules:
- `glide` - async API (asyncio, anyio, trio)
- `glide_sync` - sync API (GLIDE 2.1+)

---

## Client Classes

| Class | Module | Mode | Description |
|-------|--------|------|-------------|
| `GlideClient` | `glide` / `glide_sync` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | `glide` / `glide_sync` | Cluster | Valkey Cluster with auto-topology |

Both are created via the `create()` class method and accept a configuration object.

---

## Async API

### Standalone Connection

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

### Cluster Connection

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

---

## Sync API (GLIDE 2.1+)

The sync module mirrors the async API but blocks on each call. Import from `glide_sync` instead of `glide`.

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

## Configuration

### GlideClientConfiguration

For standalone mode. Inherits from `BaseClientConfiguration`.

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

### GlideClusterClientConfiguration

For cluster mode. Adds `periodic_checks` for topology refresh control.

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

## Configuration Details

### NodeAddress

```python
class NodeAddress:
    def __init__(self, host: str = "localhost", port: int = 6379)
```

### ServerCredentials

Supports password-based or IAM authentication (mutually exclusive). See `features/tls-auth.md` for TLS and authentication details.

```python
# Password-based
creds = ServerCredentials(password="secret")
creds = ServerCredentials(username="myuser", password="secret")

# IAM (requires username)
from glide import IamAuthConfig, ServiceType
iam = IamAuthConfig(
    cluster_name="my-cluster",
    service=ServiceType.ELASTICACHE,
    region="us-east-1",
)
creds = ServerCredentials(username="myuser", iam_config=iam)
```

### BackoffStrategy

Exponential backoff with jitter for reconnection.

```python
class BackoffStrategy:
    def __init__(
        self,
        num_of_retries: int,
        factor: int,            # milliseconds
        exponent_base: int,
        jitter_percent: Optional[int] = None,
    )
```

Formula: `factor * (exponent_base ^ N)` where N is the attempt number, with optional `jitter_percent` as a percentage of the computed duration. See [connection-model](../architecture/connection-model.md) for full retry strategy details.

### ReadFrom

| Value | Behavior |
|-------|----------|
| `ReadFrom.PRIMARY` | All reads to primary (default) |
| `ReadFrom.PREFER_REPLICA` | Round-robin replicas, fallback to primary |
| `ReadFrom.AZ_AFFINITY` | Prefer same-AZ replicas (requires `client_az`) |
| `ReadFrom.AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then same-AZ primary, then remote |

AZ Affinity strategies require Valkey 8.0+ and `client_az` must be set. See `features/az-affinity.md` for detailed AZ routing behavior.

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
| `ConfigurationError` | Invalid client configuration |
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

Note: Import as `GlideTimeoutError` / `GlideConnectionError` to avoid shadowing Python builtins.

---

## Return Types

- String commands return `bytes` (decode with `.decode()`)
- `GET` returns `Optional[bytes]` - `None` when key does not exist
- Numeric commands return `int` or `float`
- `SET` returns `Optional[str]` - `"OK"` on success

---

## Architecture Notes

- **Async client**: PyO3-based native extension communicating over Unix socket IPC with the Rust core
- **Sync client**: CFFI-based FFI calls directly to the Rust core via `glide-ffi`
- Single multiplexed connection per node - no connection pool management needed
- Lazy connections are opt-in via `lazy_connect=True` - by default the client connects immediately during `create()`

---

## Ecosystem Integrations

No official Django or FastAPI integration exists. Third-party integrations:
- `aiocache` - GLIDE backend support for async caching
- AWS Lambda Powertools for Python - GLIDE support in the idempotency feature

For FastAPI, manually create the async client at startup and inject it as a dependency. Since GLIDE uses a single multiplexed connection per node (no connection pool), create separate client instances for blocking commands in multi-worker deployments.
