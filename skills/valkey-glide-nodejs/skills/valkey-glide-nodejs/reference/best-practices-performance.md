# Performance tuning (Node.js)

Use when optimizing GLIDE Node throughput and latency. Covers GLIDE-specific discipline - general Node async patterns (`Promise.all`, don't `await` in tight loops) are the same as any Node app and not covered here.

## Client model: one client per process, not per request

GLIDE is a multiplexer. One `GlideClient` / `GlideClusterClient` instance serves every pending Promise in the process concurrently - requests are tagged with IDs and demuxed. Creating a client per request or per worker thread is wasted allocation and a fresh TCP handshake to every cluster node.

**Exceptions - use a dedicated client:**

- Blocking commands: `BLPOP`, `BRPOP`, `BLMOVE`, `BZPOPMAX`, `BZPOPMIN`, `BRPOPLPUSH`, `BLMPOP`, `BZMPOP`, plus `XREAD` / `XREADGROUP` with `BLOCK`. They occupy the multiplexed connection for the block duration.
- WATCH / MULTI / EXEC - connection-state commands; leak across callers on the shared multiplexer.
- Long polling `getPubSubMessage()` - holds the Promise indefinitely.

Large values are NOT an exception - they pipeline through the multiplexer fine.

## Batching is the top optimization

Batching amortizes the napi-rs FFI + UDS crossing across all commands - one crossing per batch instead of one per command. This is the single biggest throughput knob.

```typescript
import { Batch } from "@valkey/valkey-glide";

const batch = new Batch(false);
for (let i = 0; i < 100; i++) batch.set(`k:${i}`, `v:${i}`);
await client.exec(batch, true);  // one round-trip, one multiplexer slot
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

The multiplexer caps concurrent inflight requests at `inflightRequestsLimit: 1000` per client by default. Beyond the cap, requests fail with `RequestError("Reached maximum inflight requests")` - rejected, not queued.

If you hit it: first batch commands (one batch = one slot), then consider whether 1000 concurrent in-flight is actually the bottleneck (usually it's server-side). Only as a last resort create a second client - doubling clients doubles the TCP footprint and breaks the single-multiplexer invariant.

## TCP_NODELAY

Default `true` - commands sent immediately rather than Nagle-buffered. Almost always the right choice for request/response traffic. Disable (`advancedConfiguration: { tcpNoDelay: false }`) only if benchmarks show TCP-level batching helps your workload.

## Compression

GLIDE offers transparent value compression on the core side, configured via the connection config - see [features-connection](features-connection.md). Monitor effect via `client.getStatistics()` keys `total_bytes_compressed` vs `total_original_bytes` vs `compression_skipped_count`.

