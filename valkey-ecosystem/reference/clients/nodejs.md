# Node.js Client Libraries

Use when building Node.js or TypeScript applications with Valkey, choosing between iovalkey and GLIDE Node.js, migrating from ioredis or node-redis, or integrating with BullMQ, Keyv, or Express Session.

---

> iovalkey, ioredis/node-redis compatibility, GLIDE Node.js, and migration paths.

## iovalkey (Official Valkey Fork)

iovalkey is the official Node.js client for Valkey, forked from ioredis. It provides the same battle-tested API with Valkey-native awareness.

### Install

```bash
npm install iovalkey
```

### Version

- **Current**: 0.3.3 (check npm for latest)
- **Node.js**: 14+
- **Server**: Valkey 7.2+
- **TypeScript**: Built-in type definitions
- **Downloads**: ~344K/week on npm (~2.2% of ioredis's ~16M/week)

**Staleness concern**: iovalkey has not had an npm publish since June 2025 (v0.3.3). The v0.x versioning suggests it has not reached 1.0 stability. For teams wanting an actively developed Valkey Node.js client, GLIDE Node.js (~250K/week) may be the stronger choice given its active release cadence.

### Basic Usage

```typescript
import Valkey from "iovalkey";

const client = new Valkey({
  host: "localhost",
  port: 6379,
});

await client.set("key", "value");
const result = await client.get("key");
```

### Key Features

- Full TypeScript support
- Cluster mode with automatic slot routing
- Sentinel support for high availability
- Streams API
- Pub/Sub
- Pipelines and transactions (MULTI/EXEC)
- Lua scripting
- TLS/SSL support
- Auto-reconnect with configurable retry strategy
- Connection pooling
- Binary-safe (Buffer support)

### Cluster Mode

```typescript
import { Cluster } from "iovalkey";

const cluster = new Cluster([
  { host: "node-1", port: 6379 },
  { host: "node-2", port: 6379 },
  { host: "node-3", port: 6379 },
]);

await cluster.set("key", "value");
```

### Pipelines

```typescript
const pipeline = client.pipeline();
pipeline.set("key1", "value1");
pipeline.set("key2", "value2");
pipeline.get("key1");
const results = await pipeline.exec();
```

## ioredis Compatibility

ioredis works with Valkey by changing only the server endpoint:

```typescript
import Redis from "ioredis";

// Point at Valkey instead of Redis
const client = new Redis({ host: "valkey-server", port: 6379 });
```

This works via RESP protocol compatibility. ioredis is community-maintained (15,243 stars, 297 open issues) and has no native Valkey awareness, but it remains fully functional for standard operations. Key gap: ioredis lacks AZ-affinity routing - a feature available in iovalkey and GLIDE natively.

## node-redis Compatibility

node-redis (the Redis-maintained official Node.js client) also works with Valkey by endpoint swap:

```typescript
import { createClient } from "redis";

const client = createClient({ url: "redis://valkey-server:6379" });
await client.connect();
```

Long-term compatibility is not guaranteed as Redis and Valkey diverge. node-redis will not expose Valkey-specific features. Users have reported CPU pegging with `createCluster()` against AWS ElastiCache Valkey clusters and connection issues in cluster mode that work fine with ioredis.

## Migration from ioredis to iovalkey

The migration is a straightforward package swap - iovalkey maintains API compatibility with ioredis.

### Step 1: Swap Package

```bash
npm uninstall ioredis
npm install iovalkey
```

### Step 2: Change Imports

```typescript
// Before
import Redis from "ioredis";
import { Cluster } from "ioredis";

// After
import Valkey from "iovalkey";
import { Cluster } from "iovalkey";
```

### Step 3: Update Constructor (optional)

```typescript
// Before
const client = new Redis({ host: "localhost", port: 6379 });

// After - either works
const client = new Valkey({ host: "localhost", port: 6379 });
```

### What Does Not Change

- All command methods (`set`, `get`, `hset`, `lpush`, etc.) are identical
- Pipeline and transaction APIs are identical
- Pub/Sub API is identical
- Cluster and Sentinel APIs are identical
- Event names and callback signatures are identical
- Lua scripting API is identical
- TypeScript types maintain the same shape

### Handling Both During Transition

If you need to support both ioredis and iovalkey during a gradual migration:

```typescript
let ClientClass;
try {
  ClientClass = (await import("iovalkey")).default;
} catch {
  ClientClass = (await import("ioredis")).default;
}
export default ClientClass;
```

## Valkey GLIDE for Node.js

GLIDE provides a Rust-core Node.js client with production-hardened connection management and AZ-affinity routing.

```bash
npm install @valkey/valkey-glide
```

```typescript
import { GlideClient, GlideClientConfiguration } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
  addresses: [{ host: "localhost", port: 6379 }],
});

await client.set("key", "value");
const result = await client.get("key");
```

GLIDE Node.js gets ~250K downloads/week on npm. Version 2.3.0 added dynamic PubSub support, mTLS, OpenTelemetry parent span propagation, and read-only mode. Combined with iovalkey, Valkey-native Node.js client downloads are ~594K/week.

For detailed GLIDE Node.js API coverage, connection management, cluster configuration, and advanced patterns, see the **valkey-glide** skill.

## Framework Integrations

### BullMQ

BullMQ works with Valkey as a drop-in Redis replacement:

```typescript
import { Queue, Worker } from "bullmq";

const queue = new Queue("tasks", {
  connection: { host: "valkey-server", port: 6379 },
});
```

BullMQ uses ioredis internally. It works with Valkey via RESP compatibility. A native GLIDE integration is not yet available.

### Keyv

The `@keyv/valkey` adapter uses iovalkey:

```typescript
import Keyv from "keyv";
import KeyvValkey from "@keyv/valkey";

const keyv = new Keyv({
  store: new KeyvValkey("valkey://localhost:6379"),
});
```

### Express Session

Express session stores that use ioredis or node-redis work with Valkey by endpoint swap:

```typescript
import session from "express-session";
import connectRedis from "connect-redis";

const store = new connectRedis({
  client: valkeyClient,  // iovalkey or ioredis instance
});
```

## Decision Guide

| Scenario | Recommendation |
|----------|---------------|
| New project on Valkey | GLIDE Node.js or iovalkey |
| Existing ioredis project, minimal effort | Change endpoint only |
| Existing ioredis project, long-term | Migrate to iovalkey or GLIDE |
| Existing node-redis project | Change endpoint; consider GLIDE or iovalkey for new code |
| Need AZ-affinity or managed service optimization | GLIDE Node.js |
| BullMQ project | ioredis with Valkey endpoint |
| Need TypeScript-first experience | iovalkey (built-in types) |
| Edge computing (Cloudflare Workers) | thin-redis (lightweight, edge-compatible) |

## Cross-References

- `clients/landscape.md` - overall client decision framework
- **valkey-glide** skill - GLIDE Node.js API details, connection management, batching
- `modules/overview.md` - module system; GLIDE Node.js provides `GlideJson` and `GlideFt` classes for JSON and Search modules
- `modules/bloom.md` - Bloom filter commands via `customCommand` in iovalkey or GLIDE
