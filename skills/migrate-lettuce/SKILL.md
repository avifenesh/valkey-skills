---
name: migrate-lettuce
description: "Use when migrating Java applications from Lettuce to Valkey GLIDE. Covers Spring Data Valkey, compatibility layer, and native rewrite paths. No reactive API equivalent, PubSub, codec gaps. Not for Jedis migration - use migrate-jedis instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from Lettuce to Valkey GLIDE (Java)

Use when migrating a Java application from Lettuce to the GLIDE client library.

---

## Key Differences

| Area | Lettuce | GLIDE |
|------|---------|-------|
| Async model | RedisFuture<T> (extends CompletionStage) | CompletableFuture<T> |
| Connection | RedisClient.create(uri) | GlideClient.createClient(config).get() |
| Cluster | RedisClusterClient | GlideClusterClient |
| Configuration | RedisURI + ClientOptions | GlideClientConfiguration.builder() |
| Connection model | Multiplexed (like GLIDE) | Multiplexed - single connection per node |
| Reactive API | Project Reactor (Flux/Mono) | Not available - async only |
| Codecs | Configurable via RedisCodec | String and GlideString (binary) |
| Transactions | MULTI/EXEC API | Batch(true) |
| Pipelines | Auto-flush or manual setAutoFlushCommands | Batch(false) |

Both Lettuce and GLIDE use async, multiplexed connections - so the migration is structurally smoother than from Jedis or redis-py.

---

## Connection Setup

**Lettuce:**
```java
import io.lettuce.core.RedisClient;
import io.lettuce.core.RedisURI;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.api.async.RedisAsyncCommands;

RedisClient redisClient = RedisClient.create(
    RedisURI.builder()
        .withHost("localhost")
        .withPort(6379)
        .withDatabase(0)
        .build()
);
StatefulRedisConnection<String, String> connection = redisClient.connect();
RedisAsyncCommands<String, String> commands = connection.async();
```

**GLIDE:**
```java
import glide.api.GlideClient;
import glide.api.models.configuration.GlideClientConfiguration;
import glide.api.models.configuration.NodeAddress;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .databaseId(0)
    .requestTimeout(5000)
    .build();

GlideClient client = GlideClient.createClient(config).get();
```

GLIDE has fewer layers - no separate connection and commands objects. The client exposes commands directly.

---

## Configuration Mapping

| Lettuce parameter | GLIDE equivalent |
|-------------------|------------------|
| RedisURI.withHost() | NodeAddress.builder().host() |
| RedisURI.withPort() | NodeAddress.builder().port() |
| RedisURI.withDatabase() | .databaseId() |
| RedisURI.withPassword() | ServerCredentials.builder().password() |
| RedisURI.withSsl(true) | .useTLS(true) |
| RedisURI.withTimeout() | .requestTimeout() |
| ClientOptions.autoReconnect() | Built-in - always auto-reconnects |
| ClientResources | Not applicable - managed by Rust core |

---

## String Operations

**Lettuce (async):**
```java
RedisFuture<String> setResult = commands.set("key", "value");
setResult.get();
RedisFuture<String> getResult = commands.get("key");
String val = getResult.get();

// With expiry
commands.setex("key", 60, "value").get();
// Conditional
commands.setnx("key", "value").get();
```

**GLIDE:**
```java
import glide.api.models.commands.SetOptions;
import static glide.api.models.commands.SetOptions.Expiry;

client.set("key", "value").get();
String val = client.get("key").get();

// With expiry
client.set("key", "value",
    SetOptions.builder().expiry(Expiry.Seconds(60L)).build()).get();
// Conditional
client.set("key", "value",
    SetOptions.builder().conditionalSetOnlyIfNotExist().build()).get();
```

Both return futures - the .get() pattern is the same. The main difference is CompletableFuture (GLIDE) vs RedisFuture (Lettuce).

---

## Hash Operations

**Lettuce:**
```java
commands.hset("hash", "field1", "value1").get();
commands.hset("hash", Map.of("f1", "v1", "f2", "v2")).get();
String val = commands.hget("hash", "field1").get();
Map<String, String> all = commands.hgetall("hash").get();
```

**GLIDE:**
```java
client.hset("hash", Map.of("field1", "value1")).get();
client.hset("hash", Map.of("f1", "v1", "f2", "v2")).get();
String val = client.hget("hash", "field1").get();
Map<String, String> all = client.hgetall("hash").get();
```

Nearly identical. The only difference is that Lettuce hset accepts a single field-value pair as separate args, while GLIDE always takes a Map.

---

## List Operations

**Lettuce:**
```java
commands.lpush("list", "a", "b", "c").get();          // varargs
commands.rpush("list", "x", "y").get();
String val = commands.lpop("list").get();
List<String> range = commands.lrange("list", 0, -1).get();
```

**GLIDE:**
```java
client.lpush("list", new String[]{"a", "b", "c"}).get();  // array
client.rpush("list", new String[]{"x", "y"}).get();
String val = client.lpop("list").get();
String[] range = client.lrange("list", 0, -1).get();
```

---

## Set Operations

**Lettuce:**
```java
commands.sadd("set", "a", "b", "c").get();
commands.srem("set", "a").get();
Set<String> members = commands.smembers("set").get();
```

**GLIDE:**
```java
client.sadd("set", new String[]{"a", "b", "c"}).get();
client.srem("set", new String[]{"a"}).get();
Set<String> members = client.smembers("set").get();
```

---

## Sorted Set Operations

**Lettuce:**
```java
import io.lettuce.core.ScoredValue;

commands.zadd("zset", 1.0, "alice").get();
commands.zadd("zset", ScoredValue.just(1.0, "alice"),
                      ScoredValue.just(2.0, "bob")).get();
Double score = commands.zscore("zset", "alice").get();
```

**GLIDE:**
```java
client.zadd("zset", Map.of("alice", 1.0, "bob", 2.0)).get();
Double score = client.zscore("zset", "alice").get();
```

---

## Delete and Exists

**Lettuce:**
```java
commands.del("k1", "k2", "k3").get();         // varargs
long count = commands.exists("k1", "k2").get();
```

**GLIDE:**
```java
client.del(new String[]{"k1", "k2", "k3"}).get();   // array
long count = client.exists(new String[]{"k1", "k2"}).get();
```

---

## Cluster Mode

**Lettuce:**
```java
import io.lettuce.core.cluster.RedisClusterClient;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;

RedisClusterClient clusterClient = RedisClusterClient.create(
    List.of(
        RedisURI.create("node1.example.com", 6379),
        RedisURI.create("node2.example.com", 6380)
    )
);
StatefulRedisClusterConnection<String, String> conn = clusterClient.connect();
```

**GLIDE:**
```java
import glide.api.GlideClusterClient;
import glide.api.models.configuration.GlideClusterClientConfiguration;
import glide.api.models.configuration.ReadFrom;

GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .address(NodeAddress.builder().host("node2.example.com").port(6380).build())
    .readFrom(ReadFrom.PREFER_REPLICA)
    .build();

GlideClusterClient client = GlideClusterClient.createClient(config).get();
```

Both auto-discover topology. GLIDE adds AZ Affinity and proactive background monitoring.

---

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

Lettuce uses a listener adapter pattern (RedisPubSubAdapter) on a dedicated PubSub connection. GLIDE uses either callbacks (set at creation time) or polling (getPubSubMessage / tryGetPubSubMessage). Both require a dedicated client for subscriptions. GLIDE automatically resubscribes on reconnection.

---

## Spring Data Valkey as an Alternative

If your application uses Spring Data Redis with Lettuce, consider Spring Data Valkey (`spring-boot-starter-data-valkey`) instead of a direct migration. Set `spring.data.valkey.client-type=valkeyglide` to use the GLIDE driver. Migration involves renaming `RedisTemplate` to `ValkeyTemplate` and `ReactiveRedisTemplate` to `ReactiveValkeyTemplate`. Note: the reactive API remains Lettuce-based, not GLIDE.

---

## Lettuce Compatibility Layer Status

Unlike the Jedis compatibility layer (production-ready), a Lettuce compatibility layer is **not yet implemented**. Until it ships, migration requires either the Spring Data Valkey path (see above) or a full rewrite to the native GLIDE API.

---

## Incremental Migration Strategy

Three migration paths exist, from least effort to most control:

1. **Spring Data Valkey** (lowest effort): If using Spring, swap the driver to GLIDE in properties. No application code changes. See the Spring Data Valkey section above.
2. **Lettuce compatibility layer** (not yet available): When shipped, this will provide a drop-in wrapper.
3. **Native GLIDE migration** (full control): Introduce a service/DAO abstraction, implement it with GLIDE, migrate one service at a time, and remove Lettuce when complete.

For native migration, the key steps:
1. Add `valkey-glide` alongside Lettuce in your build
2. Replace `RedisFuture<T>` with `CompletableFuture<T>` at each call site
3. Remove `StatefulRedisConnection` / `RedisAsyncCommands` layers - GLIDE client exposes commands directly
4. Migrate services one at a time behind an interface
5. Remove Lettuce dependency once all services are migrated
6. Review `best-practices/production.md` for timeout tuning, connection management, and observability setup

---

## See Also

- **valkey-glide-java** skill - full GLIDE Java API details
- Batching (see valkey-glide skill) - pipeline and transaction patterns
- AZ Affinity (see valkey-glide skill) - availability zone aware routing
- OpenTelemetry (see valkey-glide skill) - observability integration
- TLS and authentication (see valkey-glide skill) - TLS setup and credential management
- Production deployment (see valkey-glide skill) - timeout tuning, connection management, observability
- Error handling (see valkey-glide skill) - error types, reconnection, batch error semantics

---

## Gotchas

1. **No reactive API.** Lettuce offers Project Reactor support (Flux/Mono). GLIDE only provides CompletableFuture. If you rely on reactive streams, you need to adapt with `Mono.fromFuture()`. This is significant for Spring WebFlux applications - the reactive `ReactiveRedisTemplate` is only available with the Lettuce driver in Spring Data Valkey, not with GLIDE.

2. **No codec system.** Lettuce RedisCodec for custom serialization has no equivalent. GLIDE works with String and GlideString (binary). Applications using custom serializers (Kryo, Jackson, etc.) must handle serialization manually.

3. **Single-field hset.** Lettuce hset("hash", "field", "value") takes three string args. GLIDE always takes a Map: hset("hash", Map.of("field", "value")).

4. **Array args for lists.** Multi-element commands like lpush, rpush, sadd take String[] arrays instead of varargs.

5. **No ClientResources.** Lettuce ClientResources for thread pool and event loop configuration has no equivalent. GLIDE Rust core manages its own threading.

6. **Simpler connection lifecycle.** No separate StatefulConnection and Commands objects. The GLIDE client exposes commands directly and handles connection lifecycle internally.

7. **Multi-arch native library distribution.** GLIDE requires platform-specific classifiers. Use `osdetector-gradle-plugin` or `os-maven-plugin` to auto-detect. An uber JAR bundling all platforms is available from GLIDE 2.3.

8. **No Sentinel support.** Lettuce supports Redis Sentinel for HA discovery. GLIDE does not - use cluster mode or direct connection instead.
