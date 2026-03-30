# Java Client Libraries

Use when building Java applications with Valkey, choosing between valkey-java, Redisson, GLIDE Java, or Lettuce, migrating from Jedis, or integrating with Spring Boot, Hibernate, or Quarkus.

---

> valkey-java, Jedis/Lettuce compatibility, Redisson, GLIDE Java, and Spring Data Valkey.

## valkey-java (Official Valkey Fork)

valkey-java is the official Java client for Valkey, forked from Jedis. It maintains the same simple, synchronous API while adding Valkey-native awareness.

### Install (Maven)

```xml
<dependency>
    <groupId>io.valkey</groupId>
    <artifactId>valkey-java</artifactId>
    <version>5.5.0</version>
</dependency>
```

### Version

- **Version**: Check Maven Central for latest
- **Java**: 8+
- **Server**: Valkey 7.2+

### Valkey-Specific Commands

valkey-java supports Valkey-specific commands (`SETIFEQ`, `DELIFEQ`, hash field expiration) that are not available in Jedis, making it the choice for teams using Valkey-only features.

**Adoption note**: valkey-java has limited community mindshare. Most Java users either stick with Jedis/Lettuce (endpoint swap) or adopt GLIDE.

### Basic Usage

```java
import io.valkey.Valkey;

try (Valkey client = new Valkey("localhost", 6379)) {
    client.set("key", "value");
    String result = client.get("key");
}
```

### Key Features

- Simple synchronous API
- Cluster support with automatic slot routing (`ValkeyCluster`)
- Sentinel support
- Connection pooling (Apache Commons Pool)
- Pipelines, transactions, Lua scripting
- SSL/TLS support

## Jedis Compatibility

Jedis works with Valkey by changing only the server endpoint. No code changes required.

```java
import redis.clients.jedis.Jedis;

try (Jedis client = new Jedis("valkey-server", 6379)) {
    client.set("key", "value");
}
```

AWS recommends Jedis for ElastiCache for Valkey. Jedis remains a solid choice for existing projects, though it will not track Valkey-specific features.

## Lettuce Compatibility

Lettuce is the async/reactive Java Redis client. It works with Valkey via RESP protocol compatibility.

```java
import io.lettuce.core.RedisClient;
import io.lettuce.core.api.StatefulRedisConnection;

RedisClient client = RedisClient.create("redis://valkey-server:6379");
StatefulRedisConnection<String, String> connection = client.connect();
connection.sync().set("key", "value");
```

Lettuce continues active development. Check Maven Central for the latest version.

Lettuce is recommended for:
- Reactive/async applications (Project Reactor integration)
- Spring WebFlux applications (Spring Data Redis uses Lettuce by default)
- High-concurrency scenarios (single-connection multiplexing)
- AWS ElastiCache (AWS-recommended alongside Jedis)

## Redisson

Redisson is a unique client - it provides 50+ distributed Java data structures on top of Valkey, going far beyond simple key-value operations.

### Install (Maven)

```xml
<dependency>
    <groupId>org.redisson</groupId>
    <artifactId>redisson</artifactId>
    <version>4.3.0</version>
</dependency>
```

### Valkey Support

Redisson explicitly supports both Valkey and Redis and is the most popular client with Valkey awareness. Configure for Valkey:

```java
Config config = new Config();
config.useSingleServer()
      .setAddress("redis://valkey-server:6379");

RedissonClient redisson = Redisson.create(config);
```

### Distributed Data Structures

Redisson provides Java-native distributed versions of standard data structures:

- **Locks**: `RLock`, `RReadWriteLock`, `RFencedLock`, `RSemaphore`, `RCountDownLatch`
- **Collections**: `RMap`, `RSet`, `RList`, `RQueue`, `RDeque`, `RSortedSet`, `RVectorSet`
- **Atomic**: `RAtomicLong`, `RAtomicDouble`
- **Pub/Sub**: `RTopic`, `RPatternTopic`, `RReliableTopic` (new in 4.0 - topic-subscription-consumer model with acknowledgment)
- **Queues**: `ReliableQueue` (new in 4.0), `RTransferQueue`, `RPriorityQueue`
- **Caching**: `RMapCache` with TTL per entry, `RClientSideCaching`
- **Bloom filter**: `RBloomFilter`, `RCuckooFilter` (new in 4.3)
- **Rate limiter**: `RRateLimiter`
- **ID generator**: `RIdGenerator`

### Valkey-Specific Features in Redisson

- `database` setting for Valkey Cluster Mode - leverages Valkey 9's multi-DB clustering
- All deployment topologies: Single, Cluster, Sentinel, Replicated, Master-Slave, Proxy, Multi-Cluster, Multi-Sentinel
- Client-side caching (`RClientSideCaching`)
- Active production usage on AWS ElastiCache Valkey

### Framework Integrations

Redisson integrates with the broader Java ecosystem:

| Framework | Integration |
|-----------|------------|
| Spring (Cache, Session) | `redisson-spring-boot-starter` (supports Spring Boot 4.0) |
| Hibernate (2nd-level cache) | `redisson-hibernate` |
| JCache (JSR-107) | Built-in implementation |
| MyBatis | `redisson-mybatis` |
| Quarkus | `redisson-quarkus` (supports Quarkus 3.30.x) |
| Micronaut | `redisson-micronaut` |
| Helidon | `redisson-helidon` |

### When to Choose Redisson

Choose Redisson over valkey-java or Jedis when you need:
- Distributed locking (leader election, mutex patterns)
- Java collection interfaces backed by Valkey (transparent distributed collections)
- Framework integrations (Hibernate cache, JCache, Spring Session)
- Higher-level abstractions over raw commands

## Valkey GLIDE for Java

GLIDE Java provides a Rust-core client with production-learned defaults from operating Redis-compatible services at scale, AZ-affinity, and a Jedis compatibility layer. Recent releases added Java 8 backward compatibility, uber JAR for multi-platform builds, mTLS support, read-only mode, and additional commands (`EVAL_RO`, `EVALSHA_RO`, ACL commands, `WAITAOF`).

### Install (Maven)

```xml
<dependency>
    <groupId>io.valkey</groupId>
    <artifactId>valkey-glide</artifactId>
    <version>2.3.0</version>
</dependency>
```

### Jedis Compatibility Layer

GLIDE Java includes a Jedis-compatible API wrapper that allows zero-code migration from Jedis:

```java
// Existing Jedis code works with GLIDE's Jedis compat layer
// Just swap the dependency and connection factory
```

This is particularly useful for large codebases where rewriting every Jedis call is impractical. The compatibility layer translates Jedis method calls to GLIDE operations internally.

### Native GLIDE API

```java
import glide.api.GlideClient;
import glide.api.models.configuration.GlideClientConfiguration;
import glide.api.models.configuration.NodeAddress;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .build();

GlideClient client = GlideClient.createClient(config).get();
client.set("key", "value").get();
String result = client.get("key").get();
```

For detailed GLIDE Java API coverage, AZ-affinity, batching, and advanced patterns, see the **valkey-glide** skill.

## Spring Data Valkey

Spring Data Valkey is the official first-class Spring integration for Valkey, forked from Spring Data Redis.

### Install

- **Spring Boot Starter**: `io.valkey.springframework.boot:spring-boot-starter-data-valkey`
- **Standalone**: `io.valkey.springframework.data:spring-data-valkey`

Check Maven Central for the latest version.

### Key Features

- `ValkeyTemplate` with serialization support
- Pub/Sub with `MessageListenerContainer`
- Reactive API via Lettuce driver
- OpenTelemetry instrumentation with GLIDE client
- Spring Boot Actuator health indicators and metrics
- `@DataValkeyTest` slice test annotation for integration testing
- Testcontainers integration with `@ServiceConnection`
- Docker Compose service detection

### Note on Spring Data Redis

Spring Data Redis also works with Valkey without any code changes - just point the connection at a Valkey server. Spring Data Valkey is designed for teams starting new projects on Valkey or those who want Valkey-native features and observability.

## Migration Paths

- **Jedis to valkey-java**: Drop-in replacement. Change the Maven dependency and update import from `redis.clients.jedis.Jedis` to `io.valkey.Valkey`.
- **Jedis to GLIDE Java**: Zero-code migration via the Jedis compatibility layer. Swap the dependency and connection factory.
- **Lettuce users**: No migration needed. Lettuce works with Valkey by endpoint swap.

## Testcontainers

Java has first-class Testcontainers support for Valkey. Use `GenericContainer<>("valkey/valkey:9")` with exposed port 6379. Spring Data Valkey adds `@ServiceConnection` for auto-wired Testcontainers and `@DataValkeyTest` for slice testing.

## Decision Guide

| Scenario | Recommendation |
|----------|---------------|
| New project, simple key-value | valkey-java |
| New project, async/reactive | Lettuce or GLIDE Java |
| New Spring Boot project | Spring Data Valkey + valkey-java or GLIDE |
| Distributed locks/collections | Redisson |
| Hibernate/JCache caching | Redisson |
| Existing Jedis, minimal effort | Change endpoint only |
| Existing Jedis, long-term | valkey-java or GLIDE (Jedis compat) |
| AWS ElastiCache optimization | GLIDE Java (AZ-affinity) |
| Large Jedis codebase, zero rewrites | GLIDE Java Jedis compat layer |

## Cross-References

- `clients/landscape.md` - overall client decision framework
- **valkey-glide** skill - GLIDE Java API details, Jedis compat layer, AZ-affinity, batching
- `../tools/frameworks.md` - Spring Data Valkey framework integration details
- `modules/overview.md` - module system; GLIDE Java provides `Json` and `FT` classes for JSON and Search modules
- `modules/bloom.md` - Bloom filter module; Redisson also provides `RBloomFilter` as a client-side alternative
