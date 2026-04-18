# Pub/Sub

Use when working with publish/subscribe. Covers what differs from `redis-py` - the core publish/message-receive loop is similar but the subscription model diverges significantly.

## Divergence from redis-py

| redis-py | GLIDE Python |
|----------|--------------|
| `pubsub = r.pubsub(); pubsub.subscribe(...)` - runtime object per subscriber | Either static subscriptions configured into client config, or dynamic `client.subscribe()` calls (GLIDE 2.3+) |
| `for msg in pubsub.listen(): ...` | Either callback (push) or `get_pubsub_message()` / `try_get_pubsub_message()` (polling) - cannot mix |
| Manual resubscribe on reconnect | GLIDE's synchronizer reconciles desired vs actual across reconnects and topology changes |
| No notion of "desired" state | `client.get_subscriptions()` exposes desired and actual; metrics `subscription_out_of_sync_count` and `subscription_last_sync_timestamp` |
| Cluster sharded pub/sub not built in | `GlideClusterClient` with `PubSubChannelModes.Sharded` + `publish(..., sharded=True)` |

Static subscriptions require RESP3. Using RESP2 raises `ConfigurationError`.

## Subscription modes

| Mode | Subscribe / Unsubscribe | Description | Client |
|------|------------------------|-------------|--------|
| Exact | `subscribe` / `unsubscribe` | Specific channel names | Both |
| Pattern | `psubscribe` / `punsubscribe` | Glob patterns (e.g., `news.*`) | Both |
| Sharded | `ssubscribe` / `sunsubscribe` | Slot-scoped channels | `GlideClusterClient` only, Valkey 7.0+ |

## Subscription Approaches

### Static (Creation-Time) Subscriptions

Subscriptions configured in the client configuration object. Applied during connection establishment. Available in all GLIDE versions.

```python
from glide import (
    GlideClient, GlideClientConfiguration, NodeAddress, PubSubMsg,
)

def on_message(msg: PubSubMsg, context):
    print(f"[{msg.channel}] {msg.message} (pattern={msg.pattern})")

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    pubsub_subscriptions=GlideClientConfiguration.PubSubSubscriptions(
        channels_and_patterns={
            GlideClientConfiguration.PubSubChannelModes.Exact: {"alerts", "events"},
            GlideClientConfiguration.PubSubChannelModes.Pattern: {"news.*"},
        },
        callback=on_message,
        context=None,
    ),
)
client = await GlideClient.create(config)
# Subscriptions are active immediately after create()
```

Cluster mode supports Exact, Pattern, and Sharded modes:

```python
from glide import (
    GlideClusterClient, GlideClusterClientConfiguration, NodeAddress,
)

config = GlideClusterClientConfiguration(
    addresses=[NodeAddress("cluster-node", 6379)],
    pubsub_subscriptions=GlideClusterClientConfiguration.PubSubSubscriptions(
        channels_and_patterns={
            GlideClusterClientConfiguration.PubSubChannelModes.Exact: {"alerts"},
            GlideClusterClientConfiguration.PubSubChannelModes.Sharded: {"shard-events"},
        },
        callback=lambda msg, ctx: print(msg.message),
        context=None,
    ),
)
client = await GlideClusterClient.create(config)
```

Static subscriptions require RESP3 protocol (the default). RESP2 raises `ConfigurationError`.

### Dynamic (Runtime) Subscriptions - GLIDE 2.3+

Subscribe and unsubscribe after client creation. Two variants per method:

| Variant | Suffix | Behavior |
|---------|--------|----------|
| Blocking | none | Waits for server confirmation; optional `timeout_ms` |
| Non-blocking | `_lazy` | Returns immediately; reconciliation happens asynchronously |

#### Exact Channels

```python
# Blocking - waits for server confirmation
await client.subscribe({"channel1", "channel2"})

# Blocking with timeout (milliseconds)
await client.subscribe({"channel1"}, timeout_ms=5000)

# Non-blocking - returns immediately
await client.subscribe_lazy({"channel1", "channel2"})

# Unsubscribe
await client.unsubscribe({"channel1"})
await client.unsubscribe()        # unsubscribe from all exact channels
await client.unsubscribe_lazy()   # non-blocking variant
```

#### Pattern Channels

```python
await client.psubscribe({"news.*", "alerts.*"})
await client.psubscribe_lazy({"news.*"})

await client.punsubscribe({"news.*"})
await client.punsubscribe_lazy()  # unsubscribe from all patterns
```

#### Sharded Channels (Cluster Only)

```python
await client.ssubscribe({"shard-events"}, timeout_ms=3000)
await client.ssubscribe_lazy({"shard1", "shard2"})

await client.sunsubscribe({"shard-events"})
await client.sunsubscribe_lazy()  # unsubscribe from all sharded channels
```

## Receiving Messages

### Callback Model

Pass a callback in the subscription configuration. The callback receives `PubSubMsg` objects with `message`, `channel`, and optional `pattern` fields.

```python
def handler(msg: PubSubMsg, context):
    print(f"Channel: {msg.channel}, Message: {msg.message}")
    if msg.pattern:
        print(f"Matched pattern: {msg.pattern}")
```

### Polling Model

Omit the callback. Use `get_pubsub_message()` (async, blocks until a message arrives) or `try_get_pubsub_message()` (returns `None` immediately if no message).

```python
# Blocking poll
msg = await client.get_pubsub_message()

# Non-blocking poll
msg = client.try_get_pubsub_message()
if msg:
    print(msg.message)
```

You cannot mix callback and polling on the same client - calling `get_pubsub_message()` when a callback is configured raises `ConfigurationError`.

## Subscription State Inspection

Check what the client intends to be subscribed to vs what is actually confirmed on the server:

```python
state = await client.get_subscriptions()

desired = state.desired_subscriptions   # Dict[PubSubChannelModes, Set[str]]
actual = state.actual_subscriptions     # Dict[PubSubChannelModes, Set[str]]

if desired == actual:
    print("All subscriptions synchronized")

# Check specific mode
from glide import GlideClusterClientConfiguration
Modes = GlideClusterClientConfiguration.PubSubChannelModes
missing = desired.get(Modes.Exact, set()) - actual.get(Modes.Exact, set())
```

## Reconciliation

The client's synchronizer periodically reconciles desired vs actual subscriptions. Configure the interval:

```python
from glide import AdvancedGlideClusterClientConfiguration

advanced = AdvancedGlideClusterClientConfiguration(
    pubsub_reconciliation_interval=2000,  # ms between reconciliation checks
)
```

Track reconciliation health via `get_statistics()`:

```python
stats = await client.get_statistics()
out_of_sync = stats["subscription_out_of_sync_count"]
last_sync = stats["subscription_last_sync_timestamp"]  # ms since epoch
```

## Publishing

Publishing is a regular command, not tied to subscriptions:

```python
# Standalone client: publish(message, channel) -> int
num_receivers = await client.publish("hello world", "alerts")

# Cluster client: publish(message, channel, sharded=False) -> int
num_receivers = await client.publish("hello world", "alerts")

# Cluster client: sharded publish (Valkey 7.0+)
num_receivers = await client.publish("hello shard", "shard-events", sharded=True)
```
