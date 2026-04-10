# Pub/Sub (Node.js)

Use when you need real-time message broadcasting between clients - chat, notifications, event distribution, or live data feeds.

## Contents

- Key Difference from ioredis (line 16)
- PubSubChannelModes (line 59)
- PubSubSubscriptions Interface (line 69)
- PubSubMsg Interface (line 87)
- Message Delivery: Callback (line 101)
- Message Delivery: Polling (line 124)
- Complete Example: Publisher + Subscriber (line 161)
- Important Notes (line 199)

## Key Difference from ioredis

GLIDE PubSub differs from ioredis in two ways: (1) no event emitters - use callbacks or polling instead, (2) RESP3 protocol required.

All subscriptions must be declared at client creation time. Node.js GLIDE does NOT have runtime `subscribe()` / `psubscribe()` methods. To change subscriptions, close the client and create a new one.

```typescript
import { GlideClusterClient, GlideClusterClientConfiguration } from "@valkey/valkey-glide";

const subscriber = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]: new Set(["news", "events"]),
            [GlideClusterClientConfiguration.PubSubChannelModes.Pattern]: new Set(["events:*"]),
        },
        callback: (msg) => {
            console.log(`${msg.channel}: ${msg.message}`);
        },
    },
});
```

### ioredis migration pattern

```typescript
// ioredis (old) - runtime subscribe with event emitter
const sub = redis.duplicate();
sub.psubscribe("events:*");
sub.on("pmessage", (pattern, channel, message) => { ... });

// GLIDE (new) - subscriptions at creation time, callback or polling
const sub = await GlideClusterClient.createClient({
    addresses,
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Pattern]: new Set(["events:*"]),
        },
        callback: (msg) => { /* msg.channel, msg.message, msg.pattern */ },
    },
});
```

## PubSubChannelModes

Each client type defines its own enum. The cluster client supports three modes; the standalone client supports two.

| Value | Name | Description | Cluster | Standalone |
|-------|------|-------------|---------|------------|
| 0 | `Exact` | Subscribe to specific channel names (SUBSCRIBE) | Yes | Yes |
| 1 | `Pattern` | Subscribe using glob patterns like `news.*` (PSUBSCRIBE) | Yes | Yes |
| 2 | `Sharded` | Slot-scoped channels, Valkey 7.0+ (SSUBSCRIBE) | Yes | No |

## PubSubSubscriptions Interface

Defined in both `GlideClusterClientConfiguration` and `GlideClientConfiguration` namespaces:

```typescript
interface PubSubSubscriptions {
    channelsAndPatterns: Partial<Record<PubSubChannelModes, Set<string>>>;
    callback?: (msg: PubSubMsg, context: any) => void;
    context?: any;
}
```

- `channelsAndPatterns` - map from mode to a `Set<string>` of channel names or patterns
- `callback` - optional function invoked on each incoming message
- `context` - arbitrary value passed as the second argument to the callback

If no callback is provided, messages queue internally and must be retrieved via polling.

## PubSubMsg Interface

```typescript
interface PubSubMsg {
    message: GlideString;
    channel: GlideString;
    pattern?: GlideString | null;
}
```

- `message` - the published payload
- `channel` - the channel the message was published to
- `pattern` - the pattern that matched (only set for pattern subscriptions)

## Message Delivery: Callback

Provide a `callback` in `pubsubSubscriptions`. The callback must not block.

```typescript
import { GlideClusterClient, GlideClusterClientConfiguration } from "@valkey/valkey-glide";

const subscriber = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Pattern]: new Set(["user:*"]),
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]: new Set(["system"]),
        },
        callback: (msg, context) => {
            context.count++;
            console.log(`[${msg.channel}] ${msg.message} (pattern: ${msg.pattern ?? "none"})`);
        },
        context: { count: 0 },
    },
});
```

## Message Delivery: Polling

Omit the `callback` to use polling. Two methods are available on the client:

| Method | Returns | Behavior |
|--------|---------|----------|
| `getPubSubMessage()` | `Promise<PubSubMsg>` | Awaits until a message arrives |
| `tryGetPubSubMessage()` | `PubSubMsg \| null` | Returns immediately, `null` if empty |

Both methods throw `ConfigurationError` if a callback is configured, or if no subscriptions exist.

```typescript
import { GlideClusterClient, GlideClusterClientConfiguration } from "@valkey/valkey-glide";

const subscriber = await GlideClusterClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]: new Set(["orders"]),
        },
        // No callback - use polling
    },
});

// Async wait - blocks until a message arrives
const msg = await subscriber.getPubSubMessage();
console.log(`${msg.channel}: ${msg.message}`);

// Non-blocking poll - returns null if no message queued
const next = subscriber.tryGetPubSubMessage();
if (next) {
    console.log(`${next.channel}: ${next.message}`);
}
```

Drain the queue regularly - the internal buffer is unbounded and grows if not consumed.

## Complete Example: Publisher + Subscriber

```typescript
import {
    GlideClusterClient,
    GlideClusterClientConfiguration,
} from "@valkey/valkey-glide";

const addresses = [{ host: "localhost", port: 6379 }];

// Subscriber client - subscriptions declared at creation
const subscriber = await GlideClusterClient.createClient({
    addresses,
    pubsubSubscriptions: {
        channelsAndPatterns: {
            [GlideClusterClientConfiguration.PubSubChannelModes.Exact]: new Set(["chat"]),
            [GlideClusterClientConfiguration.PubSubChannelModes.Sharded]: new Set(["shard-topic"]),
        },
        callback: (msg) => {
            console.log(`[${msg.channel}] ${msg.message}`);
        },
    },
});

// Publisher client - separate instance, no subscriptions needed
const publisher = await GlideClusterClient.createClient({ addresses });

// Publish to exact channel
await publisher.publish("Hello from GLIDE!", "chat");

// Publish to sharded channel (third argument = true for sharded mode)
await publisher.publish("Sharded hello!", "shard-topic", true);

// Cleanup
publisher.close();
subscriber.close();
```

## Important Notes

1. **RESP3 is the default.** `protocol` defaults to `ProtocolVersion.RESP3`. PubSub works out of the box. If you explicitly set `protocol: ProtocolVersion.RESP2`, PubSub push notifications will not be delivered.

2. **Separate clients for pub and sub.** A subscribing client is in a special mode. Use one client for publishing and a different client for subscribing.

3. **No runtime subscribe/unsubscribe in Node.js.** Java/Python/Go have dynamic `subscribe()`/`psubscribe()` methods (GLIDE 2.3+). Node.js support is in progress. Declare all subscriptions at creation time. To change subscriptions, close and recreate the client.

4. **Callback vs polling - pick one.** If a callback is configured, `getPubSubMessage()` and `tryGetPubSubMessage()` throw `ConfigurationError`. If no callback is configured, messages must be polled.

5. **Sharded PubSub requires cluster mode.** `PubSubChannelModes.Sharded` is only available on `GlideClusterClient` (not `GlideClient`). Requires Valkey 7.0+.

6. **publish() signature differs by client type.** `GlideClusterClient.publish(message, channel, sharded?)` accepts an optional boolean for sharded mode. `GlideClient.publish(message, channel)` does not.

7. **Automatic resubscription on reconnect.** When the connection drops, GLIDE reconnects and reissues the configured SUBSCRIBE/PSUBSCRIBE/SSUBSCRIBE commands automatically.
