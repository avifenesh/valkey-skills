# Lettuce to GLIDE Advanced Patterns

Use when migrating Lettuce transactions, pipelines, Pub/Sub, or evaluating Spring Data Valkey as an alternative migration path.

## Transactions and Pipelines

**Lettuce:**
```java
// Transaction
commands.multi();
commands.set("k1", "v1");
commands.get("k1");
TransactionResult result = commands.exec().get();

// Pipeline (manual flush control)
commands.setAutoFlushCommands(false);
RedisFuture<String> f1 = commands.set("k1", "v1");
RedisFuture<String> f2 = commands.get("k1");
commands.flushCommands();
commands.setAutoFlushCommands(true);
```

**GLIDE:**
```java
import glide.api.models.Batch;

// Transaction (atomic)
Batch tx = new Batch(true);
tx.set("k1", "v1");
tx.get("k1");
Object[] result = client.exec(tx, false).get();

// Pipeline (non-atomic)
Batch pipe = new Batch(false);
pipe.set("k1", "v1");
pipe.get("k1");
Object[] result2 = client.exec(pipe, false).get();
```

---

## Pub/Sub

**Lettuce:**
```java
import io.lettuce.core.pubsub.RedisPubSubAdapter;
import io.lettuce.core.pubsub.StatefulRedisPubSubConnection;
import io.lettuce.core.pubsub.api.async.RedisPubSubAsyncCommands;

StatefulRedisPubSubConnection<String, String> pubSubConn = redisClient.connectPubSub();
pubSubConn.addListener(new RedisPubSubAdapter<>() {
    @Override
    public void message(String channel, String message) {
        System.out.println(channel + ": " + message);
    }
    @Override
    public void message(String pattern, String channel, String message) {
        System.out.println("[" + pattern + "] " + channel + ": " + message);
    }
});
RedisPubSubAsyncCommands<String, String> pubSubCmds = pubSubConn.async();
pubSubCmds.subscribe("channel").get();
pubSubCmds.psubscribe("events.*").get();
```

**GLIDE (static subscriptions - at client creation):**
```java
import glide.api.models.configuration.*;
import glide.api.models.configuration.StandaloneSubscriptionConfiguration.PubSubChannelMode;

BaseSubscriptionConfiguration.MessageCallback callback = (msg, ctx) -> {
    System.out.println("Channel: " + msg.getChannel());
    System.out.println("Message: " + msg.getMessage());
    msg.getPattern().ifPresent(p -> System.out.println("Pattern: " + p));
};

StandaloneSubscriptionConfiguration subConfig =
    StandaloneSubscriptionConfiguration.builder()
        .subscription(PubSubChannelMode.EXACT, "channel")
        .subscription(PubSubChannelMode.PATTERN, "events.*")
        .callback(callback)
        .build();

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().port(6379).build())
    .subscriptionConfiguration(subConfig)
    .build();

GlideClient subscriber = GlideClient.createClient(config).get();
```

**GLIDE (dynamic subscriptions - GLIDE 2.3+):**
```java
// Subscribe (non-blocking)
client.subscribe(Set.of("news", "events")).get();
client.psubscribe(Set.of("events.*")).get();

// Subscribe with timeout (blocking, waits for server confirmation)
client.subscribe(Set.of("alerts"), 5000).get();
client.psubscribe(Set.of("logs.*"), 5000).get();

// Receive via polling (when no callback configured)
PubSubMessage msg = client.tryGetPubSubMessage();      // non-blocking, returns null
CompletableFuture<PubSubMessage> future = client.getPubSubMessage();  // async wait

// Unsubscribe
client.unsubscribe(Set.of("news")).get();
client.punsubscribe(Set.of("events.*")).get();
client.unsubscribe();     // all channels
client.punsubscribe();    // all patterns
```

Lettuce uses a listener adapter pattern (RedisPubSubAdapter) on a dedicated PubSub connection. GLIDE uses callbacks (set at creation time) or polling (getPubSubMessage / tryGetPubSubMessage). Both require a dedicated client for subscriptions. GLIDE automatically resubscribes on reconnection.

---

## Spring Data Valkey as an Alternative

For Spring Data Redis with Lettuce, Spring Data Valkey (`spring-boot-starter-data-valkey`) is an alternative to direct migration. Set `spring.data.valkey.client-type=valkeyglide` to use the GLIDE driver. Migration involves renaming `RedisTemplate` to `ValkeyTemplate` and `ReactiveRedisTemplate` to `ReactiveValkeyTemplate`. The reactive API remains Lettuce-based, not GLIDE.

---

## Lettuce Compatibility Layer Status

Unlike the Jedis compatibility layer (production-ready), a Lettuce compatibility layer is **not yet implemented**. Until it ships, migration requires either the Spring Data Valkey path (see above) or a full rewrite to the native GLIDE API.
