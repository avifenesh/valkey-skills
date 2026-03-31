Use when executing multiple Valkey commands together using Batch (pipeline or transaction), ClusterBatch, or the deprecated Transaction class.

## Batch vs Transaction

`Transaction` is deprecated. Use `Batch` instead. A `Batch(true)` is atomic (transaction with MULTI/EXEC). A `Batch(false)` is non-atomic (pipeline).

```java
import glide.api.models.Batch;
import glide.api.models.ClusterBatch;
```

## Atomic Batch (Transaction)

All commands execute atomically. If any command fails, the transaction aborts.

```java
Batch transaction = new Batch(true)  // atomic
    .set("key1", "value1")
    .set("key2", "value2")
    .get("key1")
    .get("key2");

Object[] results = client.exec(transaction, false).get();
// results: ["OK", "OK", "value1", "value2"]
```

## Non-Atomic Batch (Pipeline)

Commands are pipelined for throughput but not wrapped in MULTI/EXEC:

```java
Batch pipeline = new Batch(false)  // non-atomic
    .set("key1", "value1")
    .set("key2", "value2")
    .get("key1")
    .get("key2");

Object[] results = client.exec(pipeline, false).get();
// results: ["OK", "OK", "value1", "value2"]
```

## raiseOnError Parameter

The second argument to `exec()` controls error handling:

```java
// raiseOnError=true: throws on any command error
Object[] results = client.exec(batch, true).get();

// raiseOnError=false: errors are returned as elements in the result array
Object[] results = client.exec(batch, false).get();
```

## ClusterBatch

For `GlideClusterClient`, use `ClusterBatch`:

```java
ClusterBatch transaction = new ClusterBatch(true)
    .set("key", "value")
    .get("key");

Object[] results = clusterClient.exec(transaction, false).get();
```

## Batch with Options

### Standalone BatchOptions

```java
import glide.api.models.commands.batch.BatchOptions;

BatchOptions options = BatchOptions.builder()
    .timeout(5000)  // override requestTimeout for this batch
    .build();

Object[] results = client.exec(batch, false, options).get();
```

### Cluster ClusterBatchOptions

```java
import glide.api.models.commands.batch.ClusterBatchOptions;
import glide.api.models.commands.batch.ClusterBatchRetryStrategy;
import glide.api.models.configuration.RequestRoutingConfiguration.SlotKeyRoute;
import glide.api.models.configuration.RequestRoutingConfiguration.SlotType;

// Route to a specific node
ClusterBatchOptions options = ClusterBatchOptions.builder()
    .route(new SlotKeyRoute("key", SlotType.PRIMARY))
    .timeout(5000)
    .build();

Object[] results = clusterClient.exec(clusterBatch, false, options).get();
```

### Cluster Retry Strategy

Retry strategies apply only to non-atomic batches. Use with caution - retries can cause out-of-order execution or duplicate commands:

```java
ClusterBatchRetryStrategy retry = ClusterBatchRetryStrategy.builder()
    .retryServerError(true)      // retry TRYAGAIN errors
    .retryConnectionError(true)  // retry on connection failure
    .build();

ClusterBatchOptions options = ClusterBatchOptions.builder()
    .retryStrategy(retry)
    .timeout(10000)  // increase timeout when using retries
    .build();

Object[] results = clusterClient.exec(pipeline, false, options).get();
```

## Standalone-Only: SELECT in Batch

`Batch` (standalone) supports `select()` to switch databases mid-batch:

```java
Batch batch = new Batch(false)
    .select(0)
    .set("key", "value_db0")
    .select(1)
    .set("key", "value_db1");

Object[] results = client.exec(batch, false).get();
```

## Chaining

Batch commands return the batch instance for fluent chaining:

```java
Batch batch = new Batch(false)
    .set("name", "Alice")
    .set("age", "30")
    .get("name")
    .incr("age")
    .expire("name", 3600);

Object[] results = client.exec(batch, false).get();
// results: ["OK", "OK", "Alice", 31L, true]
```

## Deprecated Transaction Class

`Transaction` extends `Batch(true)`. `ClusterTransaction` extends `ClusterBatch(true)`. Both are deprecated - use `Batch`/`ClusterBatch` with `isAtomic=true` instead:

```java
// Deprecated
Transaction tx = new Transaction();
tx.set("key", "val").get("key");
Object[] results = client.exec(tx).get();

// Replacement
Batch batch = new Batch(true);
batch.set("key", "val").get("key");
Object[] results = client.exec(batch, true).get();
```

## Error Handling

`ExecAbortException` is thrown when an atomic batch (transaction) is aborted:

```java
try {
    Object[] results = client.exec(batch, true).get();
} catch (java.util.concurrent.ExecutionException e) {
    if (e.getCause() instanceof ExecAbortException) {
        System.out.println("Transaction aborted: " + e.getCause().getMessage());
    }
}
```
