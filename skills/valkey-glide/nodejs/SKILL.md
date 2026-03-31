---
name: valkey-glide-nodejs
description: "Use when building Node.js or TypeScript applications with Valkey GLIDE. Covers Promise API, GlideClient, TypeScript types, ESM/CJS, TLS, authentication, OpenTelemetry, batching, PubSub, streams, Lua scripting, server modules (JSON/Search)."
version: 1.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Node.js Client

Self-contained guide for building Node.js and TypeScript applications with Valkey GLIDE.

## Routing

- Install/setup -> Installation
- TypeScript types -> Client Classes
- TLS/auth -> TLS and Authentication
- Streams/PubSub -> Streams, PubSub sections
- Error handling -> Error Handling
- Batching -> Batching
- Lua scripting -> Lua Scripting
- JSON/Search modules -> Server Modules
- OTel/tracing -> OpenTelemetry

## Installation

```bash
npm install @valkey/valkey-glide
```

**Requirements:** Node.js 16+

**Platform support:** Linux glibc (x86_64, arm64), Linux musl/Alpine (x86_64, arm64), macOS (Apple Silicon, x86_64). No Windows support.

npm >= 11 is recommended on Linux for correct optional dependency handling based on libc detection.

Supports both ESM and CommonJS. TypeScript definitions are included - no `@types/` package needed.

---

## Client Classes

| Class | Mode | Description |
|-------|------|-------------|
| `GlideClient` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | Cluster | Valkey Cluster with auto-topology |

Both extend `BaseClient` and are created via `createClient()`.

---

## Standalone Connection (ESM + TypeScript)

```typescript
import { GlideClient } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 5000,
});

try {
    await client.set("greeting", "Hello from GLIDE");
    const value = await client.get("greeting");
    console.log(`Got: ${value}`);
} finally {
    client.close();
}
```

## Standalone Connection (CommonJS)

```javascript
const { GlideClient } = require("@valkey/valkey-glide");

async function main() {
    const client = await GlideClient.createClient({
        addresses: [{ host: "localhost", port: 6379 }],
    });

    await client.set("key", "value");
    const value = await client.get("key");
    console.log(value);

    client.close();
}
main();
```

---

## Cluster Connection

```typescript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "node1.example.com", port: 6379 },
        { host: "node2.example.com", port: 6380 },
    ],
    readFrom: "preferReplica",
});

await client.set("key", "value");
const value = await client.get("key");

client.close();
```

Only seed addresses needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration - Standalone

```typescript
import {
    GlideClient,
    GlideClientConfiguration,
    ProtocolVersion,
} from "@valkey/valkey-glide";

const config: GlideClientConfiguration = {
    addresses: [{ host: "localhost", port: 6379 }],
    useTLS: true,
    credentials: {
        username: "myuser",
        password: "mypass",
    },
    readFrom: "preferReplica",
    requestTimeout: 5000,
    connectionBackoff: {
        numberOfRetries: 5,
        factor: 1000,
        exponentBase: 2,
        jitterPercent: 20,
    },
    databaseId: 0,
    clientName: "my-app",
    protocol: ProtocolVersion.RESP3,
    inflightRequestsLimit: 1000,
    readOnly: false,
};

const client = await GlideClient.createClient(config);
```

## Configuration - Cluster

```typescript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [{ host: "node1.example.com", port: 6379 }],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",
    periodicChecks: { duration_in_sec: 30 },
});
```

---

## Authentication

### Password-Based

```typescript
const config = {
    addresses: [{ host: "localhost", port: 6379 }],
    credentials: {
        username: "myuser",
        password: "mypass",
    },
};
```

### IAM Authentication (AWS ElastiCache / MemoryDB)

```typescript
import { GlideClusterClient, ServiceType } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [{ host: "my-cluster.amazonaws.com", port: 6379 }],
    useTLS: true,
    credentials: {
        username: "myIamUser",
        iamAuthentication: {
            clusterName: "my-cluster",
            service: ServiceType.Elasticache, // or ServiceType.MemoryDB
            region: "us-east-1",
        },
    },
});
```

Password and IAM are mutually exclusive. GLIDE handles automatic token refresh using the default AWS credential chain.

---

## ReadFrom Options

| Value | Behavior |
|-------|----------|
| `"primary"` | All reads to primary (default) |
| `"preferReplica"` | Round-robin replicas, fallback to primary |
| `"AZAffinity"` | Prefer same-AZ replicas (requires `clientAz`) |
| `"AZAffinityReplicasAndPrimary"` | Same-AZ replicas, then primary, then remote |

AZ Affinity requires Valkey 8.0+ and `clientAz` must be set.

---

## Error Handling

| Error | Description |
|-------|-------------|
| `RequestError` | Base for request-level failures |
| `TimeoutError` | Request exceeded `requestTimeout` |
| `ConnectionError` | Connection lost (auto-reconnects) |
| `ClosingError` | Client closed, no longer usable |
| `ExecAbortError` | Transaction aborted (WATCH key changed) |
| `ConfigurationError` | Invalid client configuration |

```typescript
import {
    RequestError,
    TimeoutError,
    ConnectionError,
} from "@valkey/valkey-glide";

try {
    const value = await client.get("key");
} catch (error) {
    if (error instanceof TimeoutError) {
        console.error("Request timed out");
    } else if (error instanceof ConnectionError) {
        console.error("Connection lost - reconnecting");
    } else if (error instanceof RequestError) {
        console.error(`Request failed: ${error.message}`);
    }
}
```

No EventEmitter interface. Errors surface per-command as rejected promises.

---

## Type System

| Type | Description |
|------|-------------|
| `GlideString` | `string \| Buffer` - binary-safe string type |
| `GlideReturnType` | Union of all possible return types |
| `GlideRecord<T>` | Record type for key-value pairs |
| `Decoder` | Enum for response decoding (`String`, `Bytes`) |

---

## Data Type Operations

### Strings

```typescript
import { TimeUnit } from "@valkey/valkey-glide";

await client.set("key", "value");
await client.set("key", "value", {
    expiry: { type: TimeUnit.Seconds, count: 60 },
});
await client.set("key", "value", {
    conditionalSet: "onlyIfDoesNotExist",
});
const val = await client.get("key");
const count = await client.incr("counter");
const count2 = await client.incrBy("counter", 5);
await client.mset({ k1: "v1", k2: "v2" });
const vals = await client.mget(["k1", "k2"]);
```

No separate `setex`/`setnx` - use `set()` with options.

### Hashes

```typescript
await client.hset("hash", { f1: "v1", f2: "v2" });
await client.hset("hash", [
    { field: "f1", value: "v1" },
    { field: "f2", value: "v2" },
]);
const val = await client.hget("hash", "f1");
const all = await client.hgetall("hash");    // Record<string, string>
const exists = await client.hexists("hash", "f1");
await client.hdel("hash", ["f1"]);
const keys = await client.hkeys("hash");
const vals = await client.hvals("hash");
const length = await client.hlen("hash");
```

### Lists

```typescript
await client.lpush("list", ["a", "b", "c"]);  // array arg
await client.rpush("list", ["x", "y"]);
const val = await client.lpop("list");
const range = await client.lrange("list", 0, -1);
const length = await client.llen("list");
await client.lset("list", 0, "new_value");
await client.ltrim("list", 0, 99);
```

### Sets

```typescript
await client.sadd("set", ["a", "b", "c"]);    // array arg
await client.srem("set", ["a", "b"]);
const members = await client.smembers("set");
const isMember = await client.sismember("set", "b");
const card = await client.scard("set");
const inter = await client.sinter(["set1", "set2"]);
```

### Sorted Sets

```typescript
import { ConditionalChange } from "@valkey/valkey-glide";

await client.zadd("zset", [
    { element: "alice", score: 1 },
    { element: "bob", score: 2 },
]);
const score = await client.zscore("zset", "alice");
const rank = await client.zrank("zset", "alice");
const card = await client.zcard("zset");
await client.zrem("zset", ["alice"]);
const range = await client.zrangeWithScores("zset", { start: 0, end: -1 });
```

### Delete and Exists

```typescript
await client.del(["k1", "k2", "k3"]);         // array arg
const count = await client.exists(["k1", "k2"]);
await client.expire("key", 60);
const ttl = await client.ttl("key");
const keyType = await client.type("key");
```

---

## Batching

### Transaction (Atomic)

```typescript
import { Batch } from "@valkey/valkey-glide";

const tx = new Batch(true)
    .set("key", "value")
    .incr("counter")
    .get("key");
const result = await client.exec(tx, true);
// ["OK", 1, "value"]
```

### Pipeline (Non-Atomic)

```typescript
const batch = new Batch(false)
    .set("k1", "v1")
    .set("k2", "v2")
    .get("k1");
const result = await client.exec(batch, false);
```

For cluster mode, use `ClusterBatch`.

---

## Lua Scripting

```typescript
import { Script } from "@valkey/valkey-glide";

const script = new Script("return redis.call('GET', KEYS[1])");
const result = await client.invokeScript(script, { keys: ["key1"] });
```

No manual SHA management. GLIDE caches the script automatically.

---

## Server Modules (JSON and Vector Search)

Requires JSON and Search modules loaded on the Valkey server. Use `GlideJson` for JSON document operations and `GlideFt` for search/vector indexing. Both use `customCommand` internally and work with standalone and cluster clients.

### JSON - Store and Retrieve Documents

```typescript
import { GlideJson } from "@valkey/valkey-glide";

// Store a JSON document
await GlideJson.set(client, "user:1", "$", JSON.stringify({
    name: "Alice", age: 30, tags: ["admin"],
}));

// Read a nested value (JSONPath returns a JSON array string)
const name = await GlideJson.get(client, "user:1", { path: "$.name" });
// '["Alice"]'

// Increment a numeric field
await GlideJson.numincrby(client, "user:1", "$.age", 1);

// Append to an array
await GlideJson.arrappend(client, "user:1", "$.tags", ['"developer"']);
```

### Vector Search - Create Index and Search

```typescript
import { GlideFt } from "@valkey/valkey-glide";

// Create an index on HASH keys with text and tag fields
await GlideFt.create(client, "article_idx", [
    { type: "TEXT", name: "title" },
    { type: "TAG", name: "category" },
], { dataType: "HASH", prefixes: ["article:"] });

// Search by tag filter
const results = await GlideFt.search(client, "article_idx", "@category:{tech}");
// results[0] = total count, results[1] = document records
```

---

<!-- SHARED-GLIDE-SECTION: keep in sync with valkey-glide/SKILL.md -->

## Architecture

| Topic | Reference |
|-------|-----------|
| Three-layer design: Rust core, Protobuf IPC, language FFI bridges | [overview](reference/architecture/overview.md) |
| Multiplexed connections, inflight limits, request timeout, reconnect logic | [connection-model](reference/architecture/connection-model.md) |
| Cluster slot routing, MOVED/ASK handling, multi-slot splitting, ReadFrom | [cluster-topology](reference/architecture/cluster-topology.md) |


## Features

| Topic | Reference |
|-------|-----------|
| Batch API: atomic (MULTI/EXEC) and non-atomic (pipeline) modes | [batching](reference/features/batching.md) |
| PubSub: exact, pattern, and sharded subscriptions, dynamic callbacks | [pubsub](reference/features/pubsub.md) |
| Scripting: Lua EVAL/EVALSHA with SHA1 caching, FCALL Functions | [scripting](reference/features/scripting.md) |
| OpenTelemetry: per-command tracing spans, metrics export | [opentelemetry](reference/features/opentelemetry.md) |
| AZ affinity: availability-zone-aware read routing, cross-zone savings | [az-affinity](reference/features/az-affinity.md) |
| TLS, mTLS, custom CA certificates, password auth, IAM tokens | [tls-auth](reference/features/tls-auth.md) |
| Compression: transparent Zstd/LZ4 for large values (SET/GET) | [compression](reference/features/compression.md) |
| Streams: XADD, XREAD, XREADGROUP, consumer groups, XCLAIM, XAUTOCLAIM | [streams](reference/features/streams.md) |
| Server modules: GlideJson (JSON), GlideFt (Search/Vector) | [server-modules](reference/features/server-modules.md) |
| Logging: log levels, file rotation, GLIDE_LOG_DIR, debug output | [logging](reference/features/logging.md) |
| Geospatial: GEOADD, GEOSEARCH, GEODIST, proximity queries | [geospatial](reference/features/geospatial.md) |
| Bitmaps and HyperLogLog: BITCOUNT, BITFIELD, PFADD, PFCOUNT | [bitmaps-hyperloglog](reference/features/bitmaps-hyperloglog.md) |
| Hash field expiration: HSETEX, HGETEX, HEXPIRE (Valkey 9.0+) | [hash-field-expiration](reference/features/hash-field-expiration.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Performance: benchmarks, GLIDE vs native clients, batching throughput | [performance](reference/best-practices/performance.md) |
| Error handling: exception types, reconnection, retry, batch errors | [error-handling](reference/best-practices/error-handling.md) |
| Production: timeout config, connection management, cloud defaults | [production](reference/best-practices/production.md) |

<!-- END SHARED-GLIDE-SECTION -->

## Cross-References

- `valkey` skill - Valkey server commands, data types, patterns
