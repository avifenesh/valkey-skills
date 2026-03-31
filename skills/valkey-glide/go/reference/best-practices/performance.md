# Performance Tuning

Use when optimizing GLIDE Go throughput and latency, tuning inflight limits, or choosing batching strategies.

---

## Batching Is the Top Optimization

Batching amortizes the CGO FFI overhead across all commands - one crossing per batch instead of one per command. Batched workloads are competitive with go-redis.

### Non-Atomic Pipeline

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

pipe := pipeline.NewStandaloneBatch(false)
for i := 0; i < 100; i++ {
    pipe.Set(fmt.Sprintf("key:%d", i), fmt.Sprintf("value:%d", i))
}
results, err := client.Exec(ctx, *pipe, true)
// One round-trip for 100 commands
```

### Atomic Transaction

```go
tx := pipeline.NewStandaloneBatch(true)
tx.Set("{account}:src", "100")
tx.Set("{account}:dst", "0")
tx.IncrBy("{account}:dst", 50)
tx.DecrBy("{account}:src", 50)
results, err := client.Exec(ctx, *tx, true)
```

All keys must share a hash slot in cluster mode. Use `{tag}` hash tags.

### Cluster Batch

```go
pipe := pipeline.NewClusterBatch(false)
pipe.Set("user:1:name", "Alice")
pipe.Set("user:2:name", "Bob")
pipe.Get("user:1:name")
results, err := clusterClient.Exec(ctx, *pipe, false)
```

Non-atomic cluster batches auto-route each command by key slot across nodes.

### Batch Size Guidelines

| Batch Size | Trade-off |
|------------|-----------|
| 10-50 | Good default. Low latency, solid throughput gain |
| 50-200 | Best throughput. Slight increase in per-batch latency |
| 200-1000 | Diminishing returns. Risk of large response buffers |
| 1000+ | Avoid. Memory pressure and long parsing time |

---

## Goroutine Concurrency

GLIDE is safe for concurrent goroutine access. Use goroutines for parallel independent operations:

```go
var wg sync.WaitGroup
keys := []string{"key1", "key2", "key3"}
results := make([]glide.Result[string], len(keys))

for i, key := range keys {
    wg.Add(1)
    go func(idx int, k string) {
        defer wg.Done()
        results[idx], _ = client.Get(ctx, k)
    }(i, key)
}
wg.Wait()
```

For bulk loads, prefer batching over individual goroutine calls - fewer FFI crossings and network round-trips.

---

## Inflight Request Limit

GLIDE caps concurrent inflight requests at 1000 per client. Requests beyond the limit are rejected immediately.

The Go client does not yet expose an `inflightRequestsLimit` configuration option. The default of 1000 applies. If hitting the limit:
1. Batch commands - one batch counts as one inflight request
2. Create additional client instances - each gets its own 1000-request budget
3. Review concurrency - 1000+ concurrent requests usually means the bottleneck is server-side

---

## Connection Model

GLIDE uses two multiplexed connections per node (data + management). No connection pools to size or manage. All data requests pipeline through the data connection using Valkey's built-in pipelining.

### When to Create Multiple Clients

- Blocking commands (BLPOP, BRPOP, XREADGROUP with BLOCK) - tie up the connection
- WATCH/UNWATCH - requires connection-level isolation
- Large value transfers - prevents head-of-line blocking
- PubSub subscribers - dedicated listener, cannot share with command traffic

---

## Resource Cleanup

Always defer `Close()` immediately after creating a client:

```go
client, err := glide.NewClient(cfg)
if err != nil {
    panic(err)
}
defer client.Close()
```

`Close()` is safe to call multiple times. It drains pending requests with `ClosingError`.

---

## When to Choose GLIDE over go-redis

GLIDE has ~15-20% lower throughput for sequential single-command operations due to CGO overhead. This gap disappears with batching.

Choose GLIDE when:
- Running Valkey Cluster (automatic topology, failover, slot routing)
- Needing built-in OpenTelemetry without wrapping every call
- Wanting automatic PubSub resubscription on reconnect
- Operating across multiple languages with consistent behavior

Stick with go-redis when:
- Maximum raw sequential throughput is critical
- Simple standalone deployment with no cluster
- Want pure-Go with no CGO dependency
