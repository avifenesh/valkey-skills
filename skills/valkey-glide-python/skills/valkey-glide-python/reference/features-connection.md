# Connection and Configuration

Use when creating GLIDE client instances, configuring addresses, authentication, TLS, reconnection, protocol version, compression, AZ affinity, or managing connection lifecycle. Covers what differs from `redis-py` / `RedisCluster` - skip the basics, they work as expected.

## Divergence from redis-py

| redis-py | GLIDE Python |
|----------|--------------|
| `redis.Redis(host, port, ...)` | `await GlideClient.create(config)` - async classmethod |
| `redis.asyncio.Redis(...)` / `redis.RedisCluster(...)` | `GlideClient` / `GlideClusterClient` (separate types, not wrappers) |
| Connection pool with `max_connections` | Single multiplexed connection per node - no pool knob |
| Per-task client OK | One client shared across all coroutines in the process (multiplexer) |
| Blocking commands share the pool | Blocking commands (BLPOP, BRPOP, BZPOPMAX, WATCH/MULTI/EXEC) occupy the single connection - use a dedicated client for them |
| `decode_responses=True` | No equivalent - always `bytes`; call `.decode()` or use `str` arg overloads where typed |
| `socket_timeout` seconds | `request_timeout` milliseconds |
| `retry_on_timeout=True` | `reconnect_strategy=BackoffStrategy(...)` |

## Client types

| Client | Class | Config |
|--------|-------|--------|
| Standalone / primary + replicas | `GlideClient` | `GlideClientConfiguration` |
| Cluster | `GlideClusterClient` | `GlideClusterClientConfiguration` |

Both are GLIDE's own code; neither wraps the other. Create via `await ClientClass.create(config)`, close via `await client.close()`. Seed addresses can be partial - topology is discovered.

## Authentication

```python
from glide import ServerCredentials, IamAuthConfig, ServiceType

# Password or username+password (ACL)
creds = ServerCredentials(password="pw")
creds = ServerCredentials(username="user", password="pw")

# IAM (ElastiCache / MemoryDB) - GLIDE-only, no redis-py equivalent
creds = ServerCredentials(
    username="iam-user",
    iam_config=IamAuthConfig(
        cluster_name="my-cluster",
        service=ServiceType.ELASTICACHE,  # or ServiceType.MEMORYDB
        region="us-east-1",
        refresh_interval_seconds=300,  # optional
    ),
)
```

Password and IAM are mutually exclusive on a single `ServerCredentials`. IAM requires a username.

### Runtime updates

```python
await client.update_connection_password("new-pw")                   # stored, used on next reconnect
await client.update_connection_password("new-pw", immediate_auth=True)  # re-AUTH now
await client.update_connection_password(None)                       # clear stored password
await client.refresh_iam_token()                                    # force IAM token refresh
```

## TLS / mTLS

Basic TLS is just `use_tls=True`. Everything else (client cert, insecure dev mode, custom CA) goes through `TlsAdvancedConfiguration` + `AdvancedGlideClientConfiguration`:

```python
from glide import (
    TlsAdvancedConfiguration, AdvancedGlideClientConfiguration,
    AdvancedGlideClusterClientConfiguration,
)

tls = TlsAdvancedConfiguration(
    root_pem_cacerts=ca_bytes,
    client_cert_pem=cert_bytes,
    client_key_pem=key_bytes,
    use_insecure_tls=False,  # True to bypass verification (dev only)
)
advanced = AdvancedGlideClientConfiguration(
    connection_timeout=5000,  # ms; default 2000
    tls_config=tls,
    tcp_nodelay=True,         # default True; disable Nagle
    pubsub_reconciliation_interval=None,  # ms; sets PubSub reconciliation cadence
)
```

`AdvancedGlideClusterClientConfiguration` adds `refresh_topology_from_initial_nodes: bool = False` - when `True`, only seed nodes are used for periodic topology refresh.

## GLIDE-only features

### AZ affinity

```python
from glide import ReadFrom

GlideClusterClientConfiguration(
    addresses=[...],
    read_from=ReadFrom.AZ_AFFINITY,             # or AZ_AFFINITY_REPLICAS_AND_PRIMARY
    client_az="us-east-1a",                      # REQUIRED when AZ_AFFINITY*
)
```

Raises `ConfigurationError` if `client_az` is missing on an AZ-affinity strategy.

### Lazy connect

```python
GlideClientConfiguration(addresses=[...], lazy_connect=True)
```

Connection establishment deferred until the first command. That first command pays connection-timeout cost, not request-timeout.

### Compression

Transparent value compression, driven by the Rust core:

```python
from glide import CompressionConfiguration, CompressionBackend

CompressionConfiguration(
    enabled=False,                          # default False
    backend=CompressionBackend.ZSTD,        # or CompressionBackend.LZ4
    compression_level=None,                  # backend default if None; core validates range
    min_compression_size=64,                 # bytes; below this, no compression
)
```

### BackoffStrategy

```python
from glide import BackoffStrategy

BackoffStrategy(
    num_of_retries=5,
    factor=100,
    exponent_base=2,
    jitter_percent=20,  # Optional; default used if not set
)
```

Reconnection retries are **infinite** regardless of `num_of_retries` - `num_of_retries` only caps the backoff sequence length before the max interval plateaus. Client will keep reconnecting until close.

## Connection statistics

```python
stats = await client.get_statistics()
# dict[str, str] - all values are stringified counters/timestamps
# Keys:
#   total_connections, total_clients,
#   total_values_compressed, total_values_decompressed,
#   total_original_bytes, total_bytes_compressed, total_bytes_decompressed,
#   compression_skipped_count,
#   subscription_out_of_sync_count, subscription_last_sync_timestamp   # ms since epoch
```

## Graceful shutdown

```python
await client.close()                # in-flight futures get ClosingError
await client.close("draining")     # optional message stored on the error
```

## Periodic topology checks (cluster)

```python
from glide import PeriodicChecksManualInterval, PeriodicChecksStatus

GlideClusterClientConfiguration(
    addresses=[...],
    periodic_checks=PeriodicChecksManualInterval(duration_in_sec=30),  # override default 60s
)
```
