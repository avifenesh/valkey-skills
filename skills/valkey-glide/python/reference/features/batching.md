# Batching - Pipelines and Transactions

Use when you need to send multiple commands in a single round-trip for throughput or atomicity - pipelines for bulk operations, transactions for atomic multi-command blocks.

GLIDE uses a unified `Batch` / `ClusterBatch` class hierarchy with an `is_atomic` flag. Setting `is_atomic=True` creates a transaction (MULTI/EXEC); `is_atomic=False` creates a pipeline.

## Contents

- Core Concepts (line 20)
- Standalone Batching (line 27)
- Cluster Batching (line 54)
- Batch Options (line 69)
- Routing Behavior (Cluster) (line 94)
- Error Handling (line 100)
- Retry Strategy (Cluster Only) (line 120)
- WATCH with Transactions (line 137)
- Building Batches with All Command Types (line 152)
- Custom Commands in Batches (line 169)

## Core Concepts

| Mode | Flag | Protocol | Slot Constraint |
|------|------|----------|-----------------|
| Transaction | `is_atomic=True` | MULTI/EXEC | All keys must map to the same hash slot in cluster mode |
| Pipeline | `is_atomic=False` | Pipelined commands | Can span multiple slots and nodes in cluster mode |

## Standalone Batching

```python
from glide import GlideClient, Batch, BatchOptions

# Atomic batch (transaction)
transaction = Batch(is_atomic=True)
transaction.set("key", "1")
transaction.incr("key")
transaction.get("key")

result = await client.exec(transaction, raise_on_error=True)
# result: [OK, 2, b'2']
```

```python
# Non-atomic batch (pipeline)
pipeline = Batch(is_atomic=False)
pipeline.set("key1", "value1")
pipeline.set("key2", "value2")
pipeline.get("key1")
pipeline.get("key2")

result = await client.exec(pipeline, raise_on_error=True)
# result: [OK, OK, b'value1', b'value2']
```

## Cluster Batching

```python
from glide import GlideClusterClient, ClusterBatch, ClusterBatchOptions

batch = ClusterBatch(is_atomic=False)
batch.set("key1", "value1")
batch.set("key2", "value2")
batch.get("key1")

result = await client.exec(batch, raise_on_error=True)
```

For atomic cluster batches, all keys must hash to the same slot. Use hash tags (e.g., `{user}.name`, `{user}.email`) to colocate keys.

## Batch Options

### Standalone

```python
options = BatchOptions(timeout=5000)  # timeout in milliseconds
result = await client.exec(transaction, raise_on_error=True, options=options)
```

### Cluster

```python
from glide import ClusterBatchOptions, BatchRetryStrategy, SlotKeyRoute, SlotType

options = ClusterBatchOptions(
    timeout=5000,
    route=SlotKeyRoute(SlotType.PRIMARY, "my-key"),
    retry_strategy=BatchRetryStrategy(
        retry_server_error=True,
        retry_connection_error=False,
    ),
)
result = await client.exec(batch, raise_on_error=False, options=options)
```

## Routing Behavior (Cluster)

- With explicit `route`: entire batch goes to the specified node.
- Without `route` + atomic: routed to the slot owner of the first key.
- Without `route` + non-atomic: each command routed individually by key slot. Multi-node commands are split and dispatched automatically.

## Error Handling

```python
from glide import RequestError

# raise_on_error=True: first error raises RequestError after all retries
try:
    result = await client.exec(batch, raise_on_error=True)
except RequestError as e:
    print(f"Batch failed: {e}")

# raise_on_error=False: errors appear as RequestError instances in the result array
result = await client.exec(batch, raise_on_error=False)
for i, res in enumerate(result):
    if isinstance(res, RequestError):
        print(f"Command {i} failed: {res}")
    else:
        print(f"Command {i} result: {res}")
```

## Retry Strategy (Cluster Only)

`BatchRetryStrategy` controls retry behavior for non-atomic cluster batches.

```python
strategy = BatchRetryStrategy(
    retry_server_error=True,     # retry on TRYAGAIN etc.
    retry_connection_error=True, # retry on connection failure
)
```

Cautions:
- `retry_server_error=True` may cause commands targeting the same slot to execute out of order.
- `retry_connection_error=True` may cause duplicate executions since the server may have already processed the request.
- Retry strategies are only supported for non-atomic batches.
- Increase `timeout` when enabling retries.

## WATCH with Transactions

Atomic batches support optimistic locking via WATCH. If a watched key changes before EXEC, the transaction returns `None`.

```python
transaction = Batch(is_atomic=True)
transaction.set("counter", "10")
transaction.incr("counter")

result = await client.exec(transaction, raise_on_error=True)
# result is None if a WATCH conflict occurred
if result is None:
    print("Transaction aborted due to WATCH conflict")
```

## Building Batches with All Command Types

`Batch` and `ClusterBatch` support the full GLIDE command set. Commands are queued and executed in order:

```python
batch = Batch(is_atomic=False)
batch.set("str-key", "hello")
batch.hset("hash-key", {"field1": "val1", "field2": "val2"})
batch.lpush("list-key", ["c", "b", "a"])
batch.sadd("set-key", ["x", "y", "z"])
batch.xadd("stream-key", [("sensor", "42")])
batch.publish("hello", "notifications")

result = await client.exec(batch, raise_on_error=True)
# Each result corresponds to the command at the same index
```

## Custom Commands in Batches

```python
batch = Batch(is_atomic=False)
batch.custom_command(["SET", "key", "value"])
batch.custom_command(["GET", "key"])
result = await client.exec(batch, raise_on_error=True)
# result: [OK, b'value']
```
