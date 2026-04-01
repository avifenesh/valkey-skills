---
name: migrate-jedis
description: "Jedis to Valkey GLIDE migration for Java. Covers zero-code-change compatibility layer, native CompletableFuture rewrite, PubSub, Batch API, cluster mode. Not for greenfield Java apps - use valkey-glide-java instead."
version: 1.0.0
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

No connection pool configuration needed. GLIDE uses a single multiplexed connection.

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

## See Also

- **valkey-glide-java** skill - full GLIDE Java API details
- Batching (see valkey-glide skill) - pipeline and transaction patterns
- TLS and authentication (see valkey-glide skill) - TLS setup and credential management
- Production deployment (see valkey-glide skill) - timeout tuning, connection management, observability

## Gotchas

1. **Every command returns CompletableFuture.** You must call .get() for synchronous behavior.
2. **Array args, not varargs.** Multi-key commands take String[] arrays, not varargs.
3. **No connection pool management.** Drop JedisPool and JedisPoolConfig entirely.
4. **Builder pattern everywhere.** Configuration, set options, and batch options all use the builder pattern.
5. **Batch replaces Transaction and Pipeline.** Use new Batch(true) for atomic and new Batch(false) for non-atomic.
6. **Classifier required in Maven/Gradle.** Use os-maven-plugin or osdetector-gradle-plugin. An uber JAR (GLIDE 2.3+) bundles all native libraries.
7. **Compatibility layer gotchas.** After calling `multi()`, you must use the returned `Transaction` object. `HashSet<byte[]>` operations degrade to O(n) because `byte[].hashCode()` returns identity hash.
8. **No Sentinel support.** GLIDE does not support Redis Sentinel - use cluster mode or direct connection.
