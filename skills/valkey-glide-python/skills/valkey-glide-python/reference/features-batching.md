# Batching - pipelines and transactions

Use when sending multiple commands in one round-trip. Pipelines for bulk throughput, transactions for atomicity. Covers what differs from `redis-py` - the basic "queue commands, run them" pattern works as expected.

## Divergence from redis-py

| redis-py | GLIDE Python |
|----------|--------------|
| `pipe = r.pipeline(transaction=True)` + `pipe.execute()` | `batch = Batch(is_atomic=True)` + `await client.exec(batch, raise_on_error=True)` |
| `pipe.watch(...)` then `pipe.multi()` | WATCH/MULTI/EXEC needs a dedicated client (occupies the multiplexer); result is `None` on WATCH conflict |
| Separate pipeline vs transaction methods | Unified `Batch` / `ClusterBatch` with `is_atomic` flag |
| Cluster pipelining: manual slot split | `ClusterBatch(is_atomic=False)` auto-routes per-slot; multi-node batches split internally |
| `strict_transactions=True` errors | `raise_on_error=True` raises on first error after all retries; `False` puts `RequestError` in the result array |

One class, two modes:

| Mode | `is_atomic` | Protocol | Cluster constraint |
|------|-------------|----------|---------------------|
| Transaction | `True` | MULTI/EXEC | All keys must map to one hash slot (use hash tags) |
| Pipeline | `False` | Pipelined commands | Any slots; GLIDE splits and dispatches per-slot |

## Minimal shape

```python
from glide import Batch, ClusterBatch

batch = Batch(is_atomic=False)  # or ClusterBatch for a cluster client
batch.set("k1", "v1")
batch.incr("k1")
batch.get("k1")
results = await client.exec(batch, raise_on_error=True)
```

## Cluster-only options (`ClusterBatchOptions`)

```python
from glide import (
    ClusterBatchOptions, BatchRetryStrategy, SlotKeyRoute, SlotType,
)

opts = ClusterBatchOptions(
    timeout=5000,                                # ms
    route=SlotKeyRoute(SlotType.PRIMARY, "key"), # optional; pins entire batch to one node
    retry_strategy=BatchRetryStrategy(
        retry_server_error=True,     # retry on TRYAGAIN etc.
        retry_connection_error=True, # retry the batch on connection failure
    ),
)
results = await client.exec(batch, raise_on_error=False, options=opts)
```

### Routing behavior

| Config | Dispatch |
|--------|----------|
| `route=` specified | Entire batch to that node |
| Atomic, no `route` | Slot owner of the first key |
| Non-atomic, no `route` | Per-command by key slot; multi-node batches split automatically |

### Retry strategy (cluster non-atomic only)

`BatchRetryStrategy` is not supported on atomic batches. Hazards:

- `retry_server_error=True` can reorder commands within a slot.
- `retry_connection_error=True` can cause duplicate executions - the server may have already processed the request before the connection died.
- Increase `timeout` when enabling retries so the retry window fits.

MOVED / ASK redirects are always handled automatically and are orthogonal to this knob.

## `raise_on_error` semantics

```python
from glide import RequestError

# raise_on_error=True: first error raises; nothing returned
try:
    results = await client.exec(batch, raise_on_error=True)
except RequestError as e:
    ...

# raise_on_error=False: errors are inline in results as RequestError instances
results = await client.exec(batch, raise_on_error=False)
for i, r in enumerate(results):
    if isinstance(r, RequestError):
        ...
```

## WATCH with transactions

Atomic batches support WATCH. If a watched key changes before EXEC, `exec()` returns `None` (not a list, not an error):

```python
batch = Batch(is_atomic=True)
batch.incr("counter")
result = await client.exec(batch, raise_on_error=True)
if result is None:
    # WATCH conflict - retry or abort
    ...
```

WATCH itself must be issued on a dedicated client - it's a connection-state command; the multiplexed connection would leak watch state across callers.
