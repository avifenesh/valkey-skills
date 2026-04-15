# Production Deployment

Use when deploying GLIDE Java to production, configuring timeouts, managing connections, or setting up observability.

## Connection Management

### Single Client Per Application

GLIDE multiplexes all requests over one connection per node. Do not create client pools.

```java
// Correct: one client shared across the application
GlideClient client = GlideClient.createClient(config).get();

// Wrong: do not pool GLIDE clients
// List<GlideClient> pool = IntStream.range(0, 10)
//     .mapToObj(i -> GlideClient.createClient(config).join())
//     .collect(toList());
```

### Lazy Connect

Defers connection until the first command. Allows startup when the server is not yet available.

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .lazyConnect(true)
    .build();

GlideClient client = GlideClient.createClient(config).get();
// No connection yet - first command triggers it
```

### Client Cleanup

GlideClient implements `AutoCloseable`. Always close on shutdown:

```java
try (GlideClient client = GlideClient.createClient(config).get()) {
    // use client
}
// or explicitly
client.close();
```

---

## Timeout Configuration

| Timeout | Default | Builder Method |
|---------|---------|---------------|
| Request timeout | 250ms | `.requestTimeout(ms)` |
| Connection timeout | 2000ms | `.advancedConfiguration(AdvancedGlideClientConfiguration.builder().connectionTimeout(ms).build())` |

### Tuning by Workload

| Workload | Recommended Timeout |
|----------|-------------------|
| Cache lookups (GET, HGET) | 250-500ms |
| Write operations (SET, HSET) | 250-500ms |
| Complex operations (SORT, SCAN) | 1000-5000ms |
| Lua scripts (EVALSHA) | 5000-30000ms |
| Blocking commands (BLPOP, XREADGROUP) | Handled automatically |

GLIDE extends blocking command timeouts by 500ms beyond the block duration.

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .requestTimeout(1000)
    .advancedConfiguration(AdvancedGlideClientConfiguration.builder()
        .connectionTimeout(5000)
        .build())
    .build();
```

---

## Cluster Configuration

Provide multiple seed nodes for redundancy. GLIDE discovers the full topology automatically.

### AZ Affinity

Route reads to same-AZ replicas to reduce latency and cross-AZ costs:

```java
GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAZ("us-east-1a")
    .build();
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

```java
import glide.api.OpenTelemetry;
import glide.api.OpenTelemetry.OpenTelemetryConfig;
import glide.api.OpenTelemetry.TracesConfig;
import glide.api.OpenTelemetry.MetricsConfig;

OpenTelemetry.init(OpenTelemetryConfig.builder()
    .traces(TracesConfig.builder()
        .endpoint("http://otel-collector:4317")
        .samplePercentage(1)
        .build())
    .metrics(MetricsConfig.builder()
        .endpoint("http://otel-collector:4317")
        .build())
    .flushIntervalMs(5000L)
    .build());
```

| Environment | Sample Rate |
|-------------|------------|
| Production | 1-2% |
| Staging | 5-10% |
| Debugging | 50-100% |

## Connection Defaults

| Parameter | Default |
|-----------|---------|
| Request timeout | 250ms |
| Connection timeout | 2000ms |
| Inflight request limit | 1000 |
| TCP_NODELAY | true |
| Lazy connect | false |
| Topology check | 60s |
| Protocol | RESP3 |
