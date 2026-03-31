---
name: migrate-jedis
description: "Use when migrating Java applications from Jedis to Valkey GLIDE. Covers API mapping, configuration changes, connection setup, error handling differences, and common migration gotchas."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from Jedis to Valkey GLIDE (Java)

Use when migrating a Java application from Jedis to the GLIDE client library.

---

## Key Differences

| Area | Jedis | GLIDE |
|------|-------|-------|
| API model | Synchronous, returns values directly | Async - returns CompletableFuture<T>, call .get() for sync |
| Configuration | JedisPool / JedisPoolConfig | GlideClientConfiguration.builder() |
| Connection model | Thread-per-connection pool | Single multiplexed connection per node |
| Multi-arg commands | Varargs: del("k1", "k2") | Array args: del(new String[]{"k1", "k2"}) |
| Expiry | Separate methods: setex(), psetex() | SetOptions.builder().expiry(Seconds(60L)) |
| Conditional SET | Separate setnx() | SetOptions.builder().conditionalSetOnlyIfNotExist() |
| Transactions | Transaction (extends Pipeline) | Batch(true) for atomic, Batch(false) for pipeline |

---

## Migration Paths

### Path 1: Jedis Compatibility Layer (Zero-Code-Change)

Drop-in wrapper implementing the Jedis API backed by GLIDE (GLIDE 2.1+). Add `io.valkey:valkey-glide-jedis-compatibility` and swap the classpath - existing `redis.clients.jedis.Jedis` code works without recompile.

**Supported (GLIDE 2.3)**: Core string/hash/list/set, streams, sorted sets, geospatial, scripting/functions, ACL, server management, transactions (WATCH/MULTI/EXEC - see gotchas). **Not yet supported**: PubSub (JedisPubSub callbacks, sharded PubSub), pipelining (use native Batch API), CommandArguments/IParams builder pattern.

### Path 2: Full Native Migration

Migrate directly to the GLIDE native API for full feature access. This guide covers this path.

---

## Connection Setup

**Jedis:**
```java
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

JedisPoolConfig poolConfig = new JedisPoolConfig();
poolConfig.setMaxTotal(10);
JedisPool pool = new JedisPool(poolConfig, "localhost", 6379);

try (Jedis jedis = pool.getResource()) {
    jedis.ping();
}
```

**GLIDE:**
```java
import glide.api.GlideClient;
import glide.api.models.configuration.GlideClientConfiguration;
import glide.api.models.configuration.NodeAddress;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .requestTimeout(5000)
    .build();

try (GlideClient client = GlideClient.createClient(config).get()) {
    client.ping().get();
}
```

No connection pool configuration needed. GLIDE uses a single multiplexed connection.

---

## Configuration Mapping

| Jedis parameter | GLIDE equivalent |
|-----------------|------------------|
| JedisPool(host, port) | NodeAddress.builder().host().port().build() |
| JedisPoolConfig.setMaxTotal() | Not needed - single multiplexed connection |
| password | ServerCredentials.builder().password().build() |
| database | databaseId() |
| ssl = true | useTLS(true) |
| timeout (ms) | requestTimeout() (ms) |

---

## String Operations

**Jedis:**
```java
jedis.set("key", "value");
jedis.setex("key", 60, "value");           // set + 60s expiry
jedis.setnx("key", "value");               // set if not exists
String val = jedis.get("key");
```

**GLIDE:**
```java
import glide.api.models.commands.SetOptions;
import static glide.api.models.commands.SetOptions.Expiry;

client.set("key", "value").get();
client.set("key", "value",
    SetOptions.builder().expiry(Expiry.Seconds(60L)).build()).get();
client.set("key", "value",
    SetOptions.builder().conditionalSetOnlyIfNotExist().build()).get();
String val = client.get("key").get();
```

---

## Hash Operations

**Jedis:**
```java
jedis.hset("hash", "field1", "value1");
Map<String, String> map = new HashMap<>();
map.put("f1", "v1");
map.put("f2", "v2");
jedis.hset("hash", map);
String val = jedis.hget("hash", "field1");
Map<String, String> all = jedis.hgetAll("hash");
```

**GLIDE:**
```java
import java.util.Map;

client.hset("hash", Map.of("field1", "value1")).get();
client.hset("hash", Map.of("f1", "v1", "f2", "v2")).get();
String val = client.hget("hash", "field1").get();
Map<String, String> all = client.hgetall("hash").get();
```

---

## List Operations

**Jedis:**
```java
jedis.lpush("list", "a", "b", "c");        // varargs
jedis.rpush("list", "x", "y");
String val = jedis.lpop("list");
List<String> range = jedis.lrange("list", 0, -1);
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

**Jedis:**
```java
jedis.sadd("set", "a", "b", "c");
jedis.srem("set", "a");
Set<String> members = jedis.smembers("set");
```

**GLIDE:**
```java
client.sadd("set", new String[]{"a", "b", "c"}).get();
client.srem("set", new String[]{"a"}).get();
Set<String> members = client.smembers("set").get();
```

---

## Sorted Set Operations

**Jedis:**
```java
jedis.zadd("zset", 1.0, "alice");
Map<String, Double> scoreMembers = Map.of("alice", 1.0, "bob", 2.0);
jedis.zadd("zset", scoreMembers);
Double score = jedis.zscore("zset", "alice");
```

**GLIDE:**
```java
import java.util.Map;

client.zadd("zset", Map.of("alice", 1.0, "bob", 2.0)).get();
Double score = client.zscore("zset", "alice").get();
```

---

## Delete and Exists

**Jedis:**
```java
jedis.del("k1", "k2", "k3");              // varargs
long count = jedis.exists("k1", "k2");
```

**GLIDE:**
```java
client.del(new String[]{"k1", "k2", "k3"}).get();  // array
long count = client.exists(new String[]{"k1", "k2"}).get();
```

---

## Cluster Mode

**Jedis:**
```java
import redis.clients.jedis.JedisCluster;

Set<HostAndPort> nodes = new HashSet<>();
nodes.add(new HostAndPort("node1.example.com", 6379));
nodes.add(new HostAndPort("node2.example.com", 6380));
JedisCluster cluster = new JedisCluster(nodes);
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

## Error Handling

**Jedis:**
```java
try {
    jedis.get("key");
} catch (JedisException e) {
    // handle
}
```

**GLIDE:**
```java
try {
    client.get("key").get();
} catch (java.util.concurrent.ExecutionException e) {
    if (e.getCause() instanceof RequestException) {
        // command-level error
    }
}
```

All GLIDE commands return CompletableFuture. Exceptions are wrapped in ExecutionException when calling .get().

---

## Spring Data Valkey as an Alternative

If your application uses Spring Data Redis with Jedis, consider Spring Data Valkey instead of a direct migration. Set `spring.data.valkey.client-type=valkeyglide` in your properties. The migration involves a package rename (`redis` to `valkey`) and class rename (`RedisTemplate` to `ValkeyTemplate`). An automated `sed` script is provided in the Spring Data Valkey MIGRATION.md.

---

## Incremental Migration Strategy

For native GLIDE migration (not using the compatibility layer):

1. Add the `valkey-glide` Maven/Gradle dependency alongside Jedis
2. Create a repository or DAO abstraction layer if one does not already exist
3. Migrate one DAO implementation at a time from Jedis to GLIDE
4. Replace `JedisPool.getResource()` calls with the GLIDE client - no pool management needed
5. Add `.get()` calls on all commands since GLIDE returns `CompletableFuture<T>`
6. Run integration tests after each DAO migration
7. Remove the Jedis dependency once all implementations are migrated
8. Review `best-practices/production.md` for timeout tuning, connection management, and observability setup

For the zero-code-change path using the Jedis compatibility layer, see the Migration Paths section above.

---

## See Also

- **valkey-glide-java** skill - full GLIDE Java API details
- [Batching](../features/batching.md) - pipeline and transaction patterns
- [TLS and authentication](../features/tls-auth.md) - TLS setup and credential management
- [Production deployment](../best-practices/production.md) - timeout tuning, connection management, observability
- [Error handling](../best-practices/error-handling.md) - error types, reconnection, batch error semantics
- [OpenTelemetry](../features/opentelemetry.md) - observability integration

---

## Gotchas

1. **Every command returns CompletableFuture.** You must call .get() for synchronous behavior. Forgetting .get() means the command fires but you never wait for the result.

2. **Array args, not varargs.** Multi-key commands take String[] arrays, not varargs.

3. **No connection pool management.** Drop JedisPool and JedisPoolConfig entirely. GLIDE handles connection multiplexing internally.

4. **Builder pattern everywhere.** Configuration, set options, and batch options all use the builder pattern.

5. **Batch replaces Transaction and Pipeline.** The Transaction class is deprecated since GLIDE 2.0. Use new Batch(true) for atomic (transactional) and new Batch(false) for non-atomic (pipeline) running.

6. **Classifier required in Maven/Gradle.** The GLIDE artifact requires an OS-specific classifier. Use os-maven-plugin or osdetector-gradle-plugin to detect it automatically. An uber JAR (GLIDE 2.3+) bundles all native libraries. JDK 8 support also starts at GLIDE 2.3 - earlier versions require JDK 11+.

7. **Compatibility layer gotchas.** After calling `multi()`, you must use the returned `Transaction` object for subsequent commands - calling `jedis.set()` directly does NOT queue to the transaction. Also, `HashSet<byte[]>` operations (smembers, sinter, sunion, sdiff) degrade to O(n) because `byte[].hashCode()` returns identity hash.

8. **No Sentinel support.** Jedis supports Redis Sentinel for HA discovery. GLIDE does not - use cluster mode or direct connection instead.
