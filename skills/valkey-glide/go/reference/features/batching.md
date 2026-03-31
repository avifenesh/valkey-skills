# Batching - Pipelines and Transactions

Use when you need to send multiple commands in a single round-trip for throughput or atomicity - pipelines for bulk operations, transactions for atomic multi-command blocks.

Package: `github.com/valkey-io/valkey-glide/go/v2/pipeline`.

## Core Concepts

| Mode | Constructor | Protocol | Slot Constraint |
|------|-------------|----------|-----------------|
| Atomic (transaction) | `NewStandaloneBatch(true)` / `NewClusterBatch(true)` | MULTI/EXEC | All keys same hash slot in cluster |
| Non-atomic (pipeline) | `NewStandaloneBatch(false)` / `NewClusterBatch(false)` | Pipelined | Can span multiple slots and nodes |

Atomic batches guarantee no interleaving. Non-atomic batches maximize throughput across the cluster.

## Batch Types

| Type | Client | Usage |
|------|--------|-------|
| `pipeline.StandaloneBatch` | `Client` | Standalone server |
| `pipeline.ClusterBatch` | `ClusterClient` | Cluster mode |

Both extend `BaseBatch` which provides the full command set (Get, Set, Incr, XAdd, etc.).

## Standalone Batch

### Atomic Transaction

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

tx := pipeline.NewStandaloneBatch(true)
tx.Set("account:src", "100")
tx.Set("account:dst", "0")
tx.IncrBy("account:dst", 50)
tx.DecrBy("account:src", 50)
results, err := client.Exec(ctx, *tx, true) // raiseOnError=true
// results: ["OK", "OK", 50, 50]
```

### Non-Atomic Pipeline

```go
pipe := pipeline.NewStandaloneBatch(false)
pipe.Set("key1", "value1")
pipe.Set("key2", "value2")
pipe.Get("key1")
pipe.Get("key2")
results, err := client.Exec(ctx, *pipe, false)
// results: ["OK", "OK", "value1", "value2"]
```

## Cluster Batch

```go
// Atomic: all keys must hash to same slot
tx := pipeline.NewClusterBatch(true)
tx.Set("{user}:name", "Alice")
tx.Set("{user}:email", "alice@example.com")
tx.Get("{user}:name")
results, err := clusterClient.Exec(ctx, *tx, true)

// Non-atomic: commands auto-routed across nodes
pipe := pipeline.NewClusterBatch(false)
pipe.Set("user:1:name", "Alice")
pipe.Set("user:2:name", "Bob")
pipe.Get("user:1:name")
results, err := clusterClient.Exec(ctx, *pipe, false)
```

## Exec Signatures

```go
// Standalone
func (client *Client) Exec(
    ctx context.Context,
    batch pipeline.StandaloneBatch,
    raiseOnError bool,
) ([]any, error)

func (client *Client) ExecWithOptions(
    ctx context.Context,
    batch pipeline.StandaloneBatch,
    raiseOnError bool,
    options pipeline.StandaloneBatchOptions,
) ([]any, error)

// Cluster
func (client *ClusterClient) Exec(
    ctx context.Context,
    batch pipeline.ClusterBatch,
    raiseOnError bool,
) ([]any, error)

func (client *ClusterClient) ExecWithOptions(
    ctx context.Context,
    batch pipeline.ClusterBatch,
    raiseOnError bool,
    options pipeline.ClusterBatchOptions,
) ([]any, error)
```

Note: pass the batch by value (`*tx` not `tx`) to `Exec`.

## Error Handling

The `raiseOnError` parameter controls batch error behavior:

| Value | Behavior |
|-------|----------|
| `true` | First error in results returned as the `error` return value |
| `false` | Errors embedded inline as `error` values in the `[]any` slice |

```go
results, err := client.Exec(ctx, *pipe, false)
for i, item := range results {
    if e := glide.IsError(item); e != nil {
        fmt.Printf("Command %d failed: %v\n", i, e)
    } else {
        fmt.Printf("Command %d: %v\n", i, item)
    }
}
```

If an atomic batch fails due to a WATCH conflict, `Exec` returns `nil, nil` (nil results, no error).

## Batch Options

### StandaloneBatchOptions

```go
opts := pipeline.NewStandaloneBatchOptions().
    WithTimeout(5 * time.Second)

results, err := client.ExecWithOptions(ctx, *tx, true, *opts)
```

### ClusterBatchOptions

```go
opts := pipeline.NewClusterBatchOptions().
    WithTimeout(5 * time.Second).
    WithRoute(config.RandomRoute).
    WithRetryStrategy(*pipeline.NewClusterBatchRetryStrategy().
        WithRetryServerError(true).
        WithRetryConnectionError(true))

results, err := clusterClient.ExecWithOptions(ctx, *pipe, false, *opts)
```

Retry strategy is not supported for atomic batches - `ExecWithOptions` returns an error if you set `RetryStrategy` on an atomic `ClusterBatch`.

## WATCH for Optimistic Locking

Standalone-only. Monitor keys for changes before executing an atomic batch:

```go
_, err := client.Watch(ctx, []string{"balance"})
// Read current value
val, _ := client.Get(ctx, "balance")

tx := pipeline.NewStandaloneBatch(true)
tx.Set("balance", "new-value")
results, err := client.Exec(ctx, *tx, true)
if results == nil {
    // WATCH key was modified by another client, retry
}

// Discard watches without executing
_, err = client.Unwatch(ctx)
```

## Cluster Routing for Batches

Non-atomic cluster batches:
1. GLIDE computes hash slots for each key-based command
2. Groups commands by target node into sub-pipelines
3. Dispatches sub-pipelines in parallel
4. Reassembles responses in original command order

Atomic cluster batches route to the slot owner of the first key. If no key is found, sent to a random node.

Redirection errors (MOVED, ASK) are always handled automatically.

## Retry Strategies (Non-Atomic Cluster Batches)

| Field | Behavior | Caveat |
|-------|----------|--------|
| `RetryServerError` | Retry on TRYAGAIN errors | May cause out-of-order execution |
| `RetryConnectionError` | Retry batch on connection failure | May cause duplicate executions |

## Batch Command Set

`BaseBatch` exposes the same commands as the client: `Get`, `Set`, `SetWithOptions`, `Incr`, `Decr`, `HSet`, `HGet`, `LPush`, `RPush`, `SAdd`, `ZAdd`, `XAdd`, `XRead`, and all other data-type commands. Each returns `*T` (the batch itself) for method chaining.

Standalone-only batch commands: `Select(index)`. See also [Streams](streams.md) and [Connection](connection.md) for WATCH/UNWATCH.
