---
name: migrate-lettuce
description: "Lettuce to Valkey GLIDE migration for Java. Covers Spring Data Valkey path, native rewrite from RedisFuture to CompletableFuture, PubSub, no reactive API or codec equivalent. Not for Jedis migration - use migrate-jedis instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from Lettuce to Valkey GLIDE (Java)

Use when migrating a Java application from Lettuce to the GLIDE client library.

## Routing

- String, hash, list, set, sorted set, delete, exists, cluster -> API Mapping
- Pipeline, transaction, Batch API, MULTI/EXEC -> Advanced Patterns
- PubSub, subscribe, publish, RedisPubSubAdapter -> Advanced Patterns
- Spring Data Valkey, Spring Boot, compatibility layer -> Advanced Patterns

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

## Quick Start - Connection Setup

**Lettuce:**
```java
RedisClient redisClient = RedisClient.create(
    RedisURI.builder().withHost("localhost").withPort(6379).withDatabase(0).build());
StatefulRedisConnection<String, String> connection = redisClient.connect();
RedisAsyncCommands<String, String> commands = connection.async();
```

**GLIDE:**
```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .databaseId(0).requestTimeout(5000).build();
GlideClient client = GlideClient.createClient(config).get();
```

GLIDE has fewer layers - no separate connection and commands objects. The client exposes commands directly.

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

## Incremental Migration Strategy

Three migration paths exist, from least effort to most control:

1. **Spring Data Valkey** (lowest effort): If using Spring, swap the driver to GLIDE in properties. No application code changes.
2. **Lettuce compatibility layer** (not yet available): When shipped, this will provide a drop-in wrapper.
3. **Native GLIDE migration** (full control): Introduce a service/DAO abstraction, implement it with GLIDE, migrate one service at a time, and remove Lettuce when complete.

For native migration, the key steps:
1. Add `valkey-glide` alongside Lettuce in your build
2. Replace `RedisFuture<T>` with `CompletableFuture<T>` at each call site
3. Remove `StatefulRedisConnection` / `RedisAsyncCommands` layers - GLIDE client exposes commands directly
4. Migrate services one at a time behind an interface
5. Remove Lettuce dependency once all services are migrated

## Reference

| Topic | File |
|-------|------|
| Command-by-command API mapping (strings, hashes, lists, sets, sorted sets, delete, exists, cluster) | [api-mapping](reference/api-mapping.md) |
| Transactions, pipelines, Pub/Sub, Spring Data Valkey alternative, compatibility layer status | [advanced-patterns](reference/advanced-patterns.md) |

## See Also

- **valkey-glide-java** skill - full GLIDE Java API details
- Batching (see valkey-glide skill) - pipeline and transaction patterns
- AZ Affinity (see valkey-glide skill) - availability zone aware routing
- OpenTelemetry (see valkey-glide skill) - observability integration

## Gotchas

1. **No reactive API.** Lettuce offers Project Reactor support (Flux/Mono). GLIDE only provides CompletableFuture. Adapt with `Mono.fromFuture()`. Significant for Spring WebFlux - the reactive `ReactiveRedisTemplate` is only available with Lettuce in Spring Data Valkey.
2. **No codec system.** Lettuce RedisCodec has no equivalent. Handle serialization manually.
3. **Single-field hset.** Lettuce hset("hash", "field", "value") takes three string args. GLIDE always takes a Map.
4. **Array args for lists.** Multi-element commands like lpush, rpush, sadd take String[] arrays instead of varargs.
5. **No ClientResources.** Lettuce ClientResources for thread pool configuration has no equivalent. GLIDE Rust core manages its own threading.
6. **Simpler connection lifecycle.** No separate StatefulConnection and Commands objects.
7. **Multi-arch native library distribution.** Use `osdetector-gradle-plugin` or `os-maven-plugin`. Uber JAR available from GLIDE 2.3.
8. **No Sentinel support.** Use cluster mode or direct connection instead.
