# Pub/Sub (Node.js)

Use when working with publish/subscribe. Covers what diverges from `ioredis` - the `r.subscribe()` / `r.on('message', ...)` event-emitter pattern does NOT translate. The publish/message-receive loop is similar in shape but the subscription model is different.

## Divergence from ioredis

| ioredis | GLIDE |
|---------|-------|
| `sub = redis.duplicate(); sub.subscribe('ch')` then `sub.on('message', (ch, msg) => ...)` | Either static config in `pubsubSubscriptions`, or `await client.subscribe(new Set(['ch']))` (GLIDE 2.3+) |
| EventEmitter (`sub.on('message', ...)`, `sub.on('pmessage', ...)`) | Callback in config OR `await client.getPubSubMessage()` / `client.tryGetPubSubMessage()` polling - cannot mix |
| `redis.publish(channel, message)` | `await client.publish(message, channel)` - **arguments REVERSED**; top silent-bug source during migration |
| Subscriber client can't issue other commands | GLIDE multiplexes - subscribing client CAN still run regular commands (dedicated client still recommended for high-throughput subscribers) |
| Manual resubscribe on reconnect | Automatic via synchronizer; `getSubscriptions()` exposes desired vs actual state |
| Sharded pub/sub via standalone client (supported in 7.0+) | `PubSubChannelModes.Sharded` requires `GlideClusterClient` |

Static subscriptions require RESP3 (the default). Setting `protocol: ProtocolVersion.RESP2` with subscriptions throws `ConfigurationError`.

## Subscription approaches

### Static (creation-time, any GLIDE version)

```typescript
import { GlideClusterClient, GlideClusterClientConfiguration } from "@valkey/valkey-glide";

const subscriber = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]:   new Set(["chat"]),
            [GlideClusterClientConfiguration.PubSubChannelModes.Pattern]: new Set(["news:*"]),
        },
        callback: (msg, context) => {
            console.log(`[${msg.channel}] ${msg.message} (pattern: ${msg.pattern ?? "none"})`);
        },
        context: { /* arbitrary */ },
    },
});
```

### Dynamic (GLIDE 2.3+ - Node includes full support)

Node.js at v2.3.1 has the full dynamic pubsub API. Methods on the client:

```typescript
// Blocking variants wait for server ack; optional timeout (ms)
await client.subscribe(new Set(["channel1", "channel2"]), /* timeoutMs? */ 5000);
await client.psubscribe(new Set(["news:*"]), 5000);
await client.ssubscribe(new Set(["shard-topic"]), 5000);  // GlideClusterClient only

// Lazy variants return immediately; reconciliation is async
await client.subscribeLazy(new Set(["channel1"]));
await client.psubscribeLazy(new Set(["news:*"]));
await client.ssubscribeLazy(new Set(["shard-topic"]));

await client.unsubscribe(new Set(["channel1"]));   // or unsubscribe() for all exact
await client.unsubscribeLazy();
```

## Receiving messages

### Callback model

Pass `callback` in `pubsubSubscriptions`. Must not block. Receives `PubSubMsg`:

```typescript
interface PubSubMsg {
    message: GlideString;
    channel: GlideString;
    pattern?: GlideString | null;  // set only for pattern subscriptions
}
```

### Polling model

Omit `callback` in config. Use the client's message methods:

| Method | Returns | Behavior |
|--------|---------|----------|
| `await client.getPubSubMessage()` | `Promise<PubSubMsg>` | Awaits until a message arrives |
| `client.tryGetPubSubMessage()` | `PubSubMsg \| null` | Returns immediately, `null` if queue empty |

Both throw `ConfigurationError` if a callback is configured, or if the client has no subscriptions. Drain the queue regularly - it is unbounded.

## Subscription state inspection

```typescript
const state = await client.getSubscriptions();
// Standalone returns StandalonePubSubState
// Cluster    returns ClusterPubSubState
// Both expose desired vs actual subscriptions per channel mode
```

Track sync health:

```typescript
const stats = await client.getStatistics();
const outOfSync = stats["subscription_out_of_sync_count"];       // all values are strings
const lastSyncMs = stats["subscription_last_sync_timestamp"];    // ms since epoch
```

## `PubSubChannelModes`

Each client type defines its own enum under the config namespace. Same numeric values in both, but `Sharded` is cluster-only:

| Value | Name | Cluster | Standalone | Server command |
|-------|------|---------|------------|----------------|
| 0 | `Exact` | Yes | Yes | SUBSCRIBE |
| 1 | `Pattern` | Yes | Yes | PSUBSCRIBE |
| 2 | `Sharded` | Yes | No | SSUBSCRIBE (Valkey 7.0+) |

## Publishing

**GOTCHA: argument order is REVERSED from ioredis.** ioredis is `r.publish(channel, message)`; GLIDE is `await client.publish(message, channel)`. Silent mis-routing if you don't notice - this is the #1 `publish()` bug in migration code.

```typescript
// Standalone: publish(message, channel) -> number of receivers
await client.publish("hello world", "chat");

// Cluster: publish(message, channel, sharded?) -> number of receivers
await client.publish("hello world", "chat");
await client.publish("hello shard", "shard-topic", true);  // sharded mode, Valkey 7.0+
```

## Automatic resubscription

On reconnect or cluster topology change, the synchronizer reissues SUBSCRIBE / PSUBSCRIBE / SSUBSCRIBE automatically. No manual handling. Tune cadence via `advancedConfiguration.pubsubReconciliationInterval` (ms).
