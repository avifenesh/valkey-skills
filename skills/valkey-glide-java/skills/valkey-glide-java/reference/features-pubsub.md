# Pub/Sub (Java)

Use when working with publish/subscribe in GLIDE Java. Covers the divergence from Jedis's `jedis.subscribe(listener, channels)` blocking-thread pattern and Lettuce's `RedisPubSubCommands` / `RedisPubSubAsyncCommands`.

## Divergence from Jedis / Lettuce

| Jedis / Lettuce | GLIDE Java |
|-----------------|-----------|
| Jedis: `jedis.subscribe(new JedisPubSub() {...}, "channel")` blocks the calling thread | Either static config on the builder OR runtime `client.subscribe(Set.of("channel"))` / `subscribe(Set.of(...), timeoutMs)` - neither blocks the calling thread |
| Lettuce: `RedisPubSubCommands pubsub = redis.connectPubSub().sync(); pubsub.subscribe("ch")` | `client.subscribe(Set.of("ch")).get()` on the same client |
| Jedis: `jedis.publish(channel, message)` | `client.publish(message, channel).get()` - **arguments REVERSED** compared to Jedis/Lettuce/everything else |
| Lettuce: `redis.async().publish(channel, message)` | Same reversed order on GLIDE: message first, channel second |
| Callback-only (Jedis) or async iterable (Lettuce reactive) | Callback configured up front on the subscription config, OR pull-model via `getPubSubMessage()` / `tryGetPubSubMessage()` |
| Manual resubscribe on reconnect | Automatic via synchronizer; `client.getSubscriptions()` returns `PubSubState` with `getDesiredSubscriptions()` / `getActualSubscriptions()` |
| Cluster sharded pub/sub not in Jedis base; Lettuce via `RedisClusterPubSubCommands` | `ssubscribe` / `sunsubscribe` / cluster `publish(msg, ch, true)` on `GlideClusterClient` (Valkey 7.0+) |
| Subscribing client enters a "special mode" unable to send regular commands (Jedis/Lettuce) | GLIDE multiplexes subscriptions alongside commands - subscribing client CAN still run regular commands (dedicated client still recommended for high-throughput subscribers) |

Static PubSub subscriptions require RESP3 (default). Using RESP2 raises `ConfigurationError`.

## Creation-Time Subscriptions (Standalone)

Channels are subscribed automatically during connection establishment:

```java
import glide.api.models.configuration.*;
import glide.api.models.configuration.StandaloneSubscriptionConfiguration.PubSubChannelMode;

// With callback
BaseSubscriptionConfiguration.MessageCallback callback = (msg, ctx) -> {
    System.out.println("Channel: " + msg.getChannel());
    System.out.println("Message: " + msg.getMessage());
    msg.getPattern().ifPresent(p -> System.out.println("Pattern: " + p));
};

StandaloneSubscriptionConfiguration subConfig =
    StandaloneSubscriptionConfiguration.builder()
        .subscription(PubSubChannelMode.EXACT, "notifications")
        .subscription(PubSubChannelMode.PATTERN, "news.*")
        .callback(callback)
        .build();

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().port(6379).build())
    .subscriptionConfiguration(subConfig)
    .build();

GlideClient subscriber = GlideClient.createClient(config).get();
```

## Creation-Time Subscriptions (Cluster)

Cluster mode adds `SHARDED` channel mode (Valkey 7.0+):

```java
import glide.api.models.configuration.ClusterSubscriptionConfiguration.PubSubClusterChannelMode;

ClusterSubscriptionConfiguration subConfig =
    ClusterSubscriptionConfiguration.builder()
        .subscription(PubSubClusterChannelMode.EXACT, "notifications")
        .subscription(PubSubClusterChannelMode.PATTERN, "news.*")
        .subscription(PubSubClusterChannelMode.SHARDED, "shard-data")
        .callback(callback)
        .build();

GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().port(6379).build())
    .subscriptionConfiguration(subConfig)
    .build();
```

## Runtime Subscribe/Unsubscribe

Both standalone and cluster clients support dynamic subscriptions after creation:

```java
// Subscribe to channels (non-blocking)
client.subscribe(Set.of("news", "updates")).get();

// Subscribe with timeout (blocking, waits for server confirmation)
client.subscribe(Set.of("alerts"), 5000).get();

// Pattern subscribe
client.psubscribe(Set.of("news.*", "events.*")).get();
client.psubscribe(Set.of("logs.*"), 5000).get();

// Unsubscribe
client.unsubscribe(Set.of("news")).get();
client.unsubscribe(Set.of("updates"), 5000).get();
client.unsubscribe();     // all channels
client.unsubscribe(5000); // all channels with timeout

// Pattern unsubscribe
client.punsubscribe(Set.of("news.*")).get();
client.punsubscribe();     // all patterns
```

## Runtime Sharded Subscribe/Unsubscribe (Cluster Only)

```java
GlideClusterClient clusterClient = GlideClusterClient.createClient(config).get();

clusterClient.ssubscribe(Set.of("shard-news", "shard-events")).get();
clusterClient.ssubscribe(Set.of("shard-alerts"), 5000).get();

clusterClient.sunsubscribe(Set.of("shard-news")).get();
clusterClient.sunsubscribe();     // all sharded channels
clusterClient.sunsubscribe(5000); // all sharded channels with timeout
```

## Receiving Messages - Callback vs Polling

**Callback mode** - set a callback in the subscription configuration. Messages are delivered as they arrive:

```java
BaseSubscriptionConfiguration.MessageCallback callback = (msg, context) -> {
    // Fast, non-blocking - next call can happen before this one completes
    System.out.println(msg.getChannel() + ": " + msg.getMessage());
};

// With optional context object (passed as second arg to callback)
StandaloneSubscriptionConfiguration.builder()
    .subscription(PubSubChannelMode.EXACT, "ch1")
    .callback(callback, myContextObject)
    .build();
```

**Polling mode** - no callback configured. Pull messages from the internal queue:

```java
// Non-blocking - returns null if no message available
PubSubMessage msg = client.tryGetPubSubMessage();

// Async - returns CompletableFuture that completes when a message arrives
CompletableFuture<PubSubMessage> future = client.getPubSubMessage();
PubSubMessage msg = future.get();
```

Calling `tryGetPubSubMessage()` or `getPubSubMessage()` when a callback is configured throws `ConfigurationError`.

## PubSubMessage Fields

```java
PubSubMessage msg = client.tryGetPubSubMessage();
GlideString message = msg.getMessage();           // the payload
GlideString channel = msg.getChannel();           // originating channel
Optional<GlideString> pattern = msg.getPattern(); // pattern that matched (if pattern sub)
```

## Publishing

**GOTCHA: argument order is REVERSED from Jedis / Lettuce.** Jedis is `publish(channel, message)`; Lettuce is `publish(channel, message)`; GLIDE Java is `publish(message, channel)` - message first, channel second. **Silent mis-routing during migration if you don't notice.**

Source: `java/client/src/main/java/glide/api/commands/PubSubBaseCommands.java` -
`CompletableFuture<String> publish(String message, String channel);`

```java
// GLIDE: message FIRST, channel SECOND
client.publish("Hello!", "announcements").get();

// Cluster sharded publish (Valkey 7.0+) - message FIRST, channel SECOND, sharded flag THIRD
clusterClient.publish("Hello!", "shard-channel", true).get();
```

Call out the same reversed-order gotcha in any migration from Jedis, Lettuce, or Spring Data Redis.

## Introspection

```java
// List active channels
String[] channels = client.pubsubChannels().get();
String[] newsChannels = client.pubsubChannels("news.*").get();

// Subscriber counts
Map<String, Long> counts = client.pubsubNumSub(new String[]{"ch1", "ch2"}).get();
Long patternCount = client.pubsubNumPat().get();

// Cluster: sharded channel introspection
String[] shardChannels = clusterClient.pubsubShardChannels().get();
Map<String, Long> shardCounts = clusterClient.pubsubShardNumSub(
    new String[]{"shard-ch1"}).get();
```

## Subscription State

Check desired vs actual subscriptions (may differ during reconnection):

```java
PubSubState<StandaloneSubscriptionConfiguration.PubSubChannelMode> state =
    client.getSubscriptions().get();

Set<String> desired = state.getDesiredSubscriptions()
    .getOrDefault(PubSubChannelMode.EXACT, Set.of());
Set<String> actual = state.getActualSubscriptions()
    .getOrDefault(PubSubChannelMode.EXACT, Set.of());
```

## Reconciliation

The client automatically reconciles subscriptions after connection loss. Configure the reconciliation interval via advanced configuration:

```java
GlideClientConfiguration.builder()
    .advancedConfiguration(AdvancedGlideClientConfiguration.builder()
        .pubsubReconciliationIntervalMs(5000)
        .build())
    .build();
```
