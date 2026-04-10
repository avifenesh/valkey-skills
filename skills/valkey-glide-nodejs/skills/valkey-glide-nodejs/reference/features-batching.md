# Batching - Pipelines and Transactions (Node.js)

Use when you need to send multiple commands in a single round-trip for throughput or atomicity - pipelines for bulk operations, transactions for atomic multi-command blocks.

Requires: `@valkey/valkey-glide` 2.0+.

## Contents

- How Batching Differs from ioredis pipeline() (line 17)
- Batch vs ClusterBatch vs Transaction vs ClusterTransaction (line 32)
- Creating a Batch, Adding Commands, Executing (line 43)
- Error Handling in Batch Results (line 93)
- Complete Example: Batch Write 50 Products (line 140)
- Cluster Routing Behavior (line 201)
- Standalone-Only Commands (line 207)

## How Batching Differs from ioredis pipeline()

In ioredis you call `client.pipeline()` to get a chainable pipeline, then `.exec()`. In GLIDE, you construct a `Batch` or `ClusterBatch` object with an `isAtomic` flag, chain commands on it, then pass it to `client.exec()`. The same class handles both pipelines and transactions - the `isAtomic` constructor argument controls the mode.

| ioredis | GLIDE equivalent |
|---------|-----------------|
| `client.pipeline().set("k","v").get("k").exec()` | `client.exec(new Batch(false).set("k","v").get("k"), true)` |
| `client.multi().set("k","v").get("k").exec()` | `client.exec(new Batch(true).set("k","v").get("k"), true)` |

Key differences:

- GLIDE batches are standalone objects - you construct them, add commands, then hand them to the client.
- The `raiseOnError` parameter on `exec()` controls whether errors throw or appear inline in the results array.
- `Transaction` and `ClusterTransaction` still exist as deprecated aliases. Prefer `Batch` and `ClusterBatch`.

## Batch vs ClusterBatch vs Transaction vs ClusterTransaction

| Class | Client | isAtomic | Notes |
|-------|--------|----------|-------|
| `Batch` | `GlideClient` (standalone) | Constructor arg | Has `select()` for DB switching |
| `ClusterBatch` | `GlideClusterClient` | Constructor arg | Has `publish()` with sharded mode, `pubsubShardChannels()` |
| `Transaction` | `GlideClient` | Always `true` | **Deprecated** - alias for `new Batch(true)` |
| `ClusterTransaction` | `GlideClusterClient` | Always `true` | **Deprecated** - alias for `new ClusterBatch(true)` |

All four extend `BaseBatch<T>` which provides the full command set (GET, SET, HSET, LPUSH, ZADD, etc.) with fluent chaining - every command method returns `this`.

## Creating a Batch, Adding Commands, Executing

```typescript
import { GlideClient, Batch } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({ addresses: [{ host: "localhost", port: 6379 }] });

// Non-atomic pipeline
const result = await client.exec(
    new Batch(false).set("key1", "value1").set("key2", "value2").get("key1").get("key2"),
    true,
);
// result: ["OK", "OK", "value1", "value2"]

// Atomic transaction
const txResult = await client.exec(
    new Batch(true).set("account:src", "100").incrBy("account:src", 50),
    true,
);
// txResult: ["OK", 150]
```

### Cluster mode

```typescript
import { GlideClusterClient, ClusterBatch } from "@valkey/valkey-glide";

const clusterClient = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 7000 }],
});

// Non-atomic - keys can span different hash slots
const result = await clusterClient.exec(
    new ClusterBatch(false).set("user:1:name", "Alice").set("user:2:name", "Bob").get("user:1:name"),
    true,
);
// result: ["OK", "OK", "Alice"]
```

### exec() signature

```typescript
// GlideClient
client.exec(batch: Batch, raiseOnError: boolean, options?: BatchOptions): Promise<GlideReturnType[] | null>
// GlideClusterClient
clusterClient.exec(batch: ClusterBatch, raiseOnError: boolean, options?: ClusterBatchOptions): Promise<GlideReturnType[] | null>
```

`BatchOptions` has a `timeout` field (milliseconds). `ClusterBatchOptions` adds `route` (single-node routing) and `retryStrategy`. If an atomic batch fails due to a `WATCH` command, `exec()` returns `null`.

## Error Handling in Batch Results

The `raiseOnError` parameter controls error behavior:

| Value | Behavior |
|-------|----------|
| `true` | Throws `RequestError` on the first error encountered in the batch |
| `false` | Errors appear as `RequestError` instances in the results array |

```typescript
import { RequestError, Batch } from "@valkey/valkey-glide";

const batch = new Batch(false)
    .set("key", "value")
    .lpush("key", ["oops"])  // WRONGTYPE - key holds a string
    .get("key");

// raiseOnError = false: errors inline
const results = await client.exec(batch, false);
for (const item of results!) {
    if (item instanceof RequestError) {
        console.log(`Command failed: ${item.message}`);
    } else {
        console.log(`Success: ${item}`);
    }
}
// Success: OK
// Command failed: WRONGTYPE Operation against a key holding the wrong kind of value
// Success: value

// raiseOnError = true: throws on first error
try { await client.exec(batch, true); }
catch (err) { if (err instanceof RequestError) console.log(err.message); }
```

### Cluster retry strategy (non-atomic only)

```typescript
const result = await clusterClient.exec(
    new ClusterBatch(false).set("k1", "v1").set("k2", "v2"), true,
    {
        timeout: 5000, route: "randomNode",
        retryStrategy: { retryServerError: true, retryConnectionError: false },
    },
);
```

## Complete Example: Batch Write 50 Products

```typescript
import { GlideClusterClient, ClusterBatch, RequestError } from "@valkey/valkey-glide";

interface Product {
    id: number;
    name: string;
    price: number;
    category: string;
    stock: number;
}

async function batchWriteProducts(
    client: GlideClusterClient,
    products: Product[],
): Promise<void> {
    // Use non-atomic batch - products have different hash slots
    const batch = new ClusterBatch(false);

    for (const p of products) {
        const key = `product:{catalog}:${p.id}`;
        batch.hset(key, {
            name: p.name,
            price: String(p.price),
            category: p.category,
            stock: String(p.stock),
        });
        // Add to category set for lookups
        batch.sadd(`category:{catalog}:${p.category}`, [key]);
    }

    const results = await client.exec(batch, false, { timeout: 10000 });

    if (!results) {
        throw new Error("Batch returned null");
    }

    let errors = 0;
    for (const r of results) {
        if (r instanceof RequestError) errors++;
    }

    if (errors > 0) {
        console.log(`[WARN] ${errors} commands failed out of ${results.length}`);
    } else {
        console.log(`[OK] Wrote ${products.length} products (${results.length} commands)`);
    }
}

// Usage
const products: Product[] = Array.from({ length: 50 }, (_, i) => ({
    id: i + 1, name: `Widget ${i + 1}`, price: 9.99 + i,
    category: ["electronics", "clothing", "home"][i % 3], stock: 100 + i * 10,
}));
await batchWriteProducts(client, products);
// [OK] Wrote 50 products (100 commands)
```

The `{catalog}` hash tag ensures HSET and SADD for each product route to the same slot, which matters if you later wrap them in an atomic batch. For non-atomic batches, hash tags are optional - GLIDE auto-splits commands across nodes.

## Cluster Routing Behavior

- **Atomic (transaction)**: routed to the slot owner of the first key. All keys must share the same slot or the transaction fails.
- **Non-atomic (pipeline)**: each command routes independently by key slot. Multi-node commands are split across nodes and responses are reassembled in order.
- MOVED/ASK redirections are handled automatically. Non-atomic batches redirect only the affected commands; atomic batches redirect the entire transaction.

## Standalone-Only Commands

`Batch` (standalone) exposes `select(index)` for switching databases within a batch. This is not available on `ClusterBatch`.
