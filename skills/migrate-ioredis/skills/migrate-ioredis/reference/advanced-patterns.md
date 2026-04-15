# ioredis to GLIDE Advanced Patterns

Use when migrating ioredis Lua scripting, pipelines, transactions, Pub/Sub, or handling event and TypeScript differences.

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

GLIDE caches the script automatically and uses EVALSHA on repeat calls. No manual SHA management.

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

GLIDE returns flat result arrays, not the [error, result] tuple format ioredis uses.

---

## Pub/Sub

**ioredis:**
```javascript
const sub = redis.duplicate();
sub.subscribe("channel");
sub.psubscribe("events:*");
sub.on("message", (channel, message) => {
    console.log(`${channel}: ${message}`);
});
sub.on("pmessage", (pattern, channel, message) => {
    console.log(`[${pattern}] ${channel}: ${message}`);
});
```

**GLIDE (static subscriptions - at client creation):**
```javascript
import { GlideClusterClient, GlideClusterClientConfiguration } from "@valkey/valkey-glide";

const subscriber = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]: new Set(["channel"]),
            [GlideClusterClientConfiguration.PubSubChannelModes.Pattern]: new Set(["events:*"]),
        },
        callback: (msg) => {
            console.log(`[${msg.channel}] ${msg.message} (pattern: ${msg.pattern ?? "none"})`);
        },
    },
});
```

**GLIDE (polling - no callback):**
```javascript
const subscriber = await GlideClusterClient.createClient({
    addresses,
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]: new Set(["channel"]),
        },
        // No callback - use polling
    },
});

const msg = await subscriber.getPubSubMessage();    // awaits until message arrives
const next = subscriber.tryGetPubSubMessage();       // returns null if no message
```

**Publishing - argument order is reversed:**
```javascript
// ioredis: channel first, message second
await cluster.publish("events:order", JSON.stringify({ id: 1, status: "created" }));

// GLIDE: message first, channel second
await publisher.publish(JSON.stringify({ id: 1, status: "created" }), "events:order");
```

The publisher must be a separate client from the subscriber. Any `GlideClusterClient` without `pubsubSubscriptions` can publish.

Node.js GLIDE has no runtime `subscribe()` / `psubscribe()` methods. All subscriptions are declared at client creation time. To change subscriptions, close and recreate the client. Callback and polling are mutually exclusive. RESP3 required for PubSub.

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
GLIDE does not expose an EventEmitter interface. The Rust core handles connection management and reconnection internally. Errors surface per-command as rejected promises. Configure reconnection behavior via connectionBackoff in the client configuration.

---

## TypeScript Support

GLIDE ships full TypeScript types via `@valkey/valkey-glide`. Supports TypeScript, CommonJS, and ESM module formats. Return types are fully typed (`Promise<string | null>` etc.) - no `@types/` packages needed.
