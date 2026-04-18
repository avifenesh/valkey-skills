# Performance tuning (Go)

Use when optimizing GLIDE Go throughput and latency. Covers GLIDE-specific discipline; general Go concurrency (goroutines, sync.WaitGroup, channel patterns) is the same as any Go app and not covered here.

## Client model: one client per process, not per goroutine

GLIDE is a multiplexer. One `*Client` / `*ClusterClient` serves every goroutine concurrently - requests are tagged with IDs and demuxed. `client.Get(ctx, ...)` is goroutine-safe; call from any number of goroutines without a mutex. Creating a client per goroutine wastes allocation and opens fresh TCP handshakes to every cluster node.

**Exceptions - use a dedicated client:**

- Blocking commands: `BLPop`, `BRPop`, `BLMove`, `BZPopMax`, `BZPopMin`, `BRPopLPush`, `BLMPop`, `BZMPop`, plus `XRead` / `XReadGroup` with block, and `Wait` / `WaitAof`. They occupy the multiplexed connection for the block duration.
- `Watch` / atomic batch with WATCH - connection-state command; leaks across goroutines on the shared multiplexer.
- PubSub subscribers doing high-volume subscriptions.

Large values are NOT an exception - they pipeline through the multiplexer fine.

## Batching is the top optimization

Batching amortizes the CGO crossing across all commands - one crossing per batch instead of one per command. This is the single biggest throughput knob.

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

batch := pipeline.NewStandaloneBatch(false)
for i := 0; i < 100; i++ {
    batch.Set(fmt.Sprintf("k:%d", i), fmt.Sprintf("v:%d", i))
}
client.Exec(ctx, *batch, true)  // one CGO crossing, one multiplexer slot
```

In cluster mode, atomic batches require all keys to share a hash slot: `batch.Set("{account}:src", ...)`.

Rough batch-size guidelines:

| Size | Trade-off |
|------|-----------|
| 10-50 | Good default; low latency, solid throughput gain |
| 50-200 | Best throughput; slight per-batch latency increase |
| 200-1000 | Diminishing returns, large response buffers |
| 1000+ | Memory pressure, long parsing - avoid |

## Inflight request limit

The multiplexer caps concurrent inflight requests at 1000 per client. Requests beyond the cap fail with an error - rejected, not queued.

**Go-specific:** `inflightRequestsLimit` is NOT exposed via the Go client config at v2.3.1 (Python/Node expose it). The default of 1000 is baked in. If you hit it, first batch commands (one batch = one slot), then consider whether 1000 concurrent in-flight is actually the bottleneck (usually server-side). Only as a last resort create a second client - doubling clients doubles the TCP footprint and breaks the single-multiplexer invariant.

## CGO overhead

Every client command crosses the CGO boundary. Batching amortizes this. Avoid tight per-command loops; prefer `Exec` with a populated `Batch`.

## Compression

Transparent value compression can reduce network bytes for large string / hash values. Configure via connection config - see [features-connection](features-connection.md). Monitor effect via `GetStatistics()`: compare `total_bytes_compressed` with `total_original_bytes` and watch `compression_skipped_count`.

## Resource cleanup

```go
client, err := glide.NewClient(cfg)
if err != nil { return err }
defer client.Close()
```

`Close()` is safe to call multiple times. Pending requests get `ClosingError`.

