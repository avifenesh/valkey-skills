---
name: valkey-glide-nodejs
description: "Use when building Node.js or TypeScript applications with Valkey GLIDE. Covers Promise API, GlideClient, TypeScript types, ESM/CJS, TLS, authentication, OpenTelemetry, batching, PubSub, streams, Lua scripting, server modules (JSON/Search), and migration from ioredis."
version: 1.0.0
last-verified: 2026-03-30
argument-hint: "[API, config, or migration question]"
---

# Valkey GLIDE Node.js Client

Self-contained guide for building Node.js and TypeScript applications with Valkey GLIDE. For architecture concepts shared across all languages, see the `valkey-glide` skill.

## Routing

- Install/setup -> Installation
- TypeScript types -> Client Classes
- TLS/auth -> TLS and Authentication
- Streams/PubSub -> Streams, PubSub sections
- Error handling -> Error Handling
- Batching -> Batching
- Lua scripting -> Lua Scripting
- JSON/Search modules -> Server Modules
- ioredis migration -> Migration from ioredis
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

## Migration from ioredis

### Key Differences

| Area | ioredis | GLIDE |
|------|---------|-------|
| Hash args | Spread pairs: `hset("h", "k1", "v1")` | Object: `hset("h", {k1: "v1"})` |
| Sorted set args | Interleaved: `zadd("z", 1, "a")` | Objects: `zadd("z", [{element: "a", score: 1}])` |
| Expiry | `setex`, `psetex` | Options on `set()` |
| Multi-arg commands | Varargs / rest params | Array arguments |
| Connection model | Pool or single | Single multiplexed per node |
| Script caching | Manual `defineCommand` | Automatic via `Script` class |
| Events | EventEmitter: `on("error")` | No emitter - errors per-command |
| Pipeline results | `[[error, result], ...]` | Flat array of results |

### Side-by-Side: Connection Setup

**ioredis:**
```javascript
const Redis = require("ioredis");
const redis = new Redis({ host: "localhost", port: 6379 });
await redis.ping();
```

**GLIDE:**
```typescript
import { GlideClient } from "@valkey/valkey-glide";
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 5000,
});
await client.ping();
```

### Side-by-Side: String Operations

**ioredis:**
```javascript
await redis.set("key", "value");
await redis.set("key", "value", "EX", 60);
await redis.set("key", "value", "NX");
const val = await redis.get("key");
```

**GLIDE:**
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
```

### Side-by-Side: Sorted Sets

**ioredis:**
```javascript
await redis.zadd("zset", 1, "alice", 2, "bob");
```

**GLIDE:**
```typescript
await client.zadd("zset", [
    { element: "alice", score: 1 },
    { element: "bob", score: 2 },
]);
```

### Side-by-Side: Lua Scripting

**ioredis:**
```javascript
redis.defineCommand("mycommand", {
    numberOfKeys: 1,
    lua: "return redis.call('GET', KEYS[1])",
});
const result = await redis.mycommand("key1");
```

**GLIDE:**
```typescript
import { Script } from "@valkey/valkey-glide";
const script = new Script("return redis.call('GET', KEYS[1])");
const result = await client.invokeScript(script, { keys: ["key1"] });
```

### Side-by-Side: Cluster Mode

**ioredis:**
```javascript
const cluster = new Redis.Cluster([
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
], { scaleReads: "slave" });
```

**GLIDE:**
```typescript
import { GlideClusterClient } from "@valkey/valkey-glide";
const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "node1.example.com", port: 6379 },
        { host: "node2.example.com", port: 6380 },
    ],
    readFrom: "preferReplica",
});
```

### Incremental Migration Strategy

1. Install `@valkey/valkey-glide` alongside `ioredis`
2. Create a wrapper module abstracting the client interface
3. Migrate route handlers or services one at a time
4. Use GLIDE Batch API for operations previously handled by ioredis pipelines
5. Swap the wrapper implementation once all call sites are migrated
6. Remove `ioredis` dependency

No drop-in compatibility layer exists for Node.js.


## Streams

### Adding and Reading

```typescript
// Add entries
const entryId = await client.xadd("mystream", [
    ["sensor", "temp"], ["value", "23.5"],
]);

// Add with trimming
const entryId2 = await client.xadd("mystream",
    [["data", "value"]],
    { trim: { method: "maxlen", threshold: 1000, exact: false } },
);

// Read from streams
const entries = await client.xread({ mystream: "0" });

// Read with blocking and count
const entries2 = await client.xread(
    { mystream: "0" },
    { count: 10, block: 5000 },
);
```

### Range Queries

```typescript
const range = await client.xrange("mystream", "-", "+");
const rangeLimit = await client.xrange("mystream", "-", "+", 100);
const revRange = await client.xrevrange("mystream", "+", "-");
const length = await client.xlen("mystream");
```

### Consumer Groups

```typescript
// Create group
await client.xgroupCreate("mystream", "mygroup", "0", { mkStream: true });

// Read as consumer
const messages = await client.xreadgroup("mygroup", "consumer1", {
    mystream: ">",
}, { count: 10, block: 5000 });

// Acknowledge
const ackCount = await client.xack("mystream", "mygroup", ["1234567890123-0"]);

// Inspect pending
const pending = await client.xpending("mystream", "mygroup");

// Auto-claim idle entries
const claimed = await client.xautoclaim(
    "mystream", "mygroup", "consumer2", 60000, "0",
);
```

Use a dedicated client for blocking XREAD/XREADGROUP to avoid blocking the multiplexed connection.

---

## OpenTelemetry Configuration

```typescript
import { OpenTelemetry } from "@valkey/valkey-glide";
import { trace } from "@opentelemetry/api";

OpenTelemetry.init({
    traces: {
        endpoint: "http://localhost:4318/v1/traces",
        samplePercentage: 10,
    },
    metrics: {
        endpoint: "http://localhost:4318/v1/metrics",
    },
    flushIntervalMs: 1000,
    parentSpanContextProvider: () => {
        const span = trace.getActiveSpan();
        if (!span) return undefined;
        const ctx = span.spanContext();
        return {
            traceId: ctx.traceId,
            spanId: ctx.spanId,
            traceFlags: ctx.traceFlags,
            traceState: ctx.traceState?.toString(),
        };
    },
});

// Runtime adjustment
OpenTelemetry.setSamplePercentage(5);
const pct = OpenTelemetry.getSamplePercentage();
const initialized = OpenTelemetry.isInitialized();
```

The `parentSpanContextProvider` links GLIDE command spans to your application spans for end-to-end distributed tracing. OTel can only be initialized once per process.

---

## TLS Configuration

### Basic TLS

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
});
```

### Custom CA Certificates

```typescript
import { readFileSync } from "fs";

const caCert = readFileSync("/path/to/ca.pem");

const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
    advancedConfiguration: {
        tlsAdvancedConfiguration: {
            rootCertificates: caCert,
        },
    },
});
```

### Insecure TLS (Development Only)

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
    advancedConfiguration: {
        tlsAdvancedConfiguration: { insecure: true },
    },
});
```

### TLS + Auth Combined

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
    credentials: { username: "myuser", password: "mypass" },
    advancedConfiguration: {
        tlsAdvancedConfiguration: {
            rootCertificates: caCert,
        },
    },
});
```

---

## PubSub Patterns

```typescript
// Separate subscriber and publisher clients
const subscriber = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
});
const publisher = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
});

// Dynamic subscribe (GLIDE 2.3+)
subscriber.subscribeLazy(["news", "events"]);

// Publish
await publisher.publish("Hello subscribers!", "events");

// Unsubscribe
subscriber.unsubscribeLazy(["news"]);
```

Always use a dedicated client for subscriptions - it enters subscriber mode where regular commands are unavailable.

---

## Batch Error Handling

```typescript
import { Batch, RequestError } from "@valkey/valkey-glide";

const batch = new Batch(false);
batch.set("k1", "v1");
batch.get("nonexistent");
batch.incr("k1");  // will fail - not numeric

// raiseOnError=false returns errors inline
const results = await client.exec(batch, false);
// results[2] is a RequestError

// raiseOnError=true throws on first error
try {
    const results2 = await client.exec(batch, true);
} catch (error) {
    if (error instanceof RequestError) {
        console.error(`Batch failed: ${error.message}`);
    }
}
```

---

## GLIDE-Only Features in Node.js

### AZ Affinity

```typescript
const client = await GlideClusterClient.createClient({
    addresses: [{ host: "node1.example.com", port: 6379 }],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",
});
```

Requires Valkey 8.0+. See the `valkey-glide` skill for cross-language AZ Affinity details.

---

## Exports

The main entry point (`@valkey/valkey-glide`) exports:

- `GlideClient`, `GlideClusterClient` - client classes
- `BaseClient` - shared base with all data commands
- `Batch`, `ClusterBatch` - batching/pipeline support
- `Commands` - command option types and factories
- `Errors` - error classes
- `Logger` - GLIDE logging configuration
- `OpenTelemetry` - tracing and metrics configuration
- Server modules: `GlideFt` (search), `GlideJson` (JSON)

---

## Ecosystem Integrations

- `@fastify/valkey-glide` - official Fastify plugin for caching and session management
- `rate-limiter-flexible` - rate limiting with GLIDE backend
- `redlock-universal` - distributed locks with native GLIDE adapter
- `aws-lambda-powertools-typescript` - idempotency feature integration

---

## Architecture Notes

- **Communication layer**: napi-rs (NAPI v2) - native Rust bindings for Node.js
- Protobuf serialization for command requests and responses
- Single multiplexed connection per node
- All command methods return `Promise<T>`
- TypeScript types bundled - no separate `@types` package

---

## Gotchas

1. **Hash argument format.** ioredis accepts spread key-value pairs (`"k1", "v1", "k2", "v2"`). GLIDE requires an object `{k1: "v1"}` or `HashDataType` array.

2. **Sorted set format.** ioredis uses interleaved score, member pairs. GLIDE uses `{element, score}` objects or a `Record<string, number>` map.

3. **No setex/psetex/setnx.** Use `set()` with the `expiry` and `conditionalSet` options.

4. **Array args for multi-key commands.** `del`, `exists`, `lpush`, `sadd` all take arrays, not rest parameters.

5. **Pipeline result format.** ioredis returns `[[error, result], ...]`. GLIDE returns a flat array. Errors are thrown or returned as `RequestError` objects depending on the `raiseOnError` flag.

6. **No event emitter.** If you relied on `on("error")` for monitoring, handle errors per-command or set up external health checks.

7. **protobufjs bundle size.** GLIDE depends on protobufjs (~19KB gzipped). This can affect cold start times in serverless deployments.

8. **npm version on Linux.** npm 11+ recommended for correct libc-based optional dependency resolution. Older npm may pull the wrong native binary.

9. **Dynamic PubSub requires GLIDE 2.3+.** Before 2.3, subscriptions must be defined at connection time.

---

## Cross-References

- `valkey-glide` skill - architecture, connection model, features shared across all languages
- `valkey` skill - Valkey server commands, data types, patterns
