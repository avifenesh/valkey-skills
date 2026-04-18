# Production deployment

Use when deploying GLIDE Python to production. Covers GLIDE-specific defaults and the pitfalls that matter for operators. For basic setup examples see [features-connection](features-connection.md).

## One client per process

Do not pool `GlideClient` / `GlideClusterClient`. The multiplexer is the pool. Creating N clients opens N sets of TCP connections to every node and defeats the connection-state tracking the core does.

Use `lazy_connect=True` if your app must start before Valkey is reachable - the first command pays the connection cost.

Always `await client.close()` on shutdown; pending futures get `ClosingError`.

## GLIDE defaults agents should know

| Knob | Default | Config |
|------|---------|--------|
| Request timeout | 250 ms | `request_timeout` |
| Connection timeout | 2000 ms | `AdvancedGlideClientConfiguration.connection_timeout` |
| Inflight request cap | 1000 | `inflight_requests_limit` |
| Topology check interval (cluster) | 60 s | `periodic_checks=PeriodicChecksManualInterval(...)` |
| Backoff retries | (infinite; cap only on sequence length) | `reconnect_strategy` |
| Protocol | RESP3 | `protocol=ProtocolVersion.RESP2` to downgrade |
| TCP_NODELAY | True | `AdvancedGlideClientConfiguration.tcp_nodelay` |

GLIDE also extends the effective request timeout for blocking commands (BLPOP, XREADGROUP BLOCK, etc.) by 0.5 s beyond the block duration - no tuning required.

## Timeout tuning

The 250 ms default is tight. Raise per-workload, not globally:

| Workload | Recommended |
|----------|-------------|
| Cache lookup (GET, HGET) | 250-500 ms |
| Writes (SET, HSET, ZADD) | 250-500 ms |
| Complex (SORT, SCAN, ZRANGEBYSCORE large) | 1-5 s |
| Lua scripts | 5-30 s |
| Blocking commands | Auto-extended - do not raise |

## Cluster: seed nodes and AZ affinity

Provide multiple seed addresses for redundancy. Topology is auto-discovered.

`ReadFrom` strategies (in `glide_shared.config.ReadFrom`):

| Strategy | Behavior |
|----------|----------|
| `PRIMARY` | All reads to primary (default) |
| `PREFER_REPLICA` | Round-robin replicas, fall back to primary |
| `AZ_AFFINITY` | Same-AZ replicas preferred, then other replicas, then primary |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then same-AZ primary, then any replica, then primary |

AZ-affinity strategies require `client_az` to be set AND the server exposing availability-zone metadata in CLUSTER SHARDS - otherwise falls back to primary.

## OpenTelemetry

Initialize once, globally, before creating clients (subsequent `init()` calls are ignored):

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
    metrics=OpenTelemetryMetricsConfig(endpoint="http://otel-collector:4317"),
    flush_interval_ms=5000,
))

# Runtime adjustments
OpenTelemetry.set_sample_percentage(10)
OpenTelemetry.is_initialized()
```

Rough sampling rates: 1-2% prod, 5-10% staging, 50-100% debugging.

## Platform constraints

- **glibc 2.17+** required. Alpine (musl) is NOT supported - use Debian/Ubuntu-based images.
- **Protobuf**: the `protobuf` Python package must be ≥ 3.20. Conflicts with other packages pinning older protobuf will surface as import errors on client creation.
- **Proxies / connection inspectors**: GLIDE sends `CLIENT SETNAME`, `CLIENT SETINFO`, `INFO REPLICATION` during setup. Transparent proxies that strip or rewrite these will break topology detection.
- **Protocol**: RESP3 is the default. RESP2 is accepted but PubSub static subscriptions require RESP3 and raise `ConfigurationError` otherwise.
