# Performance tuning

Use when optimizing GLIDE Python throughput and latency. Covers GLIDE-specific points - general async discipline (use `asyncio.gather` for independent ops, avoid `await` in tight loops) is the same as any async Python and is not covered here.

## Client model: one client per process, not per task

GLIDE is a multiplexer. One `GlideClient` / `GlideClusterClient` instance serves every coroutine in the process concurrently - requests are tagged with IDs and demuxed. Creating a client per asyncio task is wasted allocation and a fresh TCP handshake to every cluster node.

**Exceptions - use a dedicated client:**

- Blocking commands: `BLPOP`, `BRPOP`, `BLMOVE`, `BZPOPMAX`, `BZPOPMIN`, `BRPOPLPUSH`, `BLMPOP`, `BZMPOP`, plus `XREAD` / `XREADGROUP` with `BLOCK` (full list matches the blocking-timeout table in `glide-core/src/client/mod.rs`). These occupy the multiplexed connection for the block duration.
- WATCH / MULTI / EXEC - connection-state commands; leak across callers on the shared multiplexer.
- Long polling of `get_pubsub_message()` - blocks an asyncio task indefinitely.

Large values do NOT require a dedicated client - they pipeline through the multiplexed connection; they just take longer to transfer.

## Batching is the top optimization

Batching amortizes the PyO3 / UDS crossing across all commands - one crossing per batch instead of one per command. This is the single biggest throughput knob.

```python
from glide import Batch

batch = Batch(is_atomic=False)
for i in range(100):
    batch.set(f"key:{i}", f"value:{i}")
await client.exec(batch, raise_on_error=True)  # one round-trip, one multiplexer slot
```

In cluster mode, atomic batches require all keys to share a hash slot: `batch.set("{account}:src", ...)`, `batch.set("{account}:dst", ...)`.

Rough batch-size guidelines:

| Size | Trade-off |
|------|-----------|
| 10-50 | Good default; low latency, solid throughput gain |
| 50-200 | Best throughput; slight per-batch latency increase |
| 200-1000 | Diminishing returns, large response buffers |
| 1000+ | Memory pressure, long parsing - avoid |

## Inflight request limit

The multiplexer caps concurrent inflight requests at `DEFAULT_MAX_INFLIGHT_REQUESTS = 1000` per client. Beyond the cap, requests fail with `RequestError("Reached maximum inflight requests")` - rejected, not queued.

```python
GlideClientConfiguration(addresses=[...], inflight_requests_limit=500)
```

If you hit it: first batch commands (one batch = one slot), then consider whether 1000 concurrent in-flight is actually the bottleneck (usually it's server-side). Only as a last resort create a second client - doubling clients doubles the TCP footprint and breaks the single-multiplexer invariant.

## Compression

Transparent value compression can reduce network bytes for large string/hash values; decompression happens automatically on read:

```python
from glide import CompressionConfiguration, CompressionBackend

CompressionConfiguration(
    enabled=True,
    backend=CompressionBackend.LZ4,  # or ZSTD (default)
    min_compression_size=64,          # bytes; below this, no compression
)
```

Monitor effect via `get_statistics()`: `total_bytes_compressed` vs `total_original_bytes` vs `compression_skipped_count`.

