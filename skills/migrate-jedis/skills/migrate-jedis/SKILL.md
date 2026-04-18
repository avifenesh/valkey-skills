---
name: migrate-jedis
description: "Use when migrating Java from Jedis to Valkey GLIDE. Covers zero-code-change compat layer (2.1+), native CompletableFuture rewrite, REVERSED publish() args, Batch API replaces Transaction/Pipeline, no Sentinel, FLAT error hierarchy. Not for greenfield Java - use valkey-glide-java."
version: 1.1.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from Jedis to Valkey GLIDE (Java)

Use when migrating a Java application from Jedis to the GLIDE client library.

## Routing

- String, hash, list, set, sorted set, delete, exists, cluster, error handling -> API Mapping
- Pipeline, transaction, Batch API, MULTI/EXEC -> Advanced Patterns
- PubSub, subscribe, publish, JedisPubSub -> Advanced Patterns
- Spring Data Valkey, Spring Boot -> Advanced Patterns

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

## Migration Paths

### Path 1: Jedis Compatibility Layer (Zero-Code-Change)

Drop-in wrapper implementing the Jedis API backed by GLIDE (GLIDE 2.1+). Add `io.valkey:valkey-glide-jedis-compatibility` and swap the classpath - existing `redis.clients.jedis.Jedis` code works without recompile.

**Supported (GLIDE 2.3)**: Core string/hash/list/set, streams, sorted sets, geospatial, scripting/functions, ACL, server management, transactions (WATCH/MULTI/EXEC - see gotchas). **Not yet supported**: PubSub (JedisPubSub callbacks, sharded PubSub), pipelining (use native Batch API), CommandArguments/IParams builder pattern.

### Path 2: Full Native Migration

Migrate directly to the GLIDE native API for full feature access. See the API Mapping and Advanced Patterns reference files.

## Quick Start - Connection Setup

**Jedis:**
```java
JedisPoolConfig poolConfig = new JedisPoolConfig();
poolConfig.setMaxTotal(10);
JedisPool pool = new JedisPool(poolConfig, "localhost", 6379);
try (Jedis jedis = pool.getResource()) { jedis.ping(); }
```

**GLIDE:**
```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .requestTimeout(5000)
    .build();
try (GlideClient client = GlideClient.createClient(config).get()) { client.ping().get(); }
```

No connection pool configuration needed - GLIDE uses a single multiplexed connection.

## Configuration Mapping

| Jedis parameter | GLIDE equivalent |
|-----------------|------------------|
| JedisPool(host, port) | NodeAddress.builder().host().port().build() |
| JedisPoolConfig.setMaxTotal() | Not needed - single multiplexed connection |
| password | ServerCredentials.builder().password().build() |
| database | databaseId() |
| ssl = true | useTLS(true) |
| timeout (ms) | requestTimeout() (ms) |

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

## Reference

| Topic | File |
|-------|------|
| Command-by-command API mapping (strings, hashes, lists, sets, sorted sets, delete, exists, cluster, errors) | [api-mapping](reference/api-mapping.md) |
| Transactions, pipelines, Pub/Sub, Spring Data Valkey alternative | [advanced-patterns](reference/advanced-patterns.md) |

## Gotchas (the short list)

1. **`publish()` argument order is REVERSED.** Jedis is `jedis.publish(channel, message)`; GLIDE Java is `client.publish(message, channel).get()`. **Silent bug factory during migration** - code compiles and runs but publishes to the wrong channel. Verified in `java/client/.../commands/PubSubBaseCommands.java:54`.
2. **Every command returns `CompletableFuture<T>`.** Call `.get(timeout, TimeUnit)` for synchronous behavior - never bare `.get()` (can block indefinitely on a bad connection).
3. **Array args, not varargs.** Multi-key commands take `String[]` arrays. `jedis.del("k1", "k2")` -> `client.del(new String[]{"k1", "k2"}).get()`.
4. **No connection pool management.** Drop `JedisPool` and `JedisPoolConfig` entirely. Multiplexer is the pool. Blocking commands (`blpop`, `brpop`, `blmove`, `bzpopmax`/`min`, `brpoplpush`, `blmpop`, `bzmpop`, `xread`/`xreadgroup` with block) and WATCH/MULTI/EXEC need a dedicated client.
5. **Builder pattern everywhere.** Lombok `@Builder` on config, set options, batch options. `GlideClientConfiguration.builder()...build()`.
6. **Batch replaces both Transaction and Pipeline.** `new Batch(true)` for atomic (replaces `jedis.multi()`), `new Batch(false)` for pipeline. Same class, `isAtomic` flag.
7. **Classifier required in Maven / Gradle.** Use `os-maven-plugin` (Maven) or `osdetector-gradle-plugin` (Gradle) to pick the right native library. **Uber JAR (GLIDE 2.3+)** bundles all platform natives - preferred for projects that ship cross-platform.
8. **Jedis compatibility layer has edge cases.** After calling `.multi()` on the compat-wrapped client, use the returned `Transaction` object (not the underlying client). `HashSet<byte[]>` operations degrade to O(n) because `byte[].hashCode()` uses identity hash - prefer `GlideString` or the native Batch API for byte-key workloads.
9. **No Sentinel support** in GLIDE. Migrate Sentinel users to cluster mode or direct primary/replica connection.
10. **Error hierarchy is FLAT under `GlideException`.** Jedis's `JedisException` tree maps to GLIDE's 6 siblings: `ClosingException`, `ConnectionException`, `ConfigurationError` (Error suffix, inconsistent), `ExecAbortException`, `RequestException`, `TimeoutException`. All inside `ExecutionException` when unwrapping `.get()`.
11. **GLIDE `TimeoutException` vs `java.util.concurrent.TimeoutException`** - two different classes with the same simple name. Fully-qualify or alias on import.
12. **Reconnection is infinite.** No `MaxRetries` equivalent; `BackoffStrategy.numOfRetries` caps backoff sequence length only. Commands fail with `ConnectionException` while reconnecting.
13. **No Alpine / MUSL support** - glibc 2.17+ required. Use Debian-based images.
