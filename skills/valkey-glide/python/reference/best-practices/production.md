# Production Deployment

Use when deploying GLIDE Python to production, configuring timeouts, managing connections, or setting up observability.

---

## Connection Management

### Single Client Per Application

GLIDE multiplexes all requests over one connection per node. Do not create client pools.

```python
from glide import GlideClient, GlideClientConfiguration, NodeAddress

# Correct: one client shared across the application
config = GlideClientConfiguration(addresses=[NodeAddress("localhost", 6379)])
client = await GlideClient.create(config)

# Wrong: do not pool GLIDE clients
# pool = [await GlideClient.create(config) for _ in range(10)]
```

### Lazy Connect

Defer connection until the first command. Useful when the server may not be ready at startup.

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    lazy_connect=True,
)
client = await GlideClient.create(config)
# No connection yet - first command triggers it
```

### Client Cleanup

Always close clients on shutdown. Pending futures receive `ClosingError`.

```python
await client.close()
await client.close("shutting down")  # custom error message
```

---

## Timeout Configuration

| Timeout | Default | Config Parameter |
|---------|---------|-----------------|
| Request timeout | 250ms | `request_timeout` |
| Connection timeout | 2000ms | `AdvancedGlideClientConfiguration(connection_timeout=ms)` |

### Tuning by Workload

| Workload | Recommended Timeout |
|----------|-------------------|
| Cache lookups (GET, HGET) | 250-500ms |
| Write operations (SET, HSET) | 250-500ms |
| Complex operations (SORT, SCAN) | 1000-5000ms |
| Lua scripts (EVALSHA) | 5000-30000ms |
| Blocking commands (BLPOP, XREADGROUP) | Handled automatically |

GLIDE extends blocking command timeouts by 500ms beyond the block duration.

```python
from glide import AdvancedGlideClientConfiguration

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    request_timeout=1000,
    advanced_config=AdvancedGlideClientConfiguration(connection_timeout=5000),
)
```

---

## Cluster Configuration

Provide multiple seed nodes for redundancy. GLIDE discovers the full topology automatically.

### AZ Affinity

Route reads to same-AZ replicas to reduce latency and cross-AZ costs:

```python
from glide import GlideClusterClientConfiguration, NodeAddress, ReadFrom

config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("node1.example.com", 6379)],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
)
```

| Strategy | Behavior |
|----------|----------|
| `PRIMARY` | All reads to primary (default) |
| `PREFER_REPLICA` | Round-robin replicas, fallback to primary |
| `AZ_AFFINITY` | Prefer same-AZ replicas |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then primary, then remote |

Requires Valkey 8.0+ with `availability-zone` configured on each server node.

---

## OpenTelemetry

OTel is initialized globally before creating any clients:

```python
from glide import (
    OpenTelemetry, OpenTelemetryConfig,
    OpenTelemetryTracesConfig, OpenTelemetryMetricsConfig,
)

OpenTelemetry.init(OpenTelemetryConfig(
    traces=OpenTelemetryTracesConfig(
        endpoint="http://otel-collector:4317",
        sample_percentage=1,
    ),
    metrics=OpenTelemetryMetricsConfig(
        endpoint="http://otel-collector:4317",
    ),
    flush_interval_ms=5000,
))
```

| Environment | Sample Rate |
|-------------|------------|
| Production | 1-2% |
| Staging | 5-10% |
| Debugging | 50-100% |

---

## Connection Defaults

| Parameter | Default |
|-----------|---------|
| Request timeout | 250ms |
| Connection timeout | 2000ms |
| Inflight request limit | 1000 |
| Connections per node | 2 (data + management) |
| Topology check | 60s |
| Protocol | RESP3 |
