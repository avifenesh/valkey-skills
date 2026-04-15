# Lettuce to GLIDE API Mapping

Use when migrating specific Lettuce commands to their GLIDE equivalents, looking up return type differences, or converting data type operations.

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

Both return futures with the same .get() pattern. The type changes from RedisFuture (Lettuce) to CompletableFuture (GLIDE).

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

Lettuce hset accepts a single field-value pair as separate args; GLIDE always takes a Map.

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
