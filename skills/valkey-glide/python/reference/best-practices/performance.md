# Performance Tuning

Use when optimizing GLIDE Python throughput and latency, tuning inflight limits, or choosing batching strategies.

---

## Batching Is the Top Optimization

Batching amortizes the PyO3 FFI overhead across all commands - one crossing per batch instead of one per command. Batched workloads are competitive with redis-py.

### Non-Atomic Pipeline

```python
from glide import Batch

pipeline = Batch(is_atomic=False)
for i in range(100):
    pipeline.set(f"key:{i}", f"value:{i}")
result = await client.exec(pipeline, raise_on_error=True)
# One round-trip for 100 commands
```

### Atomic Transaction

```python
tx = Batch(is_atomic=True)
tx.set("{account}:src", "100")
tx.set("{account}:dst", "0")
tx.incrby("{account}:dst", 50)
tx.decrby("{account}:src", 50)
result = await client.exec(tx, raise_on_error=True)
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

## Async Best Practices

Use `asyncio.gather()` for concurrent independent operations:

```python
import asyncio

results = await asyncio.gather(
    client.get("key1"),
    client.get("key2"),
    client.get("key3"),
)
```

For bulk loads, prefer batching over individual awaits:

```python
# Slow: 1000 round-trips
for i in range(1000):
    await client.set(f"key:{i}", f"value:{i}")

# Fast: 10 round-trips (100 per batch)
for chunk_start in range(0, 1000, 100):
    batch = Batch(is_atomic=False)
    for i in range(chunk_start, min(chunk_start + 100, 1000)):
        batch.set(f"key:{i}", f"value:{i}")
    await client.exec(batch, raise_on_error=True)
```

---

## Inflight Request Limit

GLIDE caps concurrent inflight requests at 1000 per client. Requests beyond the limit are rejected immediately.

```python
from glide import GlideClientConfiguration, NodeAddress

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    inflight_requests_limit=500,  # lower for constrained servers
)
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

## Compression

Enable transparent compression for large values:

```python
from glide import CompressionConfiguration, CompressionBackend

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    compression=CompressionConfiguration(
        enabled=True,
        backend=CompressionBackend.LZ4,
        min_compression_size=64,  # bytes
    ),
)
```

---

## When to Choose GLIDE over redis-py

GLIDE has ~15-20% lower throughput for sequential single-command operations due to FFI overhead. This gap disappears with batching.

Choose GLIDE when:
- Running Valkey Cluster (automatic topology, failover, slot routing)
- Needing built-in OpenTelemetry without wrapping every call
- Wanting automatic PubSub resubscription on reconnect
- Operating across multiple languages with consistent behavior

Stick with native clients when:
- Maximum raw sequential throughput is critical
- Simple standalone deployment with no cluster
- Minimal binary dependencies needed
