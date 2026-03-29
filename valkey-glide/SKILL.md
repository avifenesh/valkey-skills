---
name: valkey-glide
description: "Use when building applications with Valkey GLIDE - the official multi-language client. Covers Python, Java, Node.js, Go, PHP, C# APIs, cluster mode, batching, PubSub, Lua scripting, OpenTelemetry, AZ affinity, TLS, compression, migration from redis-py/ioredis/Jedis/go-redis/Lettuce, and production tuning."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey GLIDE Client Reference

26 source-verified reference docs for the official Valkey GLIDE multi-language client. Per-language client API details live in the dedicated per-language skills (valkey-glide-python, valkey-glide-java, etc.). All API names, defaults, and config fields verified against actual glide-core Rust source and language wrapper code.

Browse by topic below. Each link leads to a focused reference with code examples, configuration tables, and verified API details.

## Routing

- Python/Java/Node/Go/PHP/C# setup -> Per-language skills (see Language Clients)
- Cluster vs standalone -> Per-language skills, Architecture (Cluster Topology)
- Connection pooling/timeouts/reconnection -> Architecture (Connection Model)
- Pipelines/transactions/batching -> Features (Batching)
- Pub/Sub patterns/sharded subscriptions -> Features (PubSub)
- Streams/consumer groups/XREAD -> Features (Streams)
- Lua scripts/Functions/EVAL/FCALL -> Features (Scripting)
- Observability/tracing/metrics -> Features (OpenTelemetry)
- AZ-aware reads/cross-zone latency -> Features (AZ Affinity)
- TLS/auth/mTLS/IAM -> Features (TLS and Auth)
- Compression/Zstd/LZ4 -> Features (Compression)
- JSON module/Search/Vector -> Features (Server Modules)
- Geospatial/GEOADD/GEOSEARCH -> Features (Geospatial)
- Bitmaps/HyperLogLog/BITFIELD -> Features (Bitmaps and HyperLogLog)
- Hash field TTL/HSETEX/HEXPIRE -> Features (Hash Field Expiration)
- Log levels/debugging/GLIDE_LOG_DIR -> Features (Logging)
- Switching from redis-py/ioredis/Jedis/go-redis/Lettuce/StackExchange -> Migration
- Error handling/retries/reconnection -> Best Practices (Error Handling)
- Performance tuning/benchmarks -> Best Practices (Performance)
- Production deployment/timeouts/defaults -> Best Practices (Production)
- Spring Boot/Spring Data Valkey -> Best Practices (Spring)
- How GLIDE works internally/Rust core/FFI -> Architecture


## Architecture

| Topic | Reference |
|-------|-----------|
| Three-layer design: Rust core, Protobuf IPC, language FFI bridges | [overview](reference/architecture/overview.md) |
| Multiplexed connections, inflight limits, request timeout, reconnect logic | [connection-model](reference/architecture/connection-model.md) |
| Cluster slot routing, MOVED/ASK handling, multi-slot splitting, ReadFrom | [cluster-topology](reference/architecture/cluster-topology.md) |


## Language Clients

For language-specific API details, code examples, and migration guides, use the dedicated per-language skills:

| Language | Skill | Key Content |
|----------|-------|-------------|
| Python | **valkey-glide-python** | Async/sync API, GlideClient, migration from redis-py |
| Java | **valkey-glide-java** | CompletableFuture, builders, Jedis/Lettuce migration, Spring |
| Node.js | **valkey-glide-nodejs** | Promise API, TypeScript, ioredis migration |
| Go | **valkey-glide-go** | Synchronous API, CGO, Result[T], go-redis migration |
| PHP | **valkey-glide-php** | C extension, PIE/Composer/PECL install |
| C# | **valkey-glide-csharp** | Async/await, .NET 8.0+, StackExchange.Redis migration |
| Ruby | **valkey-glide-ruby** | In development |

Per-language API details (configuration, data types, streams, OTel, TLS, PubSub, migration, gotchas) live in the per-language skills listed above. Use those skills directly for language-specific questions.


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


## Migration

For migration guides, use the per-language skills above or the detailed reference files:

| Topic | Reference |
|-------|-----------|
| From redis-py (Python) | [from-redis-py](reference/migration/from-redis-py.md) or **valkey-glide-python** |
| From ioredis (Node.js) | [from-ioredis](reference/migration/from-ioredis.md) or **valkey-glide-nodejs** |
| From Jedis (Java) | [from-jedis](reference/migration/from-jedis.md) or **valkey-glide-java** |
| From go-redis (Go) | [from-go-redis](reference/migration/from-go-redis.md) or **valkey-glide-go** |
| From Lettuce (Java) | [from-lettuce](reference/migration/from-lettuce.md) or **valkey-glide-java** |
| From StackExchange.Redis (C#) | [from-stackexchange](reference/migration/from-stackexchange.md) or **valkey-glide-csharp** |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Performance: benchmarks, GLIDE vs native clients, batching throughput | [performance](reference/best-practices/performance.md) |
| Error handling: exception types, reconnection, retry, batch errors | [error-handling](reference/best-practices/error-handling.md) |
| Production: timeout config, connection management, cloud defaults | [production](reference/best-practices/production.md) |
| Spring: Spring Data Valkey, Boot auto-config, Actuator health, drivers | [spring-integration](reference/best-practices/spring-integration.md) |
