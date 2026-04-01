# Production Deployment

Use when deploying GLIDE Go to production, configuring timeouts, managing connections, or setting up observability.

## Contents

- Connection Management (line 15)
- Timeout Configuration (line 62)
- Cluster Configuration (line 93)
- Batch Options in Production (line 130)
- Connection Defaults (line 150)

---

## Connection Management

### Single Client Per Application

GLIDE multiplexes all requests over one connection per node. Do not create client pools.

```go
import (
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

// Correct: one client shared across the application
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})
client, err := glide.NewClient(cfg)
if err != nil {
    panic(err)
}
defer client.Close()

// Wrong: do not pool GLIDE clients
```

### Lazy Connect

Defers connection until the first command. Allows startup when the server is not yet available.

```go
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithLazyConnect(true)

client, err := glide.NewClient(cfg) // Returns immediately
// Connection established on first command
```

### Client Cleanup

Always defer `Close()` after client creation. It drains pending requests with `ClosingError` and is safe to call multiple times.

```go
defer client.Close()
```

---

## Timeout Configuration

| Timeout | Default | Config Method |
|---------|---------|--------------|
| Request timeout | 250ms | `WithRequestTimeout(d time.Duration)` |
| Connection timeout | 2000ms | Advanced config: `WithConnectionTimeout(d time.Duration)` |

### Tuning by Workload

| Workload | Recommended Timeout |
|----------|-------------------|
| Cache lookups (GET, HGET) | 250-500ms |
| Write operations (SET, HSET) | 250-500ms |
| Complex operations (SORT, SCAN) | 1-5s |
| Lua scripts (EVALSHA) | 5-30s |
| Blocking commands (BLPOP, XREADGROUP) | Handled automatically |

GLIDE extends blocking command timeouts by 500ms beyond the block duration.

```go
advanced := config.NewAdvancedClientConfiguration().
    WithConnectionTimeout(5 * time.Second)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithRequestTimeout(1 * time.Second).
    WithAdvancedConfiguration(advanced)
```

---

## Cluster Configuration

### Seed Nodes

Provide multiple seed nodes for redundancy. GLIDE discovers the full topology automatically.

```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node3.example.com", Port: 6379})

client, err := glide.NewClusterClient(cfg)
```

### AZ Affinity

Route reads to same-AZ replicas to reduce latency and cross-AZ costs.

```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithReadFrom(config.AzAffinity).
    WithClientAZ("us-east-1a")
```

| Strategy | Behavior |
|----------|----------|
| `config.Primary` | All reads to primary (default) |
| `config.PreferReplica` | Round-robin replicas, fallback to primary |
| `config.AzAffinity` | Prefer same-AZ replicas |
| `config.AzAffinityReplicaAndPrimary` | Same-AZ replicas, then primary, then remote |

Requires Valkey 8.0+ with `availability-zone` configured on each server node.

---

## Batch Options in Production

Use `ExecWithOptions` to set timeouts and retry strategies for batches:

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

opts := pipeline.NewClusterBatchOptions().
    WithTimeout(5 * time.Second).
    WithRetryStrategy(*pipeline.NewClusterBatchRetryStrategy().
        WithRetryServerError(true).
        WithRetryConnectionError(true))

results, err := clusterClient.ExecWithOptions(ctx, *pipe, false, *opts)
```

Retry strategies are only supported for non-atomic batches.

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
