# Jedis to GLIDE Advanced Patterns

Use when migrating Jedis transactions, pipelines, Pub/Sub, or evaluating Spring Data Valkey as an alternative migration path.

## Contents

- Transactions and Pipelines (line 12)
- Pub/Sub (line 47)
- Spring Data Valkey as an Alternative (line 119)

---

## Transactions and Pipelines

**Jedis:**
```java
// Pipeline
Pipeline pipe = jedis.pipelined();
pipe.set("k1", "v1");
pipe.get("k1");
List<Object> results = pipe.syncAndReturnAll();

// Transaction
Transaction tx = jedis.multi();
tx.set("k1", "v1");
tx.get("k1");
List<Object> results2 = tx.exec();
```

**GLIDE:**
```java
import glide.api.models.Batch;

// Pipeline (non-atomic)
Batch pipeline = new Batch(false);
pipeline.set("k1", "v1");
pipeline.get("k1");
Object[] results = client.exec(pipeline, false).get();

// Transaction (atomic)
Batch tx = new Batch(true);
tx.set("k1", "v1");
tx.get("k1");
Object[] results2 = client.exec(tx, false).get();
```

The second parameter to exec() is raiseOnError - when true, throws on the first error; when false, returns errors inline in the result array.

---

## Pub/Sub

**Jedis:**
```java
JedisPubSub listener = new JedisPubSub() {
    @Override
    public void onMessage(String channel, String message) {
        System.out.println(channel + ": " + message);
    }
    @Override
    public void onPMessage(String pattern, String channel, String message) {
        System.out.println("[" + pattern + "] " + channel + ": " + message);
    }
};

// Blocking call - runs in a separate thread
new Thread(() -> jedis.psubscribe(listener, "events.*")).start();
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

Use a dedicated client for subscriptions - a subscribing client enters a special mode where most regular commands are unavailable. GLIDE automatically resubscribes on reconnection. Callback and polling modes are mutually exclusive on the same client.

---

## Spring Data Valkey as an Alternative

For Spring Data Redis with Jedis, Spring Data Valkey is an alternative to direct migration. Set `spring.data.valkey.client-type=valkeyglide` in properties. The migration involves a package rename (`redis` to `valkey`) and class rename (`RedisTemplate` to `ValkeyTemplate`). An automated `sed` script is provided in the Spring Data Valkey MIGRATION.md.
