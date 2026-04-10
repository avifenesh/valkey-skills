# Performance Tuning

Use when optimizing GLIDE Java throughput and latency, tuning inflight limits, or choosing batching strategies.

## Contents

- Batching Is the Top Optimization (line 16)
- CompletableFuture Best Practices (line 57)
- Inflight Request Limit (line 80)
- Connection Model (line 98)
- Resource Management (line 111)
- When to Choose GLIDE over Jedis / Lettuce (line 123)

---

## Batching Is the Top Optimization

Batching amortizes the JNI FFI overhead across all commands - one crossing per batch instead of one per command. Batched workloads are competitive with Jedis and Lettuce.

### Non-Atomic Pipeline

```java
import glide.api.models.Batch;

Batch pipeline = new Batch(false);
for (int i = 0; i < 100; i++) {
    pipeline.set("key:" + i, "value:" + i);
}
Object[] results = client.exec(pipeline, true).get(10000, TimeUnit.MILLISECONDS);
// One round-trip for 100 commands
```

### Atomic Transaction

```java
Batch tx = new Batch(true)
    .set("{account}:src", "100")
    .set("{account}:dst", "0")
    .incrBy("{account}:dst", 50)
    .decrBy("{account}:src", 50);
Object[] results = client.exec(tx, true).get(5000, TimeUnit.MILLISECONDS);
```

All keys must share a hash slot in cluster mode. Use `{tag}` hash tags.

### Batch Size Guidelines

| Batch Size | Trade-off |
|------------|-----------|
| 10-50 | Good default. Low latency, solid throughput gain |
| 50-200 | Best throughput. Slight increase in per-batch latency |
| 200-1000 | Diminishing returns. Risk of large response buffers |
| 1000+ | Avoid. Memory pressure and long parsing time |

---

## CompletableFuture Best Practices

Always use timed gets. Never call bare `.get()`:

```java
// Good: bounded wait
String value = client.get("key").get(500, TimeUnit.MILLISECONDS);

// Bad: blocks forever if connection stalls
String value = client.get("key").get();
```

For parallel operations, use `CompletableFuture.allOf()`:

```java
CompletableFuture<String> f1 = client.get("key1");
CompletableFuture<String> f2 = client.get("key2");
CompletableFuture<String> f3 = client.get("key3");
CompletableFuture.allOf(f1, f2, f3).get(2000, TimeUnit.MILLISECONDS);
```

---

## Inflight Request Limit

GLIDE caps concurrent inflight requests at 1000 per client. Requests beyond the limit are rejected immediately.

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .inflightRequestsLimit(500)  // lower for constrained servers
    .build();
```

If hitting the limit:
1. Batch commands - one batch counts as one inflight request
2. Create additional client instances - each gets its own 1000-request budget
3. Review concurrency - 1000+ concurrent requests usually means the bottleneck is server-side

---

## Connection Model

GLIDE uses a single multiplexed connection per node. No connection pools to size or manage. All requests pipeline through one connection using Valkey's built-in pipelining.

### When to Create Multiple Clients

- Blocking commands (BLPOP, BRPOP, XREADGROUP with BLOCK) - tie up the connection
- WATCH/UNWATCH - requires connection-level isolation
- Large value transfers - prevents head-of-line blocking
- PubSub subscribers - dedicated listener, cannot share with command traffic

---

## Resource Management

GlideClient implements `AutoCloseable`. Use try-with-resources:

```java
try (GlideClient client = GlideClient.createClient(config).get()) {
    client.set("key", "value").get(500, TimeUnit.MILLISECONDS);
}
```

---

## When to Choose GLIDE over Jedis / Lettuce

GLIDE has ~15-20% lower throughput for sequential single-command operations due to JNI overhead. This gap disappears with batching.

Choose GLIDE when:
- Running Valkey Cluster (automatic topology, failover, slot routing)
- Needing built-in OpenTelemetry without wrapping every call
- Wanting automatic PubSub resubscription on reconnect
- Operating across multiple languages with consistent behavior

Stick with native clients when:
- Maximum raw sequential throughput is critical
- Simple standalone deployment with no cluster
- Deep existing operational expertise with Jedis/Lettuce
