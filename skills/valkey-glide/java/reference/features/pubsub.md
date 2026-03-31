Use when implementing Pub/Sub messaging with GLIDE Java - subscribing to channels, receiving messages, publishing, or using sharded pub/sub in cluster mode.

## Contents

- Two Subscription Models (line 17)
- Creation-Time Subscriptions (Standalone) (line 21)
- Creation-Time Subscriptions (Cluster) (line 51)
- Runtime Subscribe/Unsubscribe (line 72)
- Runtime Sharded Subscribe/Unsubscribe (Cluster Only) (line 98)
- Receiving Messages - Callback vs Polling (line 111)
- PubSubMessage Fields (line 141)
- Publishing (line 150)
- Introspection (line 160)
- Subscription State (line 177)
- Reconciliation (line 191)

## Two Subscription Models

GLIDE Java supports both creation-time subscriptions (configured in the builder) and runtime subscriptions (subscribe/unsubscribe after client creation).

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

```java
// Standalone and cluster
client.publish("Hello!", "announcements").get();

// Cluster sharded publish (Valkey 7.0+)
clusterClient.publish("Hello!", "shard-channel", true).get();
```

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
