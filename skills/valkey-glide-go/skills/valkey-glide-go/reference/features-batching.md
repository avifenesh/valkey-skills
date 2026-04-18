# Batching - pipelines and transactions (Go)

Use when sending multiple commands in one round-trip. Covers what differs from go-redis's `rdb.Pipeline()` / `rdb.TxPipeline()`. Package: `github.com/valkey-io/valkey-glide/go/v2/pipeline`.

## Divergence from go-redis

| go-redis | GLIDE Go |
|----------|---------|
| `pipe := rdb.Pipeline(); pipe.Set(ctx, ...); pipe.Exec(ctx)` | `batch := pipeline.NewStandaloneBatch(false); batch.Set(...); client.Exec(ctx, *batch, true)` |
| `rdb.TxPipeline()` for transactions | `pipeline.NewStandaloneBatch(true)` - same class, `isAtomic` flag in constructor |
| Pipeline returns `[]redis.Cmder` - iterate calling `.Err()` and typed accessors | `[]any` with elements per command; errors inline if `raiseOnError=false`, or first error thrown if `true` |
| Cluster pipelining: hand-split by slot | `NewClusterBatch(false)` auto-routes per-slot; multi-node batches dispatched automatically |

Two batch types:

| Type | Client | Command set |
|------|--------|-------------|
| `pipeline.StandaloneBatch` | `Client` | Includes `Select(index)` for DB switching |
| `pipeline.ClusterBatch` | `ClusterClient` | Includes sharded `Publish` |

Both extend `BaseBatch` with full command set via fluent chaining.

## Standalone Batch

### Atomic Transaction

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

batch := pipeline.NewStandaloneBatch(false)
batch.Set("k1", "v1")
batch.Incr("k1")
batch.Get("k1")
results, err := client.Exec(ctx, *batch, true)  // raiseOnError=true; first error -> err return
```

Cluster atomic batches require all keys in one hash slot (use `{tag}` hash tags). Cluster non-atomic batches split per-slot automatically.

## `Exec` vs `ExecWithOptions`

```go
// Signatures (both clients):
client.Exec(ctx, batch, raiseOnError)                          // ([]any, error)
client.ExecWithOptions(ctx, batch, raiseOnError, options)      // ([]any, error)
```

Pass the batch by value via `*batch` to `Exec`. Options types:

- `pipeline.StandaloneBatchOptions` - `WithTimeout(d)`
- `pipeline.ClusterBatchOptions` - adds `WithRoute(r)` and `WithRetryStrategy(s)`

Returns `nil, nil` when an atomic batch fails due to a WATCH conflict.

## `raiseOnError` semantics

- `true` - first inline error is returned as the `err`.
- `false` - errors embedded inline as `error` values in the `[]any` slice:

```go
results, err := client.Exec(ctx, *batch, false)
for i, item := range results {
    if e := glide.IsError(item); e != nil {
        // handle
    }
}
```

`BatchError` wraps multiple per-command errors when `raiseOnError=true` and several commands fail prep-time. See [error-handling](best-practices-error-handling.md).

## Cluster retry strategy (non-atomic only)

```go
opts := pipeline.NewClusterBatchOptions().
    WithTimeout(5 * time.Second).
    WithRoute(config.RandomRoute).
    WithRetryStrategy(*pipeline.NewClusterBatchRetryStrategy().
        WithRetryServerError(true).
        WithRetryConnectionError(false))
```

Hazards:
- `RetryServerError` can reorder commands within a slot.
- `RetryConnectionError` can cause duplicate executions - the server may have already processed before the connection died.
- Not supported on atomic batches; `ExecWithOptions` errors if you try.

MOVED / ASK redirects are always handled automatically - non-atomic redirects only the affected commands; atomic redirects the entire transaction.

## WATCH (standalone only)

```go
client.Watch(ctx, []string{"balance"})
// read current, decide new value...
tx := pipeline.NewStandaloneBatch(true)
tx.Set("balance", "new")
results, err := client.Exec(ctx, *tx, true)
if results == nil { /* WATCH conflict - retry */ }

client.Unwatch(ctx)  // discard without executing
```

WATCH is a connection-state command - run it on a dedicated client to avoid leaking state across goroutines on the shared multiplexer.
