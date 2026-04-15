# Production Deployment

Use when deploying GLIDE Node.js to production, configuring timeouts, managing connections, or setting up observability.

## Connection Management

### Single Client Per Application

GLIDE multiplexes all requests over one connection per node. Do not create client pools.

```typescript
// Correct: one client shared across the application
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
});

// Wrong: do not pool GLIDE clients
// const clients = await Promise.all(Array(10).fill(null).map(() => GlideClient.createClient(config)));
```

### Lazy Connect

Defers connection until the first command. Allows startup when the server is not yet available.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    lazyConnect: true,
});
// No connection yet - first command triggers it
await client.ping();
```

### Client Cleanup

Always close clients on shutdown. Pending promises are rejected with `ClosingError`.

```typescript
client.close();
client.close("Shutting down gracefully"); // custom error message
```

---

## Timeout Configuration

| Timeout | Default | Config Property |
|---------|---------|----------------|
| Request timeout | 250ms | `requestTimeout` |
| Connection timeout | 2000ms | `advancedConfiguration.connectionTimeout` |

### Tuning by Workload

| Workload | Recommended Timeout |
|----------|-------------------|
| Cache lookups (GET, HGET) | 250-500ms |
| Write operations (SET, HSET) | 250-500ms |
| Complex operations (SORT, SCAN) | 1000-5000ms |
| Lua scripts (EVALSHA) | 5000-30000ms |
| Blocking commands (BLPOP, XREADGROUP) | Handled automatically |

GLIDE extends blocking command timeouts by 500ms beyond the block duration.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 1000,
    advancedConfiguration: { connectionTimeout: 5000 },
});
```

---

## Cluster Configuration

Provide multiple seed nodes for redundancy. GLIDE discovers the full topology automatically.

### AZ Affinity

Route reads to same-AZ replicas to reduce latency and cross-AZ costs:

```typescript
const client = await GlideClusterClient.createClient({
    addresses: [{ host: "node1.example.com", port: 6379 }],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",
});
```

| Strategy | Behavior |
|----------|----------|
| `"primary"` | All reads to primary (default) |
| `"preferReplica"` | Round-robin replicas, fallback to primary |
| `"AZAffinity"` | Prefer same-AZ replicas |
| `"AZAffinityReplicasAndPrimary"` | Same-AZ replicas, then primary, then remote |

Requires Valkey 8.0+ with `availability-zone` configured on each server node.

---

## OpenTelemetry

OTel is initialized globally before creating any clients:

```typescript
import { OpenTelemetry } from "@valkey/valkey-glide";

OpenTelemetry.init({
    traces: {
        endpoint: "http://otel-collector:4317",
        samplePercentage: 1,  // 1% for production
    },
    metrics: {
        endpoint: "http://otel-collector:4317",
    },
    flushIntervalMs: 5000,
});
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
