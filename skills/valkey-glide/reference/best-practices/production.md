# Production Deployment

Use when deploying GLIDE to production, configuring timeouts, managing connections, setting up observability, or planning cluster topology. For throughput optimization and batching, see `performance.md`. For error recovery and reconnection details, see `error-handling.md`.

---

## Connection Management

### Single Client Per Application

GLIDE multiplexes all requests over a single connection per node. Do not create connection pools. A single `GlideClient` or `GlideClusterClient` instance is sufficient for the entire application.

```python
# Correct: one client, shared across the application
client = await GlideClient.create(config)

# Wrong: do not create pools of GLIDE clients
# pool = [await GlideClient.create(config) for _ in range(10)]
```

### When to Create Additional Clients

Create separate client instances only for:

| Use Case | Reason |
|----------|--------|
| Blocking commands (BLPOP, BRPOP, BLMOVE, XREADGROUP BLOCK) | These occupy the connection for the duration of the block |
| WATCH/UNWATCH (optimistic locking) | Requires connection-level isolation |
| Large value transfers (multi-MB values) | Prevents head-of-line blocking for other operations |
| PubSub subscribers | Dedicated listener - cannot share with command traffic |

### Lazy Connections (Opt-In)

GLIDE connects eagerly by default (`lazy_connect` defaults to `false`). You can opt in to lazy connection establishment - deferring connection until the first command - by setting `lazy_connect` to `true`. This reduces startup latency and avoids connection errors during application initialization when the server may not be ready.

```python
# Python: enable lazy connection
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    lazy_connect=True,
)
client = await GlideClient.create(config)  # Returns immediately, connects on first command
```

```java
// Java: enable lazy connection
config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .lazyConnect(true)
    .build();
client = GlideClient.createClient(config).get();  // Returns immediately, connects on first command
```

### Client Cleanup

Always close clients when your application shuts down. This releases connections and background threads.

```python
await client.close()
```

```java
client.close();  // GlideClient implements AutoCloseable
```

```javascript
client.close();
```

```go
client.Close()
```

---

## Timeout Configuration

### Defaults from Source

| Timeout | Default | Source Location |
|---------|---------|----------------|
| Request timeout | 250ms | `DEFAULT_RESPONSE_TIMEOUT` in `glide-core/src/client/mod.rs` |
| Connection timeout | 2000ms | `DEFAULT_CONNECTION_TIMEOUT` in `glide-core/src/client/types.rs` |
| Connection check interval | 3s | `CONNECTION_CHECKS_INTERVAL` in `glide-core/src/client/mod.rs` |
| Heartbeat interval | 1s | `HEARTBEAT_SLEEP_DURATION` in `glide-core/src/client/mod.rs` |
| Topology check interval | 60s | `DEFAULT_PERIODIC_TOPOLOGY_CHECKS_INTERVAL` in `glide-core/src/client/mod.rs` |

### Timeout Tuning by Workload

| Workload Type | Recommended Timeout | Reasoning |
|--------------|-------------------|-----------|
| Cache lookups (GET, HGET) | 250-500ms | Fast operations; default is usually sufficient |
| Write operations (SET, HSET) | 250-500ms | Similar to reads unless persistence is slow |
| Complex operations (SORT, SCAN, SINTERSTORE) | 1000-5000ms | Server-side computation time varies |
| Lua scripts (EVALSHA) | 5000-30000ms | Script complexity varies widely |
| Blocking commands (BLPOP, XREADGROUP BLOCK) | Handled automatically | GLIDE extends timeout by 500ms beyond the block duration |

The request timeout covers the full cycle: sending the command, waiting for response, and any internal reconnection attempts.

### Blocking Command Timeout Extension

GLIDE automatically detects blocking commands and extends the request timeout. The extension is 0.5 seconds beyond the specified block time (`BLOCKING_CMD_TIMEOUT_EXTENSION` in `glide-core/src/client/mod.rs`). This prevents the client from timing out before the server responds to the block.

```python
# BLPOP with 5-second block: GLIDE sets request timeout to 5.5s
result = await client.blpop(["queue"], timeout=5.0)
```

---

## Connection Sizing

GLIDE creates 2 connections per client per node (1 data plane + 1 management/topology). Plan connection budgets accordingly for large clusters:

| Cluster Size | Clients/App | Apps | Total Connections |
|-------------|-------------|------|-------------------|
| 3 shards (6 nodes) | 1 | 10 | 120 |
| 10 shards (20 nodes) | 1 | 50 | 2,000 |
| 25 shards (50 nodes) | 2 | 100 | 20,000 |

### ElastiCache Serverless

The default connection timeout is 2000ms. For ElastiCache Serverless endpoints with higher initial connection latency, consider setting `connectionTimeout: 5000` (or higher) to account for cold-start delays.

---

## Cloud Deployment Tips

- **ECS/Fargate**: Set `lazyConnect(false)` to fail fast on startup rather than on first request. Account for 2 connections per client per node when sizing.
- **EKS**: Production-validated at 9 pods x 60 threads. Use `ReadFrom.PREFER_REPLICA` to distribute read load.
- **Lambda**: Keep functions warm, use provisioned concurrency for latency-sensitive workloads. Always test with actual Lambda deployment - behavior can differ from local/Docker.

---

## Cluster Mode Configuration

### Seed Nodes

Provide multiple seed nodes for redundancy. If the first node is unreachable during initial connection, GLIDE tries the next one.

```python
config = GlideClusterClientConfiguration(
    addresses=[
        NodeAddress("node1.example.com", 6379),
        NodeAddress("node2.example.com", 6379),
        NodeAddress("node3.example.com", 6379),
    ],
)
```

After initial connection, GLIDE discovers the full topology automatically. Seed nodes are only used for bootstrapping.

### Hash Tags for Slot Co-location

Use hash tags to ensure related keys land on the same slot. This is required for atomic batches (transactions) in cluster mode and helps with multi-key operations.

```python
# These three keys hash to the same slot based on {user:1}
await client.set("{user:1}:name", "Alice")
await client.set("{user:1}:email", "alice@example.com")
await client.set("{user:1}:prefs", '{"theme":"dark"}')

# This transaction works in cluster mode because all keys share a slot
tx = ClusterBatch(is_atomic=True)
tx.get("{user:1}:name")
tx.get("{user:1}:email")
result = await client.exec(tx)
```

### Topology Refresh

GLIDE runs periodic topology checks every 60 seconds by default. You can adjust or disable this:

```python
from glide import PeriodicChecksManualInterval, PeriodicChecksStatus

# Custom interval (in seconds)
config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("node1.example.com", 6379)],
    periodic_checks=PeriodicChecksManualInterval(duration_in_sec=30),
)

# Disable periodic checks (not recommended for production)
config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("node1.example.com", 6379)],
    periodic_checks=PeriodicChecksStatus.DISABLED,
)
```

Even with periodic checks disabled, GLIDE still responds to MOVED/ASK redirections reactively.

---

## AZ Affinity for Read-Heavy Workloads

AZ Affinity routes read commands to replicas in the same availability zone as the client. This reduces latency by roughly 500us and avoids cross-AZ data transfer charges.

### Configuration

```python
config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("node1.example.com", 6379)],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
)
```

### Read Strategy Options

| Strategy | Behavior |
|----------|----------|
| `PRIMARY` | All reads to primary (default) |
| `PREFER_REPLICA` | Round-robin across replicas, fallback to primary |
| `AZ_AFFINITY` | Prefer replicas in the client's AZ |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Prefer local AZ replicas, then local AZ primary, then remote |

### Requirements

- Valkey 8.0+ (server must support `availability-zone` config)
- Each server node configured with its AZ: `CONFIG SET availability-zone us-east-1a`
- Client configured with its own AZ via `client_az`

### Cost Impact

For a two-shard cluster processing 250MB/s of reads, AZ Affinity can reduce monthly cross-AZ costs from approximately $4,373 to $1,088 - a 75% reduction.

---

## OpenTelemetry in Production

### Defaults from Source

| Setting | Default | Source |
|---------|---------|--------|
| Trace sample percentage | 1% | `DEFAULT_TRACE_SAMPLE_PERCENTAGE` in `telemetry/src/open_telemetry.rs` |
| Flush interval | 5000ms | `DEFAULT_FLUSH_SIGNAL_INTERVAL_MS` in `telemetry/src/open_telemetry.rs` |

### Production Configuration

OTel is initialized globally via `OpenTelemetry.init()`, not as a parameter to client configuration:

```python
from glide import (
    OpenTelemetry,
    OpenTelemetryConfig,
    OpenTelemetryTracesConfig,
    OpenTelemetryMetricsConfig,
    GlideClientConfiguration,
    NodeAddress,
)

# Initialize OpenTelemetry globally before creating any clients
OpenTelemetry.init(OpenTelemetryConfig(
    traces=OpenTelemetryTracesConfig(
        endpoint="http://otel-collector:4317",
        sample_percentage=1,  # 1% for production, up to 5% for debugging
    ),
    metrics=OpenTelemetryMetricsConfig(
        endpoint="http://otel-collector:4317",
    ),
    flush_interval_ms=5000,
))

# Then create the client normally - OTel is active globally
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
)
```

### Sampling Recommendations

| Environment | Sample Rate | Reasoning |
|-------------|------------|-----------|
| Production | 1-2% | Minimal overhead, sufficient for trend analysis |
| Staging | 5-10% | More detail for pre-production validation |
| Debugging | 50-100% | Full visibility, significant overhead |

### What You Get

Each traced command produces:
- A parent span for the GLIDE command
- A child `send_command` span measuring server communication time
- Status fields (OK/Error) on each span
- Metrics: request timeouts, retry counts, MOVED errors

Limitations: SCAN family commands and Lua scripting commands are not yet included in tracing.

### Export Options

- **gRPC** (recommended for production): `http://collector:4317`
- **HTTP**: `http://collector:4318`
- **File** (development only): `file:///path/to/traces.json`

---

## Platform Support Matrix

| Platform | Python | Java | Node.js | Go | PHP | C# |
|----------|--------|------|---------|----|-----|-----|
| Ubuntu 20+ (x86_64) | Y | Y | Y | Y | Y | Y |
| Ubuntu 20+ (arm64) | Y | Y | Y | Y | Y | Y |
| Amazon Linux 2/2023 | Y | Y | Y | Y | Y | Y |
| macOS 14.7 (Apple Silicon) | Y | Y | Y | Y | Y | Y |
| macOS 13.7 (x86_64) | Y | Y | Y | Y | Y | Y |
| Windows (x86_64) | - | Y | - | - | - | - |
| Alpine Linux | - | Y | - | Y | - | - |

Windows support is currently Java-only. Alpine/MUSL support is limited to Java and Go.

---

## Connection Defaults Summary

All verified against `glide-core` source:

| Parameter | Default | Configurable |
|-----------|---------|-------------|
| Request timeout | 250ms | Yes (`request_timeout`) |
| Connection timeout | 2000ms | Yes (`connection_timeout`) |
| Inflight request limit | 1000 | Yes (`inflight_requests_limit`) |
| TCP_NODELAY | true | Yes (`tcp_nodelay`) |
| Lazy connect | false | Yes (`lazy_connect`) |
| Topology check interval | 60s | Yes (`periodic_checks`) |
| Connection check interval | 3s | No (hardcoded) |
| Heartbeat interval | 1s | No (hardcoded) |
| Default retries | 3 (cluster client routing retries, not backoff strategy retries) | Via `connection_retry_strategy` |
| Default port | 6379 | Yes (per `NodeAddress`) |
| TLS mode | NoTls | Yes (`tls_mode`) |
| Read from | Primary | Yes (`read_from`) |
| RESP protocol | RESP3 | Yes (`protocol` - RESP2 or RESP3) |
