---
name: migrate-lettuce
description: "Use when migrating Java from Lettuce to Valkey GLIDE. Covers Spring Data Valkey path, native rewrite from RedisFuture to CompletableFuture, REVERSED publish() args, no reactive API, no codec, no Sentinel. Not for Jedis migration - use migrate-jedis."
version: 1.1.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from Lettuce to Valkey GLIDE (Java)

Use when migrating a Java application from Lettuce to the GLIDE client library.

## Routing

| Question | Reference |
|----------|-----------|
| String, hash, list, set, sorted set, delete, exists, cluster | [api-mapping](reference/api-mapping.md) |
| Pipeline, transaction, Batch API, MULTI/EXEC | [advanced-patterns](reference/advanced-patterns.md) |
| PubSub, subscribe, publish, RedisPubSubAdapter | [advanced-patterns](reference/advanced-patterns.md) |
| Spring Data Valkey, Spring Boot, compatibility layer | [advanced-patterns](reference/advanced-patterns.md) |

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

Both Lettuce and GLIDE use async, multiplexed connections - structurally smoother migration than from Jedis or redis-py.

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

No separate connection and commands objects - the client exposes commands directly.

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

## Gotchas (the short list)

1. **`publish()` argument order is REVERSED.** Lettuce is `redis.async().publish(channel, message)`; GLIDE Java is `client.publish(message, channel).get()`. **Silent bug factory during migration.** Verified in `java/client/.../commands/PubSubBaseCommands.java`.
2. **No reactive API.** Lettuce offers Project Reactor (`Flux` / `Mono`). GLIDE only provides `CompletableFuture`. Adapt with `Mono.fromFuture(client.get(key))`. Significant for Spring WebFlux - the reactive `ReactiveRedisTemplate` / `ReactiveValueOperations` is only available via Lettuce in Spring Data Valkey today.
3. **No codec system.** Lettuce `RedisCodec<K, V>` has no equivalent. Handle serialization manually or use `GlideString` for binary-safe bytes.
4. **`hset("hash", "field", "value")` variadic form** in Lettuce takes 3 strings; GLIDE takes a `Map<String, String>` or an array of `String[]` pairs via overloads. Always check signature.
5. **Array args for multi-element commands** - `lpush`, `rpush`, `sadd`, `srem`, `del`, `exists` take `String[]` arrays instead of varargs.
6. **No `ClientResources` / thread-pool configuration.** GLIDE Rust core manages its own threading.
7. **Simpler connection lifecycle** - no separate `StatefulConnection` + `Commands` layers. Call commands directly on the client.
8. **Multi-arch native library distribution.** Use `osdetector-gradle-plugin` or `os-maven-plugin`. **Uber JAR (GLIDE 2.3+)** bundles all platform natives - preferred for cross-platform projects.
9. **Error hierarchy is FLAT under `GlideException`.** Lettuce's `RedisException` -> `RedisCommandExecutionException` / `RedisCommandTimeoutException` / `RedisConnectionException` subclass tree maps to GLIDE's 6 siblings: `ClosingException`, `ConnectionException`, `ConfigurationError` (note "Error" suffix), `ExecAbortException`, `RequestException`, `TimeoutException`. All come inside `ExecutionException` when unwrapping `.get()`.
10. **GLIDE `TimeoutException` vs `java.util.concurrent.TimeoutException`** - two different classes with the same simple name; the former is the internal request timeout, the latter is what `.get(n, TimeUnit)` throws when the future doesn't resolve in time. Fully-qualify or alias.
11. **No Sentinel support** in GLIDE. Migrate Sentinel users to cluster mode or direct primary/replica connection.
12. **Reconnection is infinite.** No `maxRedirects` / reconnect-cap equivalent - `BackoffStrategy.numOfRetries` caps backoff sequence length only.
13. **No Alpine / MUSL support** - glibc 2.17+ required.
