# Batching - pipelines and transactions (Node.js)

Use when sending multiple commands in one round-trip. Pipelines for bulk throughput, transactions for atomicity. Covers what differs from ioredis's `pipeline()` / `multi()` pattern - the basic "queue commands, run them" shape is similar and not covered here.

## Divergence from ioredis

| ioredis | GLIDE |
|---------|-------|
| `client.pipeline().set("k","v").exec()` | `client.exec(new Batch(false).set("k","v"), true)` |
| `client.multi().set("k","v").exec()` | `client.exec(new Batch(true).set("k","v"), true)` |
| Pipeline is chainable on the client | `Batch` / `ClusterBatch` are standalone objects handed to the client's `exec()` |
| Separate pipeline vs transaction methods | Unified `Batch` / `ClusterBatch` with constructor `isAtomic` flag |
| Errors via tuple `[err, result]` per command | Errors via `raiseOnError` - `true` throws on first, `false` puts `RequestError` in the results array inline |
| Cluster pipelining: manual slot split | `ClusterBatch(false)` auto-splits per-slot; multi-node batches dispatched automatically |
| `Transaction` / `ClusterTransaction` classes | Deprecated aliases for `new Batch(true)` / `new ClusterBatch(true)`; migrating code may still reference them |

## Classes

| Class | Client | Mode |
|-------|--------|------|
| `Batch` | `GlideClient` | `new Batch(isAtomic: boolean)`; has `.select(index)` for DB switching (not on cluster) |
| `ClusterBatch` | `GlideClusterClient` | `new ClusterBatch(isAtomic: boolean)`; has sharded `.publish()` |
| `Transaction` | `GlideClient` | Deprecated alias for `new Batch(true)` |
| `ClusterTransaction` | `GlideClusterClient` | Deprecated alias for `new ClusterBatch(true)` |

All four extend `BaseBatch<T>` with fluent chaining - every command method returns `this`.

## Minimal shape

```typescript
import { Batch, RequestError } from "@valkey/valkey-glide";

const results = await client.exec(
    new Batch(false).set("k1", "v1").incr("k1").get("k1"),
    true,  // raiseOnError
);
```

Cluster atomic batches require all keys to share a hash slot (use `{tag}` hash tags). Cluster non-atomic batches split per-slot automatically.

## `exec()` signatures

```typescript
// GlideClient:        exec(batch, raiseOnError, options?) - options: BatchOptions
// GlideClusterClient: exec(batch, raiseOnError, options?) - options: ClusterBatchOptions
// returns Promise<GlideReturnType[] | null>
```

`BatchOptions`: `{ timeout?: number }` (ms).
`ClusterBatchOptions`: adds `route` (single-node routing) and `retryStrategy` (non-atomic only).

Returns `null` when an atomic batch fails due to a WATCH conflict.

## `raiseOnError` semantics

- `true` - throws `RequestError` on first failure.
- `false` - errors appear inline as `RequestError` instances in the results array:

```typescript
const results = await client.exec(batch, false);
for (const r of results!) {
    if (r instanceof RequestError) { /* handle */ }
}
```

## Cluster retry strategy (non-atomic only)

```typescript
await clusterClient.exec(batch, true, {
    timeout: 5000,
    route: "randomNode",
    retryStrategy: {
        retryServerError: true,       // retry on TRYAGAIN etc.
        retryConnectionError: false,  // retry batch on connection failure
    },
});
```

Hazards:

- `retryServerError: true` may reorder commands targeting the same slot.
- `retryConnectionError: true` may cause duplicate executions - the server may have already processed the request before the connection died.
- Not supported on atomic batches.
- Raise `timeout` when enabling retries.

MOVED / ASK redirections are always handled automatically - non-atomic redirects only the affected commands; atomic redirects the entire transaction.

## WATCH

WATCH needs a dedicated client - it's a connection-state command and leaks across callers on the shared multiplexer. Inside a dedicated client, WATCH followed by an atomic batch returns `null` from `exec()` if a watched key was modified before the transaction runs.
