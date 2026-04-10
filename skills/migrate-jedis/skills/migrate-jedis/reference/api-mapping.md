# Jedis to GLIDE API Mapping

Use when migrating specific Jedis commands to their GLIDE equivalents, looking up return type differences, or converting data type operations.

## Contents

- String Operations (line 12)
- Hash Operations (line 37)
- List Operations (line 58)
- Set Operations (line 77)
- Sorted Set Operations (line 94)
- Delete and Exists (line 113)
- Cluster Mode (line 128)
- Error Handling (line 157)

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
