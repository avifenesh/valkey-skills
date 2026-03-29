# Performance Tuning

Use when optimizing GLIDE throughput and latency, choosing between GLIDE and native clients, or tuning inflight request limits and batching strategies. For deployment configuration and timeout tuning, see `production.md`. For error recovery patterns, see `error-handling.md`.

---

## Benchmarks: GLIDE vs Native Clients

### Sequential Operations (Single-Threaded, Node.js)

| Operation | redis (RESP3) | ioredis | valkey-glide |
|-----------|--------------|---------|--------------|
| SET (ops/s) | 8,385 | 8,158 | 6,585 |
| GET (ops/s) | 7,793 | 8,727 | 7,193 |
| HSET (ops/s) | 7,860 | 7,304 | 6,754 |
| HGET (ops/s) | 8,675 | 8,618 | 6,660 |

GLIDE is roughly 15-20% slower than native clients for sequential operations. This overhead comes from the FFI bridge between the language wrapper and the Rust core. Every command crosses the boundary (napi-rs for Node.js, PyO3 as the FFI bridge for Python with Protobuf used for ConnectionRequest serialization, JNI for Java, CGO for Go), adding fixed per-call latency.

### Batched Operations (100 SETs per Batch, Node.js)

| Client | ops/s | avg latency |
|--------|-------|-------------|
| redis (RESP3) multi | 3,615 | 0.277ms |
| valkey-glide atomic | 3,458 | 0.289ms |
| ioredis pipeline | 3,334 | 0.300ms |

Batched workloads are competitive. The FFI overhead is amortized across all commands in the batch - one crossing per batch instead of one per command. Pipelined approaches show 190-257% higher throughput compared to individual async requests.

### Where GLIDE Wins

Raw throughput benchmarks do not capture GLIDE's advantages in real production conditions:

- **Cluster failover**: GLIDE automatically detects topology changes, redirects MOVED/ASK errors, and re-routes commands without application intervention. Native clients often require manual handling or library-specific configuration.
- **Reconnection**: Automatic exponential backoff with jitter. Native clients vary - some drop requests, some block, some require manual reconnection.
- **Topology changes**: Proactive background monitoring with consensus-based resolution. GLIDE queries multiple nodes and picks the view with highest agreement.
- **Multi-slot commands**: MGET, MSET, DEL, EXISTS are automatically split across slots, dispatched, and reassembled.

---

## Inflight Request Limiting

GLIDE caps concurrent inflight requests at **1000 per client** (constant `DEFAULT_MAX_INFLIGHT_REQUESTS` in `glide-core/src/client/mod.rs`).

### Little's Law Reasoning

The default is derived from Little's Law in queuing theory:

```
L = lambda * W

Expected max request rate: 50,000 requests/second
Expected response time:    1 millisecond
Required inflight:         50,000 * 0.001 = 50 requests
```

The value of 1000 provides a 20x buffer for bursts while still preventing resource exhaustion. Requests beyond the limit are rejected immediately.

### When You Hit the Limit

If requests are being rejected due to inflight limits:

1. **Batch commands** - combine multiple commands into a single Batch/pipeline. One batch counts as one inflight request regardless of how many commands it contains.
2. **Create additional client instances** - each client gets its own connection(s) and its own 1000-request budget.
3. **Review your concurrency** - if you genuinely need 1000+ concurrent requests to a single node, the bottleneck is likely server-side.

### Custom Limits

All languages expose an `inflight_requests_limit` configuration option. Lowering it can protect a Valkey node from overload. Raising it above 1000 is rarely necessary.

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    inflight_requests_limit=500,  # Lower for constrained servers
)
```

---

## Batching for Throughput

Batching is the single most effective optimization. Use non-atomic batches (pipelines) for throughput; use atomic batches (transactions) only when you need MULTI/EXEC guarantees.

### Non-Atomic (Pipeline) - Throughput Optimized

```python
pipe = Batch(is_atomic=False)
for i in range(100):
    pipe.set(f"key:{i}", f"value:{i}")
result = await client.exec(pipe)
```

One FFI crossing, one round trip for 100 commands. Cross-slot operations are automatically split in cluster mode.

### Atomic (Transaction) - Consistency Optimized

```python
tx = Batch(is_atomic=True)
tx.set("{account}:src", "100")
tx.set("{account}:dst", "0")
tx.incrby("{account}:dst", 50)
tx.decrby("{account}:src", 50)
result = await client.exec(tx, raise_on_error=True)
```

All keys must hash to the same slot in cluster mode. Use hash tags `{tag}` to ensure co-location.

### Batch Size Guidelines

| Batch Size | Trade-off |
|------------|-----------|
| 10-50 | Good default. Low latency, good throughput improvement |
| 50-200 | Best throughput. Slight increase in per-batch latency |
| 200-1000 | Diminishing returns. Risk of large response buffers |
| 1000+ | Avoid. Memory pressure, long response parsing time |

---

## Connection Model Advantages

GLIDE uses a single multiplexed connection per node. All requests pipeline through this connection using Valkey's built-in request pipelining.

### No Pool Overhead

Traditional clients maintain connection pools (typically 10-50 connections). This means:
- Memory overhead per connection (kernel buffers, TLS state)
- Pool management complexity (sizing, health checks, idle timeout)
- Contention under high concurrency (pool exhaustion, queue wait)

GLIDE eliminates all of this. One connection handles all traffic to a given node.

### When You Need Multiple Clients

Create separate GLIDE client instances only for:
- **Blocking commands** (BLPOP, BRPOP, BLMOVE, XREADGROUP with BLOCK) - these tie up the connection
- **WATCH/UNWATCH** - requires connection-level isolation for optimistic locking
- **Large value transfers** - prevents head-of-line blocking for other operations
- **PubSub subscribers** - dedicated listener that cannot share with command traffic

---

## TCP Tuning

GLIDE enables TCP_NODELAY by default (`tcp_nodelay` defaults to `true` in `types.rs`). This disables Nagle's algorithm, ensuring commands are sent immediately rather than buffered. This is the correct setting for latency-sensitive Valkey workloads.

Do not disable TCP_NODELAY unless you have measured and confirmed that batching at the TCP level helps your specific workload.

---

## When to Choose GLIDE

### Choose GLIDE When

- You run Valkey Cluster and need automatic topology handling, failover, and slot-aware routing
- You operate across multiple languages and want consistent behavior
- You deploy in cloud environments and benefit from AZ Affinity (Valkey 8.0+)
- You need built-in OpenTelemetry without wrapping every call
- You want automatic PubSub resubscription on reconnect
- Reliability matters more than squeezing the last 15% of sequential throughput

### Stick with Native Clients When

- Maximum raw sequential throughput for a single language is critical
- Your deployment is simple (single standalone node, no cluster)
- You have deep operational expertise with your existing client
- You want minimal binary dependencies (GLIDE ships a native Rust library)
- Your application is mostly pipelining already and you do not need cluster features

### Migration Cost-Benefit

The 15-20% sequential overhead disappears when you:
1. Use batching (competitive or faster)
2. Run in cluster mode (GLIDE's topology management prevents the latency spikes that native clients suffer during failover)
3. Account for developer time saved by cross-language consistency

For most production workloads - especially those using cluster mode or requiring high availability - GLIDE's reliability features outweigh the raw throughput difference.
