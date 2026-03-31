---
name: migrate-ioredis
description: "Use when migrating Node.js applications from ioredis to Valkey GLIDE. Covers API mapping, configuration changes, connection setup, error handling differences, and common migration gotchas."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from ioredis to Valkey GLIDE (Node.js)

Use when migrating a Node.js application from ioredis to the GLIDE client library.

---

## Key Differences

| Area | ioredis | GLIDE |
|------|---------|-------|
| Hash args | Spread pairs: hset("h", "k1", "v1", "k2", "v2") | Object: hset("h", {k1: "v1", k2: "v2"}) |
| Sorted set args | Interleaved: zadd("z", 1, "a", 2, "b") | Array of objects: zadd("z", [{element: "a", score: 1}]) |
| Expiry | Separate commands: setex, psetex | Options on set(): {expiry: {type, count}} |
| Multi-arg commands | Varargs or rest params | Array arguments |
| Connection model | Connection pool or single | Single multiplexed connection per node |
| Cluster | new Redis.Cluster([...]) | GlideClusterClient.createClient({...}) |
| Script caching | Manual defineCommand | Automatic via Script class |
| Events | EventEmitter (on("error")) | No event emitter - errors surface per-command |

---

## Connection Setup

**ioredis:**
```javascript
const Redis = require("ioredis");
const redis = new Redis({ host: "localhost", port: 6379 });
await redis.ping();
```

**GLIDE:**
```javascript
import { GlideClient } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 5000,
});
await client.ping();
```

---

## Configuration Mapping

| ioredis parameter | GLIDE equivalent |
|-------------------|------------------|
| host, port | addresses: [{host, port}] |
| db | databaseId |
| password | credentials: {password} |
| username | credentials: {username, password} |
| connectTimeout | requestTimeout (covers full lifecycle) |
| tls: {} | useTls: true |
| retryStrategy | Built-in reconnection with connectionBackoff |
| maxRetriesPerRequest | Not applicable - GLIDE handles retries internally |
| lazyConnect: true | Default behavior in GLIDE |

---

## String Operations

**ioredis:**
```javascript
await redis.set("key", "value");
await redis.set("key", "value", "EX", 60);
await redis.set("key", "value", "NX");
await redis.setex("key", 60, "value");
const val = await redis.get("key");
```

**GLIDE:**
```javascript
import { TimeUnit } from "@valkey/valkey-glide";

await client.set("key", "value");
await client.set("key", "value", { expiry: { type: TimeUnit.Seconds, count: 60 } });
await client.set("key", "value", { conditionalSet: "onlyIfDoesNotExist" });
// No separate setex - use set() with expiry option
const val = await client.get("key");
```

---

## Hash Operations

**ioredis:**
```javascript
await redis.hset("hash", "f1", "v1", "f2", "v2");    // spread pairs
await redis.hset("hash", { f1: "v1", f2: "v2" });     // also works
const val = await redis.hget("hash", "f1");
const all = await redis.hgetall("hash");                // {f1: "v1", f2: "v2"}
```

**GLIDE:**
```javascript
// Object form or HashDataType array form
await client.hset("hash", { f1: "v1", f2: "v2" });
await client.hset("hash", [{ field: "f1", value: "v1" }, { field: "f2", value: "v2" }]);
const val = await client.hget("hash", "f1");
const all = await client.hgetall("hash");               // Record<string, string>
```

---

## List Operations

**ioredis:**
```javascript
await redis.lpush("list", "a", "b", "c");
await redis.rpush("list", "x", "y");
const val = await redis.lpop("list");
const range = await redis.lrange("list", 0, -1);
```

**GLIDE:**
```javascript
await client.lpush("list", ["a", "b", "c"]);            // array arg
await client.rpush("list", ["x", "y"]);
const val = await client.lpop("list");
const range = await client.lrange("list", 0, -1);
```

---

## Set Operations

**ioredis:**
```javascript
await redis.sadd("set", "a", "b", "c");
await redis.srem("set", "a", "b");
const members = await redis.smembers("set");
```

**GLIDE:**
```javascript
await client.sadd("set", ["a", "b", "c"]);              // array arg
await client.srem("set", ["a", "b"]);
const members = await client.smembers("set");
```

---

## Sorted Set Operations

**ioredis:**
```javascript
await redis.zadd("zset", 1, "alice", 2, "bob");         // score, member pairs
await redis.zadd("zset", "NX", 1, "alice");              // NX flag
const score = await redis.zscore("zset", "alice");
const range = await redis.zrange("zset", 0, -1, "WITHSCORES");
```

**GLIDE:**
```javascript
import { ConditionalChange } from "@valkey/valkey-glide";

// Array of {element, score} objects or Record<string, number>
await client.zadd("zset", [
    { element: "alice", score: 1 },
    { element: "bob", score: 2 },
]);
await client.zadd("zset", { alice: 1 }, { conditionalChange: ConditionalChange.ONLY_IF_DOES_NOT_EXIST });
const score = await client.zscore("zset", "alice");
const range = await client.zrangeWithScores("zset", { start: 0, end: -1 });
```

---

## Delete and Exists

**ioredis:**
```javascript
await redis.del("k1", "k2", "k3");
const count = await redis.exists("k1", "k2");
```

**GLIDE:**
```javascript
await client.del(["k1", "k2", "k3"]);                   // array arg
const count = await client.exists(["k1", "k2"]);
```

---

## Cluster Mode

**ioredis:**
```javascript
const cluster = new Redis.Cluster([
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
], { scaleReads: "slave" });
```

**GLIDE:**
```javascript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "node1.example.com", port: 6379 },
        { host: "node2.example.com", port: 6380 },
    ],
    readFrom: "preferReplica",
});
```

GLIDE auto-discovers the full topology from seed nodes. No natMap or manual slot configuration needed.

---

## Lua Scripting

**ioredis:**
```javascript
// Manual defineCommand
redis.defineCommand("mycommand", {
    numberOfKeys: 1,
    lua: "return redis.call('GET', KEYS[1])",
});
const result = await redis.mycommand("key1");

// Or evalsha manually
const sha = await redis.script("LOAD", luaScript);
const result2 = await redis.evalsha(sha, 1, "key1");
```

**GLIDE:**
```javascript
import { Script } from "@valkey/valkey-glide";

// Automatic caching - SCRIPT LOAD on first call, EVALSHA on subsequent
const script = new Script("return redis.call('GET', KEYS[1])");
const result = await client.invokeScript(script, { keys: ["key1"] });
```

No manual SHA management. GLIDE caches the script automatically and uses EVALSHA on repeat calls.

---

## Pipelines and Transactions

**ioredis:**
```javascript
// Pipeline
const pipeline = redis.pipeline();
pipeline.set("k1", "v1");
pipeline.get("k1");
const results = await pipeline.exec();  // [[null, "OK"], [null, "v1"]]

// Transaction
const multi = redis.multi();
multi.set("k1", "v1");
multi.get("k1");
const results2 = await multi.exec();    // [[null, "OK"], [null, "v1"]]
```

**GLIDE:**
```javascript
import { Batch } from "@valkey/valkey-glide";

// Transaction (atomic)
const tx = new Batch(true);
tx.set("k1", "v1");
tx.get("k1");
const results = await client.exec(tx, false);  // ["OK", "v1"]

// Pipeline (non-atomic)
const pipe = new Batch(false);
pipe.set("k1", "v1");
pipe.get("k1");
const results2 = await client.exec(pipe, false);  // ["OK", "v1"]
```

Note: GLIDE returns flat result arrays, not the [error, result] tuple format that ioredis uses.

---

## Event Handling

**ioredis:**
```javascript
redis.on("error", (err) => console.error("Connection error:", err));
redis.on("connect", () => console.log("Connected"));
redis.on("close", () => console.log("Disconnected"));
redis.on("reconnecting", () => console.log("Reconnecting"));
```

**GLIDE:**
GLIDE does not expose an EventEmitter interface. Connection management and reconnection are handled internally by the Rust core. Errors surface per-command as rejected promises. Configure reconnection behavior via connectionBackoff in the client configuration.

---

## TypeScript Support

GLIDE provides full TypeScript types out of the box via `@valkey/valkey-glide`. The package supports TypeScript, CommonJS, and ESM module formats. Return types are fully typed as `Promise<string | null>` etc. - no `@types/` packages needed.

---

## Incremental Migration Strategy

No drop-in compatibility layer exists for Node.js. The recommended approach:

1. Install `@valkey/valkey-glide` alongside `ioredis`
2. Create a wrapper module that abstracts the client interface
3. Migrate route handlers or services one at a time behind the wrapper
4. Use GLIDE's Batch API for bulk operations previously handled by ioredis pipelines
5. Swap the wrapper implementation once all call sites are migrated
6. Remove `ioredis` dependency
7. Review `best-practices/production.md` for timeout tuning, connection management, and observability setup

---

## See Also

- **valkey-glide-nodejs** skill - full GLIDE Node.js API details
- [Scripting](../features/scripting.md) - Lua scripting and the Script class
- [PubSub](../features/pubsub.md) - subscription patterns and dynamic PubSub
- [Batching](../features/batching.md) - pipeline and transaction patterns
- [TLS and authentication](../features/tls-auth.md) - TLS setup and credential management
- [Production deployment](../best-practices/production.md) - timeout tuning, connection management, observability
- [Error handling](../best-practices/error-handling.md) - error types, reconnection, batch error semantics

---

## Gotchas

1. **Hash argument format.** ioredis accepts spread key-value pairs ("k1", "v1", "k2", "v2"). GLIDE requires an object {k1: "v1"} or HashDataType array.

2. **Sorted set format.** ioredis uses interleaved score, member pairs. GLIDE uses {element, score} objects or a Record<string, number> map.

3. **No setex/psetex/setnx.** Use set() with the expiry and conditionalSet options instead.

4. **Array args for multi-key commands.** del, exists, lpush, sadd all take arrays, not rest parameters.

5. **Pipeline result format.** ioredis returns [[error, result], ...]. GLIDE returns a flat array of results. Errors are thrown or returned as RequestError objects depending on the raiseOnError flag.

6. **No event emitter.** If you relied on on("error") for monitoring, you need to handle errors per-command or set up external health checks.

7. **Module imports.** GLIDE uses named imports from @valkey/valkey-glide. TypeScript types are included.

---

## Additional Notes

1. **Dynamic PubSub requires GLIDE 2.3+.** Before 2.3, GLIDE required all subscriptions to be defined at connection time. GLIDE 2.3 added dynamic subscribe/unsubscribe after client creation.

2. **protobufjs bundle size.** GLIDE's Node.js client depends on protobufjs, which adds approximately 19KB gzipped (6.5KB with tree shaking). This can be significant for serverless deployments where bundle size affects cold start times.

3. **npm version on Linux.** npm 11+ is recommended on Linux for proper optional dependency handling based on libc detection. Older npm versions may pull the wrong native binary.
