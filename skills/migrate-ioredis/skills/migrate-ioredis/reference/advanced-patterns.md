# ioredis to GLIDE: migration patterns

Use when translating ioredis Lua scripts, pipelines, Pub/Sub, or handling event / TypeScript differences.

## Lua Scripting: Script class, required `.release()`

```javascript
// ioredis - manual defineCommand or evalsha
redis.defineCommand("mycmd", { numberOfKeys: 1, lua: "return redis.call('GET', KEYS[1])" });
await redis.mycmd("key1");

// GLIDE
import { Script } from "@valkey/valkey-glide";

const script = new Script("return redis.call('GET', KEYS[1])");
try {
    const result = await client.invokeScript(script, { keys: ["key1"] });
} finally {
    script.release();  // REQUIRED - not garbage collected, leaks native memory otherwise
}
```

Automatic EVALSHA-with-EVAL-fallback. No manual SHA management. For cluster keyless scripts: `clusterClient.invokeScriptWithRoute(script, { args, route })`. Scripts are NOT allowed inside a `Batch` - use `batch.customCommand(["EVAL", ...])` there.

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

### Path A - static subscriptions (any GLIDE version)

```javascript
import { GlideClusterClient, GlideClusterClientConfiguration } from "@valkey/valkey-glide";

const subscriber = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]:   new Set(["channel"]),
            [GlideClusterClientConfiguration.PubSubChannelModes.Pattern]: new Set(["events:*"]),
        },
        callback: (msg) => {
            console.log(`[${msg.channel}] ${msg.message}`);
        },
    },
});
```

Omit `callback` and poll with `await subscriber.getPubSubMessage()` (blocking) or `subscriber.tryGetPubSubMessage()` (non-blocking). Callback and polling are mutually exclusive.

### Path B - dynamic subscriptions (GLIDE 2.3+; yes, Node has these)

Node at v2.3.1 includes the full dynamic pubsub API - older docs claiming Node lacks runtime subscribe are outdated:

```javascript
await subscriber.subscribe(new Set(["channel"]), /* timeoutMs? */ 5000);
await subscriber.subscribeLazy(new Set(["channel"]));  // non-blocking
await subscriber.psubscribe(new Set(["events:*"]), 5000);
await subscriber.ssubscribe(new Set(["shard-topic"]), 5000);  // cluster only

await subscriber.unsubscribe(new Set(["channel"]));
await subscriber.unsubscribeLazy();

const state = await subscriber.getSubscriptions();  // desired vs actual
```

### Publishing

**GOTCHA: argument order is REVERSED from ioredis.** ioredis is `r.publish(channel, message)`; GLIDE is `await client.publish(message, channel)`. The `publish` table row in SKILL.md's divergence list calls this out too.

```javascript
// ioredis:                     publish(channel, message)
await cluster.publish("events:order", JSON.stringify({ id: 1 }));

// GLIDE: message first, channel second
await publisher.publish(JSON.stringify({ id: 1 }), "events:order");
```

### Other pubsub differences

- GLIDE multiplexes pubsub onto the same connection - the subscribing client can still run regular commands. Dedicated client still recommended for high-throughput subscribers to avoid head-of-line effects.
- Automatic resubscription on reconnect and cluster topology change via the synchronizer.
- RESP3 required for static subscriptions; RESP2 raises `ConfigurationError`.

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
