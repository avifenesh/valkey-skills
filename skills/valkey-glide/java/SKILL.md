---
name: valkey-glide-java
description: "Use when building Java applications with Valkey GLIDE. Covers CompletableFuture API, GlideClient, configuration builders, TLS, authentication, OpenTelemetry, error handling, batching, streams, Jedis compatibility layer, and server modules (JSON/Search)."
version: 1.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Java Client

Self-contained guide for building Java/JVM applications with Valkey GLIDE.

## Routing

- Install/setup -> Installation
- CompletableFuture API -> Client Classes, Basic Operations
- TLS/auth -> TLS and Authentication
- Streams/PubSub -> Streams, PubSub sections
- Error handling -> Error Handling
- Batching -> Batching
- JSON/Search modules -> Server Modules
- OTel/tracing -> OpenTelemetry

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
    .clientAZ("us-east-1a")
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
| `AZ_AFFINITY` | Prefer same-AZ replicas (requires `clientAZ`) |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then primary, then remote |

AZ Affinity requires Valkey 8.0+ and `clientAZ` must be set.

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

The second parameter to `exec()` is `raiseOnError` - when true, throws on the first error; when false, returns errors inline in the result array.

---

## Jedis Compatibility Layer

Drop-in Jedis replacement (GLIDE 2.1+). Add `io.valkey:valkey-glide-jedis-compatibility` and swap the classpath - existing `redis.clients.jedis.Jedis` code works without recompile.

**Supported (GLIDE 2.3):** Core string/hash/list/set, streams, sorted sets, geospatial, scripting/functions, ACL, server management, transactions (WATCH/MULTI/RUN).

**Not yet supported:** PubSub (JedisPubSub callbacks, sharded PubSub), pipelining (use native Batch API), CommandArguments/IParams builder pattern.

---

## Server Modules (JSON and Vector Search)

Requires JSON and Search modules loaded on the Valkey server. Use `Json` for JSON document operations and `FT` for search/vector indexing. Both use `customCommand` internally and work with standalone and cluster clients.

### JSON - Store and Retrieve Documents

```java
import glide.api.commands.servermodules.Json;

// Store a JSON document
Json.set(client, "user:1", "$", "{\"name\":\"Alice\",\"age\":30}").get();

// Read a nested value (JSONPath returns a JSON array string)
String name = Json.get(client, "user:1", new String[]{"$.name"}).get();
// "[\"Alice\"]"

// Increment a numeric field
Json.numincrby(client, "user:1", "$.age", 1).get();
```

### Vector Search - Create Index and Search

```java
import glide.api.commands.servermodules.FT;
import glide.api.models.commands.FT.FTCreateOptions;
import glide.api.models.commands.FT.FTCreateOptions.*;

// Create an index on HASH keys with text and tag fields
FieldInfo[] schema = new FieldInfo[] {
    new FieldInfo("title", new TextField()),
    new FieldInfo("category", new TagField()),
};
FT.create(client, "article_idx", schema, FTCreateOptions.builder()
    .dataType(DataType.HASH).prefixes(new String[]{"article:"}).build()).get();

// Search by tag filter
Object[] results = FT.search(client, "article_idx", "@category:{tech}").get();
// results[0] = total count, results[1..] = document key/value pairs
```

---

<!-- SHARED-GLIDE-SECTION: keep in sync with valkey-glide/SKILL.md -->

## Architecture

| Topic | Reference |
|-------|-----------|
| Three-layer design: Rust core, Protobuf IPC, language FFI bridges | [overview](reference/architecture/overview.md) |
| Multiplexed connections, inflight limits, request timeout, reconnect logic | [connection-model](reference/architecture/connection-model.md) |
| Cluster slot routing, MOVED/ASK handling, multi-slot splitting, ReadFrom | [cluster-topology](reference/architecture/cluster-topology.md) |


## Features

| Topic | Reference |
|-------|-----------|
| Batch API: atomic (MULTI/EXEC) and non-atomic (pipeline) modes | [batching](reference/features/batching.md) |
| PubSub: exact, pattern, and sharded subscriptions, dynamic callbacks | [pubsub](reference/features/pubsub.md) |
| Scripting: Lua EVAL/EVALSHA with SHA1 caching, FCALL Functions | [scripting](reference/features/scripting.md) |
| OpenTelemetry: per-command tracing spans, metrics export | [opentelemetry](reference/features/opentelemetry.md) |
| AZ affinity: availability-zone-aware read routing, cross-zone savings | [az-affinity](reference/features/az-affinity.md) |
| TLS, mTLS, custom CA certificates, password auth, IAM tokens | [tls-auth](reference/features/tls-auth.md) |
| Compression: transparent Zstd/LZ4 for large values (SET/GET) | [compression](reference/features/compression.md) |
| Streams: XADD, XREAD, XREADGROUP, consumer groups, XCLAIM, XAUTOCLAIM | [streams](reference/features/streams.md) |
| Server modules: GlideJson (JSON), GlideFt (Search/Vector) | [server-modules](reference/features/server-modules.md) |
| Logging: log levels, file rotation, GLIDE_LOG_DIR, debug output | [logging](reference/features/logging.md) |
| Geospatial: GEOADD, GEOSEARCH, GEODIST, proximity queries | [geospatial](reference/features/geospatial.md) |
| Bitmaps and HyperLogLog: BITCOUNT, BITFIELD, PFADD, PFCOUNT | [bitmaps-hyperloglog](reference/features/bitmaps-hyperloglog.md) |
| Hash field expiration: HSETEX, HGETEX, HEXPIRE (Valkey 9.0+) | [hash-field-expiration](reference/features/hash-field-expiration.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Performance: benchmarks, GLIDE vs native clients, batching throughput | [performance](reference/best-practices/performance.md) |
| Error handling: exception types, reconnection, retry, batch errors | [error-handling](reference/best-practices/error-handling.md) |
| Production: timeout config, connection management, cloud defaults | [production](reference/best-practices/production.md) |

<!-- END SHARED-GLIDE-SECTION -->

## Cross-References

- `valkey` skill - Valkey server commands, data types, patterns
