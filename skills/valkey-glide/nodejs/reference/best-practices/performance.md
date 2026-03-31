# Performance Tuning

Use when optimizing GLIDE Node.js throughput and latency, tuning inflight limits, or choosing batching strategies.

---

## Batching Is the Top Optimization

Batching amortizes the napi-rs FFI overhead across all commands - one crossing per batch instead of one per command. Batched workloads are competitive with native Node.js clients (ioredis, node-redis).

### Non-Atomic Pipeline

```typescript
import { Batch } from "@valkey/valkey-glide";

const batch = new Batch(false);
for (let i = 0; i < 100; i++) {
    batch.set(`key:${i}`, `value:${i}`);
}
const results = await client.exec(batch, true);
// One round-trip for 100 commands
```

### Atomic Transaction

```typescript
const tx = new Batch(true)
    .set("{account}:src", "100")
    .set("{account}:dst", "0")
    .incrBy("{account}:dst", 50)
    .decrBy("{account}:src", 50);
const results = await client.exec(tx, true);
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

## Inflight Request Limit

GLIDE caps concurrent inflight requests at 1000 per client. Requests beyond the limit are rejected immediately.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    inflightRequestsLimit: 500, // lower for constrained servers
});
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

## TCP Tuning

GLIDE enables TCP_NODELAY by default, disabling Nagle's algorithm. Commands are sent immediately rather than buffered. Do not disable this unless you have measured and confirmed that TCP-level batching helps your workload.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    advancedConfiguration: { tcpNoDelay: true }, // default
});
```

---

## When to Choose GLIDE over ioredis / node-redis

GLIDE has ~15-20% lower throughput for sequential single-command operations due to FFI overhead. This gap disappears with batching.

Choose GLIDE when:
- Running Valkey Cluster (automatic topology, failover, slot routing)
- Needing built-in OpenTelemetry without wrapping every call
- Wanting automatic PubSub resubscription on reconnect
- Reliability matters more than squeezing last 15% of sequential throughput

Stick with native clients when:
- Maximum raw sequential throughput is critical
- Simple standalone deployment with no cluster
- Minimal binary dependencies needed
