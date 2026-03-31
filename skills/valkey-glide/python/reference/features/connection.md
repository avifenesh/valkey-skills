# Connection and Configuration

Use when creating GLIDE client instances, configuring addresses, authentication, TLS, reconnection, protocol version, compression, AZ affinity, or managing connection lifecycle.

## Client Types

| Client | Class | Config Class | Use Case |
|--------|-------|-------------|----------|
| Standalone | `GlideClient` | `GlideClientConfiguration` | Single node or read replicas |
| Cluster | `GlideClusterClient` | `GlideClusterClientConfiguration` | Cluster mode with slot-based routing |

Both clients are created via the async `create()` classmethod and closed via `close()`.

## Standalone Client

```python
import asyncio
from glide import (
    GlideClient, GlideClientConfiguration, NodeAddress,
    ServerCredentials, BackoffStrategy, ReadFrom, ProtocolVersion,
)

async def main():
    config = GlideClientConfiguration(
        addresses=[
            NodeAddress("localhost", 6379),
            NodeAddress("replica1.example.com", 6379),
        ],
        use_tls=False,
        credentials=ServerCredentials(password="secretpass"),
        read_from=ReadFrom.PREFER_REPLICA,
        request_timeout=500,          # ms
        reconnect_strategy=BackoffStrategy(
            num_of_retries=5, factor=100, exponent_base=2,
            jitter_percent=20,  # optional, adds randomness to retry intervals
        ),
        database_id=0,
        client_name="my-app",
        protocol=ProtocolVersion.RESP3,
    )
    client = await GlideClient.create(config)
    await client.set("key", "value")
    await client.close()

asyncio.run(main())
```

## Cluster Client

```python
from glide import (
    GlideClusterClient, GlideClusterClientConfiguration, NodeAddress,
    PeriodicChecksManualInterval, ServerCredentials, BackoffStrategy,
)

config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("cluster-node-1.example.com", 6379)],
    use_tls=True,
    credentials=ServerCredentials(username="admin", password="secret"),
    periodic_checks=PeriodicChecksManualInterval(duration_in_sec=30),
    reconnect_strategy=BackoffStrategy(
        num_of_retries=5, factor=1000, exponent_base=2,
    ),
)
client = await GlideClusterClient.create(config)
```

Seed addresses can be partial - the client discovers the full cluster topology automatically.

## TLS and mTLS

```python
from glide import TlsAdvancedConfiguration, AdvancedGlideClientConfiguration

# Basic TLS
config = GlideClientConfiguration(
    addresses=[NodeAddress("host", 6380)],
    use_tls=True,
)

# mTLS with custom CA
with open("/path/to/ca-cert.pem", "rb") as f:
    ca_cert = f.read()
with open("/path/to/client-cert.pem", "rb") as f:
    client_cert = f.read()
with open("/path/to/client-key.pem", "rb") as f:
    client_key = f.read()

tls_config = TlsAdvancedConfiguration(
    root_pem_cacerts=ca_cert,
    client_cert_pem=client_cert,
    client_key_pem=client_key,
)
advanced = AdvancedGlideClientConfiguration(
    connection_timeout=5000,  # ms
    tls_config=tls_config,
    tcp_nodelay=True,         # disable Nagle's algorithm (default: True)
)
config = GlideClientConfiguration(
    addresses=[NodeAddress("host", 6380)],
    use_tls=True,
    advanced_config=advanced,
)
```

For self-signed certs in dev, set `use_insecure_tls=True` on `TlsAdvancedConfiguration`.

For cluster clients, use `AdvancedGlideClusterClientConfiguration` which adds `refresh_topology_from_initial_nodes`:

```python
from glide import AdvancedGlideClusterClientConfiguration

advanced = AdvancedGlideClusterClientConfiguration(
    connection_timeout=5000,
    tls_config=tls_config,
    refresh_topology_from_initial_nodes=True,  # only use seed nodes for topology
)
```

## Authentication

```python
# Password-only
creds = ServerCredentials(password="my-password")

# Username + password (ACL)
creds = ServerCredentials(username="app-user", password="my-password")

# IAM authentication (AWS ElastiCache / MemoryDB)
from glide import IamAuthConfig, ServiceType
iam = IamAuthConfig(
    cluster_name="my-cluster",
    service=ServiceType.ELASTICACHE,
    region="us-east-1",
    refresh_interval_seconds=300,
)
creds = ServerCredentials(username="iam-user", iam_config=iam)
```

Password and IAM are mutually exclusive. IAM requires a username.

## Runtime Password Update

```python
# Update stored password for future reconnections (no immediate AUTH)
await client.update_connection_password("new-password")

# Update and immediately re-authenticate all connections
await client.update_connection_password("new-password", immediate_auth=True)

# Remove stored password
await client.update_connection_password(None)
```

## IAM Token Refresh

```python
# Manually refresh IAM token (only for clients created with IAM auth)
await client.refresh_iam_token()
```

## Compression

```python
from glide import CompressionConfiguration, CompressionBackend

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    compression=CompressionConfiguration(
        enabled=True,
        backend=CompressionBackend.LZ4,   # or ZSTD (default)
        compression_level=3,               # backend-specific
        min_compression_size=64,           # bytes, minimum threshold
    ),
)
```

Compression is transparent - set-type commands compress automatically, get-type commands decompress.

## AZ Affinity

```python
config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("host", 6379)],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
)
```

`AZ_AFFINITY` routes reads to same-AZ replicas first. `AZ_AFFINITY_REPLICAS_AND_PRIMARY` includes the local primary in the rotation. Both require `client_az` to be set.

## Lazy Connect

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    lazy_connect=True,   # defer connection until first command
)
```

The first command pays the connection establishment cost. Governed by `connection_timeout`, not `request_timeout`.

## Connection Statistics

```python
stats = await client.get_statistics()
# Returns dict with int values:
#   total_connections, total_clients, total_values_compressed,
#   total_values_decompressed, total_original_bytes,
#   total_bytes_compressed, total_bytes_decompressed,
#   compression_skipped_count, subscription_out_of_sync_count,
#   subscription_last_sync_timestamp (ms since epoch)
```

## Graceful Shutdown

```python
await client.close()
# Optional: pass an error message for in-flight futures
await client.close("shutting down")
```

All pending futures receive a `ClosingError` with the provided message.
