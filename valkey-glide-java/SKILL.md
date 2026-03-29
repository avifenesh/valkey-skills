---
name: valkey-glide-java
description: "Use when building Java applications with Valkey GLIDE. Covers CompletableFuture API, GlideClient, configuration builders, TLS, authentication, OpenTelemetry, error handling, batching, Spring integration, and migration from Jedis/Lettuce."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey GLIDE Java Client

Self-contained guide for building Java/JVM applications with Valkey GLIDE. Covers the CompletableFuture-based API, configuration, error handling, batching, Spring Data Valkey integration, and migration from both Jedis and Lettuce. For architecture concepts shared across all languages (connection model, topology discovery, protocol details), see the `valkey-glide` skill.

## Installation

**Requirements:** JDK 11+ (JDK 8 supported from GLIDE 2.3)

### Gradle

Requires the OS detector plugin for platform-specific native binaries:

```gradle
plugins {
    id "com.google.osdetector" version "1.7.3"
}

dependencies {
    implementation group: 'io.valkey', name: 'valkey-glide',
                  version: '2.+', classifier: osdetector.classifier
}
```

### Maven

```xml
<dependency>
    <groupId>io.valkey</groupId>
    <artifactId>valkey-glide</artifactId>
    <classifier>${os.detected.classifier}</classifier>
    <version>[2.0.0,)</version>
</dependency>
```

Maven requires the `os-maven-plugin` extension to resolve `${os.detected.classifier}`.

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64), Windows (x86_64), Alpine Linux.

**Classifiers:** `osx-aarch_64`, `osx-x86_64`, `linux-aarch_64`, `linux-x86_64`, `linux_musl-aarch_64`, `linux_musl-x86_64`, `windows-x86_64`. An uber JAR bundling all platforms is available from GLIDE 2.3.

---

## Client Classes

| Class | Mode | Description |
|-------|------|-------------|
| `GlideClient` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | Cluster | Valkey Cluster with auto-topology |

Both extend `BaseClient`, return `CompletableFuture` from all commands, and implement `AutoCloseable`.

---

## Standalone Connection

```java
import glide.api.GlideClient;
import glide.api.models.configuration.GlideClientConfiguration;
import glide.api.models.configuration.NodeAddress;

public class QuickStart {
    public static void main(String[] args) throws Exception {
        GlideClientConfiguration config = GlideClientConfiguration.builder()
            .address(NodeAddress.builder()
                .host("localhost")
                .port(6379)
                .build())
            .requestTimeout(5000)
            .build();

        try (GlideClient client = GlideClient.createClient(config).get()) {
            client.set("greeting", "Hello from GLIDE").get();
            String value = client.get("greeting").get();
            System.out.println("Got: " + value);
        }
    }
}
```

Use try-with-resources - `GlideClient` implements `AutoCloseable`.

---

## Cluster Connection

```java
import glide.api.GlideClusterClient;
import glide.api.models.configuration.GlideClusterClientConfiguration;
import glide.api.models.configuration.NodeAddress;
import glide.api.models.configuration.ReadFrom;

GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .address(NodeAddress.builder().host("node2.example.com").port(6380).build())
    .readFrom(ReadFrom.PREFER_REPLICA)
    .build();

GlideClusterClient client = GlideClusterClient.createClient(config).get();

client.set("key", "value").get();
String value = client.get("key").get();

client.close();
```

Only seed addresses needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration - Standalone

All configuration uses Lombok builders. Package: `glide.api.models.configuration`.

```java
import glide.api.models.configuration.*;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .useTLS(true)
    .readFrom(ReadFrom.PREFER_REPLICA)
    .credentials(ServerCredentials.builder()
        .username("myuser")
        .password("mypass")
        .build())
    .requestTimeout(5000)
    .reconnectStrategy(BackoffStrategy.builder()
        .numOfRetries(5)
        .factor(100)
        .exponentBase(2)
        .jitterPercent(20)
        .build())
    .databaseId(0)
    .clientName("my-app")
    .inflightRequestsLimit(1000)
    .readOnly(true)
    .build();
```

## Configuration - Cluster

```java
GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAz("us-east-1a")
    .build();
```

---

## Authentication

### Password-Based

```java
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .password("mypass")
    .build();
```

### IAM Authentication

```java
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .iamConfig(IamAuthConfig.builder()
        .clusterName("my-cluster")
        .service(ServiceType.ELASTICACHE)
        .region("us-east-1")
        .build())
    .build();
```

Password and IAM are mutually exclusive.

---

## Reconnection Strategy

```java
BackoffStrategy strategy = BackoffStrategy.builder()
    .numOfRetries(5)       // escalation attempts before constant retry
    .factor(100)           // base delay in milliseconds
    .exponentBase(2)       // exponential growth factor
    .jitterPercent(20)     // optional jitter percentage
    .build();
```

Formula: `factor * (exponentBase ^ N)` with optional `jitterPercent` as a percentage of the computed duration.

---

## ReadFrom Options

| Value | Behavior |
|-------|----------|
| `PRIMARY` | All reads to primary (default) |
| `PREFER_REPLICA` | Round-robin replicas, fallback to primary |
| `AZ_AFFINITY` | Prefer same-AZ replicas (requires `clientAz`) |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then primary, then remote |

AZ Affinity requires Valkey 8.0+ and `clientAz` must be set.

---

## Error Handling

All async methods return `CompletableFuture`. Errors surface as `ExecutionException` wrapping the actual error.

### Blocking Pattern

```java
import java.util.concurrent.ExecutionException;

try {
    String value = client.get("key").get();
} catch (ExecutionException e) {
    Throwable cause = e.getCause();
    if (cause instanceof glide.api.models.exceptions.RequestException) {
        System.err.println("Request failed: " + cause.getMessage());
    }
}
```

### Non-Blocking Pattern

```java
client.get("key")
    .thenAccept(value -> System.out.println("Got: " + value))
    .exceptionally(e -> {
        System.err.println("Failed: " + e.getMessage());
        return null;
    });
```

---

## Data Type Operations

### Strings

```java
import glide.api.models.commands.SetOptions;
import static glide.api.models.commands.SetOptions.Expiry;

client.set("key", "value").get();
client.set("key", "value",
    SetOptions.builder().expiry(Expiry.Seconds(60L)).build()).get();
client.set("key", "value",
    SetOptions.builder().conditionalSetOnlyIfNotExist().build()).get();
String val = client.get("key").get();
long count = client.incr("counter").get();
long count2 = client.incrBy("counter", 5).get();
client.mset(Map.of("k1", "v1", "k2", "v2")).get();
String[] vals = client.mget(new String[]{"k1", "k2"}).get();
```

No separate `setex`/`setnx` - use `SetOptions` on `set()`.

### Hashes

```java
import java.util.Map;

client.hset("hash", Map.of("field1", "value1")).get();
client.hset("hash", Map.of("f1", "v1", "f2", "v2")).get();
String val = client.hget("hash", "field1").get();
Map<String, String> all = client.hgetall("hash").get();
boolean exists = client.hexists("hash", "field1").get();
long deleted = client.hdel("hash", new String[]{"field1"}).get();
String[] keys = client.hkeys("hash").get();
String[] hvals = client.hvals("hash").get();
long length = client.hlen("hash").get();
```

### Lists

```java
client.lpush("list", new String[]{"a", "b", "c"}).get();  // array, not varargs
client.rpush("list", new String[]{"x", "y"}).get();
String val = client.lpop("list").get();
String[] range = client.lrange("list", 0, -1).get();
long length = client.llen("list").get();
client.lset("list", 0, "new_value").get();
client.ltrim("list", 0, 99).get();
```

### Sets

```java
client.sadd("set", new String[]{"a", "b", "c"}).get();
client.srem("set", new String[]{"a"}).get();
Set<String> members = client.smembers("set").get();
boolean isMember = client.sismember("set", "b").get();
long cardinality = client.scard("set").get();
Set<String> inter = client.sinter(new String[]{"set1", "set2"}).get();
```

### Sorted Sets

```java
client.zadd("zset", Map.of("alice", 1.0, "bob", 2.0)).get();
Double score = client.zscore("zset", "alice").get();
Long rank = client.zrank("zset", "alice").get();
long card = client.zcard("zset").get();
long removed = client.zrem("zset", new String[]{"alice"}).get();
```

### Delete and Exists

```java
client.del(new String[]{"k1", "k2", "k3"}).get();  // array
long count = client.exists(new String[]{"k1", "k2"}).get();
client.expire("key", 60).get();
long ttl = client.ttl("key").get();
String keyType = client.type("key").get();
```

---

## Batching

### Transaction (Atomic)

```java
import glide.api.models.Batch;

Batch tx = new Batch(true);
tx.set("key", "value");
tx.incr("counter");
tx.get("key");
Object[] result = client.exec(tx, false).get();
// result: ["OK", 1L, "value"]
```

### Pipeline (Non-Atomic)

```java
Batch batch = new Batch(false);
batch.set("k1", "v1");
batch.set("k2", "v2");
batch.get("k1");
Object[] result = client.exec(batch, false).get();
```

The second parameter to `run()` is `raiseOnError` - when true, throws on the first error; when false, returns errors inline in the result array.

---

## Jedis Compatibility Layer

Drop-in Jedis replacement (GLIDE 2.1+). Add `io.valkey:valkey-glide-jedis-compatibility` and swap the classpath - existing `redis.clients.jedis.Jedis` code works without recompile.

**Supported (GLIDE 2.3):** Core string/hash/list/set, streams, sorted sets, geospatial, scripting/functions, ACL, server management, transactions (WATCH/MULTI/RUN).

**Not yet supported:** PubSub (JedisPubSub callbacks, sharded PubSub), pipelining (use native Batch API), CommandArguments/IParams builder pattern.

---

## Spring Data Valkey

Spring Data Valkey provides GLIDE as a first-class driver.

**From Spring Data Redis with Jedis:** Set `spring.data.valkey.client-type=valkeyglide`. Migration involves a package rename (`redis` to `valkey`) and class rename (`RedisTemplate` to `ValkeyTemplate`). An automated `sed` script is provided in the Spring Data Valkey MIGRATION.md.

**From Spring Data Redis with Lettuce:** Set `spring.data.valkey.client-type=glide` to use the GLIDE driver while keeping the Spring RedisTemplate API. Gives GLIDE Rust core benefits (AZ affinity, OpenTelemetry, reconnection) with no application code changes. Note: the reactive `ReactiveRedisTemplate` is only available with the Lettuce driver, not GLIDE.

---

## Migration from Jedis

### Key Differences

| Area | Jedis | GLIDE |
|------|-------|-------|
| API model | Synchronous | Async - `CompletableFuture<T>`, call `.get()` for sync |
| Configuration | `JedisPool` / `JedisPoolConfig` | `GlideClientConfiguration.builder()` |
| Connection model | Thread-per-connection pool | Single multiplexed connection per node |
| Multi-arg commands | Varargs: `del("k1", "k2")` | Array: `del(new String[]{"k1", "k2"})` |
| Expiry | `setex()`, `psetex()` | `SetOptions.builder().expiry(Seconds(60L))` |
| Conditional SET | `setnx()` | `SetOptions.builder().conditionalSetOnlyIfNotExist()` |
| Transactions | Transaction extends Pipeline | `Batch(true)` atomic, `Batch(false)` pipeline |

### Side-by-Side: Connection Setup

**Jedis:**
```java
JedisPoolConfig poolConfig = new JedisPoolConfig();
poolConfig.setMaxTotal(10);
JedisPool pool = new JedisPool(poolConfig, "localhost", 6379);
try (Jedis jedis = pool.getResource()) {
    jedis.ping();
}
```

**GLIDE:**
```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .requestTimeout(5000)
    .build();
try (GlideClient client = GlideClient.createClient(config).get()) {
    client.ping().get();
}
```

### Side-by-Side: String Operations

**Jedis:**
```java
jedis.set("key", "value");
jedis.setex("key", 60, "value");
jedis.setnx("key", "value");
String val = jedis.get("key");
```

**GLIDE:**
```java
client.set("key", "value").get();
client.set("key", "value",
    SetOptions.builder().expiry(Expiry.Seconds(60L)).build()).get();
client.set("key", "value",
    SetOptions.builder().conditionalSetOnlyIfNotExist().build()).get();
String val = client.get("key").get();
```

### Jedis Migration Paths

**Path 1 - Zero-code-change:** Add `valkey-glide-jedis-compatibility` and swap the classpath. Existing Jedis code works without recompile.

**Path 2 - Native migration:**
1. Add `valkey-glide` alongside Jedis
2. Create a DAO abstraction layer
3. Migrate one DAO at a time
4. Replace `JedisPool.getResource()` with GLIDE client
5. Add `.get()` calls on all commands
6. Run integration tests after each migration
7. Remove Jedis dependency

---

## Migration from Lettuce

### Key Differences

| Area | Lettuce | GLIDE |
|------|---------|-------|
| Async model | `RedisFuture<T>` (CompletionStage) | `CompletableFuture<T>` |
| Connection | `RedisClient.create(uri)` | `GlideClient.createClient(config).get()` |
| Configuration | `RedisURI` + `ClientOptions` | `GlideClientConfiguration.builder()` |
| Reactive API | Project Reactor (Flux/Mono) | Not available - async only |
| Codecs | Configurable via `RedisCodec` | String and GlideString (binary) |
| Pipelines | `setAutoFlushCommands` | `Batch(false)` |

### Side-by-Side: Connection Setup

**Lettuce:**
```java
RedisClient redisClient = RedisClient.create(
    RedisURI.builder().withHost("localhost").withPort(6379).withDatabase(0).build()
);
StatefulRedisConnection<String, String> connection = redisClient.connect();
RedisAsyncCommands<String, String> commands = connection.async();
```

**GLIDE:**
```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .databaseId(0)
    .requestTimeout(5000)
    .build();
GlideClient client = GlideClient.createClient(config).get();
```

### Lettuce Migration Paths

**Path 1 - Spring Data Valkey** (lowest effort): Swap the driver in properties. No application code changes.

**Path 2 - Native migration:**
1. Add `valkey-glide` alongside Lettuce
2. Replace `RedisFuture<T>` with `CompletableFuture<T>`
3. Remove `StatefulRedisConnection` / `RedisAsyncCommands` layers
4. Migrate services one at a time behind an interface
5. Remove Lettuce dependency


## Streams

### Adding and Reading

```java
import glide.api.models.commands.stream.*;
import java.util.Map;

// Add entry with auto-generated ID
String entryId = client.xadd("mystream",
    Map.of("sensor", "temp", "value", "23.5")).get();

// Add with trimming
String entryId2 = client.xadd("mystream",
    Map.of("data", "value"),
    StreamAddOptions.builder()
        .trim(new MaxLen(false, 1000L))
        .build()
).get();

// Read from streams
Map<String, Map<String, String[][]>> entries =
    client.xread(Map.of("mystream", "0")).get();

// Read with block and count
entries = client.xread(
    Map.of("mystream", "0"),
    StreamReadOptions.builder().count(10L).block(5000L).build()
).get();
```

### Range Queries

```java
// Forward range
Map<String, String[][]> range = client.xrange("mystream", "-", "+").get();
range = client.xrange("mystream", "-", "+", 100L).get();

// Reverse range
range = client.xrevrange("mystream", "+", "-").get();

// Stream length
long length = client.xlen("mystream").get();
```

### Consumer Groups

```java
// Create group
client.xgroupCreate("mystream", "mygroup", "0").get();

// Read as consumer
Map<String, Map<String, String[][]>> messages =
    client.xreadgroup("mygroup", "consumer1",
        Map.of("mystream", ">")).get();

// Acknowledge
long ackCount = client.xack("mystream", "mygroup",
    new String[]{"1234567890123-0"}).get();

// Inspect pending
Object[] pending = client.xpending("mystream", "mygroup").get();
```

Use a dedicated client for blocking XREAD/XREADGROUP to avoid blocking the multiplexed connection.

---

## OpenTelemetry Configuration

```java
import glide.api.OpenTelemetry;

OpenTelemetry.init(
    OpenTelemetry.OpenTelemetryConfig.builder()
        .traces(
            OpenTelemetry.TracesConfig.builder()
                .endpoint("http://localhost:4318/v1/traces")
                .samplePercentage(10)
                .build()
        )
        .metrics(
            OpenTelemetry.MetricsConfig.builder()
                .endpoint("http://localhost:4318/v1/metrics")
                .build()
        )
        .flushIntervalMs(5000L)
        .build()
);

// Runtime sampling adjustment
OpenTelemetry.setSamplePercentage(5);
boolean initialized = OpenTelemetry.isInitialized();
```

### Spring Boot Integration

```properties
spring.data.valkey.valkey-glide.open-telemetry.enabled=true
spring.data.valkey.valkey-glide.open-telemetry.traces-endpoint=http://localhost:4317
spring.data.valkey.valkey-glide.open-telemetry.metrics-endpoint=http://localhost:4317
```

OTel can only be initialized once per process. Emits per-command trace spans and metrics (timeouts, retries, MOVED errors).

---

## TLS Configuration

### Basic TLS

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("valkey.example.com").port(6380).build())
    .useTLS(true)
    .build();
```

### Custom CA Certificates

```java
import glide.api.models.configuration.AdvancedGlideClientConfiguration;
import glide.api.models.configuration.TlsAdvancedConfiguration;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("valkey.example.com").port(6380).build())
    .useTLS(true)
    .advancedConfiguration(
        AdvancedGlideClientConfiguration.builder()
            .tlsAdvancedConfiguration(
                TlsAdvancedConfiguration.builder()
                    .rootCertificates(caCertBytes)
                    .build()
            )
            .build()
    )
    .build();
```

### TLS + Auth Combined

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("valkey.example.com").port(6380).build())
    .useTLS(true)
    .credentials(ServerCredentials.builder()
        .username("myuser")
        .password("mypass")
        .build())
    .advancedConfiguration(
        AdvancedGlideClientConfiguration.builder()
            .tlsAdvancedConfiguration(
                TlsAdvancedConfiguration.builder()
                    .rootCertificates(caCertBytes)
                    .build()
            )
            .build()
    )
    .build();
```

---

## PubSub Patterns

```java
// Separate subscriber and publisher clients
GlideClient subscriber = GlideClient.createClient(config).get();
GlideClient publisher = GlideClient.createClient(config).get();

// Subscribe
subscriber.subscribe(new String[]{"news", "events"}).get();

// Publish
publisher.publish("events", "Hello subscribers!").get();
```

Always use a dedicated client for subscriptions.

---

## Batch Error Handling

```java
Batch batch = new Batch(false);
batch.set("k1", "v1");
batch.get("nonexistent");
batch.incr("k1");  // will fail - not numeric

// raiseOnError=false returns errors inline in result array
Object[] results = client.exec(batch, false).get();
// results[2] is a RequestException

// raiseOnError=true throws on first error
try {
    Object[] results2 = client.exec(batch, true).get();
} catch (ExecutionException e) {
    System.err.println("Batch failed: " + e.getCause().getMessage());
}
```

---

## GLIDE-Only Features in Java

### AZ Affinity

```java
GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAz("us-east-1a")
    .build();
```

Requires Valkey 8.0+. See the `valkey-glide` skill for cross-language AZ Affinity details.

### IAM Authentication for AWS

```java
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .iamConfig(IamAuthConfig.builder()
        .clusterName("my-cluster")
        .service(ServiceType.ELASTICACHE)
        .region("us-east-1")
        .refreshIntervalSeconds(300)
        .build())
    .build();

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder()
        .host("mycluster.abc.use1.cache.amazonaws.com").port(6379).build())
    .credentials(creds)
    .useTLS(true)
    .build();
```

---

## JVM Tuning Notes

- Monitor native memory with `-XX:NativeMemoryTracking=summary` - the Rust core allocates outside the JVM heap
- The inflight request limit defaults to 1000; tune `requestTimeout` based on workload
- The `GlideString` class supports binary-safe string operations for keys and values
- Communication layer: JNI with Protobuf serialization for all commands

---

## Gotchas

1. **Every command returns CompletableFuture.** Call `.get()` for synchronous behavior. Forgetting `.get()` means the command fires but you never wait for the result.

2. **Array args, not varargs.** Multi-key commands take `String[]` arrays, not varargs.

3. **No connection pool management.** Drop `JedisPool` and `JedisPoolConfig` entirely. GLIDE handles connection multiplexing internally.

4. **Builder pattern everywhere.** Configuration, set options, and batch options all use builders.

5. **Batch replaces Transaction.** The `Transaction` class is deprecated since GLIDE 2.0. Use `new Batch(true)` for atomic, `new Batch(false)` for pipeline.

6. **Classifier required.** The GLIDE artifact requires an OS-specific classifier. Use `os-maven-plugin` or `osdetector-gradle-plugin`. The uber JAR (GLIDE 2.3+) bundles all native libraries.

7. **Compatibility layer gotchas.** After calling `multi()`, use the returned `Transaction` object - calling `jedis.set()` directly does NOT queue to the transaction. Also, `HashSet<byte[]>` degrades to O(n) because `byte[].hashCode()` returns identity hash.

8. **No reactive API.** Lettuce offers Project Reactor (Flux/Mono). GLIDE only provides CompletableFuture. Use `Mono.fromFuture()` to adapt for Spring WebFlux.

9. **No Sentinel support.** Use cluster mode or direct connection instead.

10. **No codec system.** Lettuce `RedisCodec` for custom serialization has no equivalent. Handle serialization (Jackson, Kryo, etc.) manually.

---

## Cross-References

- `valkey-glide` skill - architecture, connection model, features shared across all languages
- `valkey` skill - Valkey server commands, data types, patterns
