# Pub/Sub

Use when you need real-time message broadcasting between clients - chat, notifications, event distribution, or live data feeds. For durable message processing with consumer groups and replay, see [Streams](streams.md) instead.

GLIDE supports Valkey's publish/subscribe messaging with three subscription modes, automatic reconnection with resubscription, and a synchronizer that continuously reconciles desired vs actual subscription state. Sharded subscriptions require Valkey 7.0+. Dynamic subscribe/unsubscribe requires GLIDE 2.3+.

## Subscription Modes

| Mode | Command | Description | Cluster Requirement |
|------|---------|-------------|---------------------|
| Exact | SUBSCRIBE / UNSUBSCRIBE | Subscribe to specific channel names | All modes |
| Pattern | PSUBSCRIBE / PUNSUBSCRIBE | Subscribe using glob patterns (e.g., `news.*`) | All modes |
| Sharded | SSUBSCRIBE / SUNSUBSCRIBE | Slot-scoped channels routed by hash slot | Cluster mode, Valkey 7.0+ |

In cluster mode, sharded subscriptions are slot-deterministic - the subscription is managed by the node owning the channel's hash slot. GLIDE handles slot migration automatically.

## Subscription Models

### Historical: Immutable Subscriptions (pre-2.3)

Subscriptions were configured at client creation time and could not be changed. The configuration was passed through the client configuration object as initial subscriptions.

### Dynamic Subscriptions (GLIDE 2.3+)

Runtime `subscribe()` and `unsubscribe()` methods allow modifying subscriptions after client creation. The synchronizer manages the desired-vs-actual state and reconciles differences.

Two operation modes are available:
- **Non-blocking (lazy)**: Returns immediately, reconciliation happens asynchronously
- **Blocking**: Waits until the subscription change is confirmed on the server (with configurable timeout)

## Architecture: PubSub Synchronizer

The Rust core implements a `GlidePubSubSynchronizer` that uses an observer pattern:

- `desired_subscriptions` - what the user wants to be subscribed to (modified by API calls)
- `current_subscriptions_by_address` - what the client is actually subscribed to (updated by server push notifications)

A background reconciliation task runs at a configurable interval (default: 3 seconds) to align current subscriptions with desired subscriptions. The interval is configurable via `pubsub_reconciliation_interval` in the advanced client configuration.

The synchronizer handles:
- Subscribing to channels the user wants but the client is not subscribed to
- Unsubscribing from channels the client is subscribed to but the user no longer wants
- Topology changes - when slots migrate to new nodes, subscriptions are moved accordingly
- Node disconnections - cleared subscriptions are automatically resubscribed

## Message Kinds

Messages received from PubSub carry a kind that indicates how they were matched:

| Kind | Description |
|------|-------------|
| Message | Received via exact channel subscription (SUBSCRIBE) |
| PMessage | Received via pattern subscription (PSUBSCRIBE) |
| SMessage | Received via sharded subscription (SSUBSCRIBE) |

## Message Receiving Methods

Three approaches for consuming messages:

1. **Polling** (`tryGetMessage` / `try_get_pubsub_message`) - non-blocking, returns next message or nothing
2. **Async** (`getMessage` / `get_pubsub_message`) - returns Future/Promise, waits for next message
3. **Callback** - user-provided function invoked on message arrival (must be thread-safe)

Extract messages promptly when using async/polling mode - the internal buffer is unbounded and will grow indefinitely if not drained.

## Message Reception (Python)

```python
# Blocking - waits for a message
msg = await subscriber.get_pubsub_message()

# Non-blocking - returns None if no message available
msg = subscriber.try_get_pubsub_message()

# Callback-driven (set during client configuration)
def on_message(msg, context):
    print(f"Channel: {msg.channel}, Message: {msg.message}")
```

## Python Example

```python
from glide import (
    GlideClient,
    GlideClientConfiguration,
    GlideClusterClientConfiguration,
    NodeAddress,
)

# Subscriber client - standalone
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
)
subscriber = await GlideClient.create(config)

# Dynamic subscribe (GLIDE 2.3+)
await subscriber.subscribe(["news", "events"])
await subscriber.psubscribe(["user:*"])

# Receive messages
msg = await subscriber.get_pubsub_message()
print(f"Channel: {msg.channel}, Message: {msg.message}")

# Unsubscribe
await subscriber.unsubscribe(["news"])

# Publisher client - separate instance
publisher = await GlideClient.create(config)
await publisher.publish("events", "Hello subscribers!")
```

## Java Example

```java
import glide.api.GlideClient;
import glide.api.GlideClusterClient;

// Create subscriber and publisher as separate clients
GlideClient subscriber = GlideClient.createClient(config).get();
GlideClient publisher = GlideClient.createClient(config).get();

// Subscribe
subscriber.subscribe(new String[]{"news", "events"}).get();

// Publish
publisher.publish("events", "Hello subscribers!").get();
```

## Node.js Example

```javascript
import { GlideClient } from "@valkey/valkey-glide";

// Subscriber - separate client instance
const subscriber = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
});

// Publisher
const publisher = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
});

await subscriber.subscribe(["news", "events"]);
await publisher.publish("events", "Hello!");
```

## Dedicated Subscriber Client

A subscriber client is dedicated to listening - it enters a special mode where most regular commands are unavailable. Always use separate clients for publishing and subscribing:

```python
# Correct: separate clients
subscriber = await GlideClient.create(config)
publisher = await GlideClient.create(config)

# Incorrect: same client for both pub and sub
# client.subscribe(...)  # Now client is in subscriber mode
# client.set(...)        # This will fail
```

## Automatic Reconnection

When a connection drops, GLIDE:

1. Reconnects using the configured backoff strategy (see [connection-model](../architecture/connection-model.md) for reconnection details)
2. Clears the `current_subscriptions_by_address` for the disconnected node
3. Triggers reconciliation, which resubscribes to all desired channels
4. For sharded subscriptions, handles slot migration - resubscribing to new slot owners

This is managed by the `GlidePubSubSynchronizer` in the Rust core, which uses `Weak` references to avoid memory leaks and `Notify` primitives for efficient wake-up.

## Topology Change Handling

When cluster topology changes (slot migrations, node additions/removals):

1. The synchronizer receives the new slot map via `handle_topology_refresh`
2. For each current subscription, it checks if the owning node has changed
3. Migrated subscriptions are queued for unsubscribe from the old node
4. The reconciliation loop then resubscribes on the new correct node
5. For removed nodes, all their subscriptions are cleared and resubscribed elsewhere

## Configuration

```python
from glide import AdvancedGlideClientConfiguration

# Configure reconciliation interval (milliseconds)
advanced = AdvancedGlideClientConfiguration(
    pubsub_reconciliation_interval=5000,  # 5 seconds
)
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    advanced_config=advanced,
)
```

## Message Loss Caveat

During automatic reconnection and resubscription, messages can be lost. This is inherent to the RESP protocol's at-most-once delivery semantics. Applications requiring stronger guarantees should implement application-level acknowledgment using Valkey Streams instead of PubSub.

## Subscription State Introspection

GLIDE provides `get_subscriptions()` that returns both desired and actual subscription state, organized by kind (Exact, Pattern, Sharded). This is useful for debugging synchronization issues - comparing desired vs actual reveals whether the synchronizer has caught up after topology changes or reconnections.

## Related Features

- [Streams](streams.md) - durable, ordered message processing with consumer groups and replay capability; use Streams when you need at-least-once delivery guarantees
- [Logging](logging.md) - enable Debug level to see subscription state changes and reconciliation activity
- [OpenTelemetry](opentelemetry.md) - PubSub synchronization state is reported as OTel metrics (out-of-sync events, last sync timestamp)
