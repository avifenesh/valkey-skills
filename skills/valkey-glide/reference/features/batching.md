# Batching - Pipelines and Transactions

Use when you need to send multiple commands in a single round-trip for throughput or atomicity - pipelines for bulk operations, transactions for atomic multi-command blocks.

Requires: GLIDE 2.0+.

GLIDE unified the separate Transaction and Pipeline APIs into a single Batch/ClusterBatch class hierarchy with an `is_atomic` flag. This replaced the older `Transaction` class (which is now a thin alias for backwards compatibility).

## Core Concepts

| Mode | Flag | Protocol | Slot Constraint |
|------|------|----------|-----------------|
| Atomic batch (transaction) | `is_atomic=True` | MULTI/EXEC | All keys must map to the same hash slot in cluster mode |
| Non-atomic batch (pipeline) | `is_atomic=False` | Pipelined commands | Can span multiple slots and nodes in cluster mode |

Atomic batches guarantee that all commands run as a single unit - no other client command can interleave. Non-atomic batches send commands without atomic guarantees but can route across the full cluster.

## Class Hierarchy

| Language | Standalone | Cluster | Legacy Alias |
|----------|-----------|---------|--------------|
| Python | `Batch(is_atomic)` | `ClusterBatch(is_atomic)` | `Transaction(Batch)` |
| Java | `Batch(boolean isAtomic)` | `ClusterBatch(boolean isAtomic)` | `Transaction(Batch)` |
| Node.js | `Batch` | `ClusterBatch` | `Transaction(Batch)` |
| Go | `pipeline.NewStandaloneBatch(isAtomic)` | `pipeline.NewClusterBatch(isAtomic)` | - |

All classes extend a common `BaseBatch` base that provides the full command set.

## Python

```python
from glide import Batch, ClusterBatch

# Atomic transaction (standalone)
tx = Batch(is_atomic=True)
tx.set("account:src", "100")
tx.set("account:dst", "0")
tx.incrby("account:dst", 50)
tx.decrby("account:src", 50)
result = await client.exec(tx, raise_on_error=True)
# ['OK', 'OK', 50, 50]

# Non-atomic pipeline (cluster)
pipe = ClusterBatch(is_atomic=False)
pipe.set("user:1:name", "Alice")
pipe.set("user:2:name", "Bob")
pipe.get("user:1:name")
pipe.get("user:2:name")
result = await client.exec(pipe, raise_on_error=False)
# ['OK', 'OK', b'Alice', b'Bob']
```

### Batch Options (Python)

```python
from glide import BatchOptions, ClusterBatchOptions

# Standalone batch with options
opts = BatchOptions(timeout=5000)
result = await client.exec(batch, options=opts)

# Cluster batch with retry strategy
opts = ClusterBatchOptions(timeout=5000)
result = await client.exec(batch, options=opts)
```

## Java

```java
import glide.api.models.Batch;
import glide.api.models.ClusterBatch;

// Atomic transaction
Batch transaction = new Batch(true);
transaction.set("key", "value");
transaction.incr("counter");
transaction.get("key");
Object[] result = client.exec(transaction).get();

// Non-atomic pipeline
Batch pipeline = new Batch(false);
pipeline.set("key1", "value1");
pipeline.set("key2", "value2");
pipeline.get("key1");
pipeline.get("key2");
Object[] result = client.exec(pipeline, false).get();
// result: ["OK", "OK", "value1", "value2"]
```

Java also provides `BatchOptions` and `ClusterBatchOptions` for configuration, and `ClusterBatchRetryStrategy` for controlling retry behavior on server and connection errors.

## Node.js

```javascript
import { Batch, ClusterBatch, Transaction } from "@valkey/valkey-glide";

// Atomic (Transaction is an alias for Batch)
const tx = new Transaction()
    .set("key", "value")
    .get("key");
const result = await client.exec(tx);
// ['OK', 'value']

// Non-atomic pipeline - cluster
const pipe = new ClusterBatch()
    .set("k1", "v1")
    .set("k2", "v2")
    .get("k1");
const result = await client.exec(pipe);
```

Node.js `Batch` and `ClusterBatch` extend `BaseBatch`. `Transaction` is exported as an alias for `Batch`.

## Go

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

// Atomic transaction
tx := pipeline.NewStandaloneBatch(true)
tx.Set("key", "value")
tx.Incr("counter")
tx.Get("key")
results, err := client.Exec(ctx, *tx, true)

// Non-atomic pipeline (cluster)
pipe := pipeline.NewClusterBatch(false)
pipe.Set("k1", "v1")
pipe.Set("k2", "v2")
pipe.Get("k1")
results, err := client.Exec(ctx, *pipe, false)
```

Go provides `StandaloneBatchOptions` and `ClusterBatchOptions` for configuration. `ClusterBatchRetryStrategy` controls retry behavior:

```go
retryStrategy := pipeline.NewClusterBatchRetryStrategy().
    WithRetryServerError(true).
    WithRetryConnectionError(true)
opts := pipeline.NewClusterBatchOptions().
    WithRetryStrategy(retryStrategy)
```

## Error Handling

The `raise_on_error` parameter (Python) or equivalent controls batch error behavior:

| Setting | Behavior |
|---------|----------|
| `True` / `true` | Raises/throws on the first error encountered in the batch results |
| `False` / `false` | Returns errors inline as `RequestError` objects in the results array |

```python
# Inline error handling
result = await client.exec(batch, raise_on_error=False)
for item in result:
    if isinstance(item, RequestError):
        print(f"Command failed: {item}")
    else:
        print(f"Success: {item}")
```

## Performance

Batching provides significant throughput gains by reducing round-trip overhead. Benchmarks show 190-257% higher throughput with pipelined batches compared to individual async requests.

For batched operations (100 SETs per batch), GLIDE performs comparably to native clients:

| Client | ops/s | avg latency |
|--------|-------|-------------|
| redis (RESP3) multi | 3,615 | 0.277ms |
| valkey-glide atomic | 3,458 | 0.289ms |
| ioredis pipeline | 3,334 | 0.300ms |

## Multi-Node Pipeline Execution

For non-atomic cluster batches, GLIDE splits commands across nodes:

1. Computes hash slots for each key-based command
2. Groups commands by target node into sub-pipelines
3. Dispatches sub-pipelines independently to target nodes
4. Reassembles responses in original command order

This means a single `ClusterBatch` with keys spanning 3 nodes produces 3 parallel sub-pipelines, maximizing throughput while preserving the response ordering the caller expects.

## Retry Strategies (Non-Atomic Cluster Batches)

Non-atomic cluster batches support configurable retry behavior via `ClusterBatchRetryStrategy`:

| Strategy | Behavior | Caveat |
|----------|----------|--------|
| `retryServerError` | Retry on TRYAGAIN errors | May cause out-of-order execution |
| `retryConnectionError` | Retry entire batch on connection failure | May cause duplicate executions |

Redirection errors (MOVED, ASK) are always handled automatically regardless of retry configuration.

```python
from glide import ClusterBatchOptions, BatchRetryStrategy

options = ClusterBatchOptions(
    retry_strategy=BatchRetryStrategy(retry_server_error=True, retry_connection_error=False),
    timeout=2000
)
result = await client.exec(batch, raise_on_error=False, options=options)
```

## Inflight Limits and Optimal Batch Sizes

GLIDE uses multiplexed connections with automatic pipelining - all requests go through a single connection per node. The default inflight request limit is 1000 per client (configurable). Based on Little's Law: at 50K req/s with 1ms avg response = 50 inflight, so 1000 gives roughly 20x headroom for bursts. For the full inflight limiting mechanism, see [connection-model](../architecture/connection-model.md).

Practical sizing guidance:
- **Latency-sensitive workloads**: 10-50 commands per batch
- **Throughput-focused bulk operations**: 100-500 commands per batch
- The 1000 default inflight limit applies to concurrent requests (each batch counts as one inflight request regardless of how many commands it contains). Beyond 1000 concurrent inflight requests, excess requests are immediately rejected

## Cluster Mode Considerations

- Atomic batches require all keys to hash to the same slot. Use hash tags `{tag}` to co-locate keys.
- Non-atomic batches can span multiple slots and nodes - GLIDE automatically splits and routes per-slot.
- `ClusterBatch` is the cluster-mode variant; `Batch`/`StandaloneBatch` is for standalone mode.

## Standalone-Only Commands in Batch

The standalone `Batch` class supports commands not available in `ClusterBatch`:

- `select(index)` - change database within the batch
- `copy(source, destination, destinationDB, replace)` - copy with cross-database support

## Related Features

- [Streams](streams.md) - all stream commands support batch execution for pipelined or transactional usage
- [Scripting](scripting.md) - `invoke_script` is NOT supported in batches; use `custom_command(["EVAL", ...])` instead
- [Compression](compression.md) - compressed SET/GET commands work within batches
