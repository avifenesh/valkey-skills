---
name: valkey-glide
description: "Use when building applications with Valkey GLIDE - the official multi-language client. Covers Python, Java, Node.js, Go, PHP, C# APIs, cluster mode, batching, PubSub, Lua scripting, OpenTelemetry, AZ affinity, TLS, compression, migration from redis-py/ioredis/Jedis/go-redis/Lettuce, and production tuning."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey GLIDE Client Reference

32 source-verified reference docs for the official Valkey GLIDE multi-language client. All API names, defaults, and config fields verified against actual glide-core Rust source and language wrapper code.

Browse by topic below. Each link leads to a focused reference with code examples, configuration tables, and verified API details.

## Routing

- Python/Java/Node/Go/PHP/C# setup -> Clients
- Cluster vs standalone -> Clients, Architecture (Cluster Topology)
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

| Topic | Reference |
|-------|-----------|
| Python: GlideClient, GlideClusterClient, async/sync, asyncio config | [python](reference/clients/python.md) |
| Java: GlideClient, GlideClusterClient, CompletableFuture, JNI bridge | [java](reference/clients/java.md) |
| Node.js: GlideClient, GlideClusterClient, Promise API, TypeScript, napi-rs | [nodejs](reference/clients/nodejs.md) |
| Go: GlideClient, GlideClusterClient, synchronous API, CGO, Result[T] | [go](reference/clients/go.md) |
| PHP: GlideClient, GlideClusterClient, synchronous, FFI extension | [php](reference/clients/php.md) |
| C#: GlideClient, GlideClusterClient, async/await, .NET 8.0+ | [csharp](reference/clients/csharp.md) |


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

| Topic | Reference |
|-------|-----------|
| From redis-py: Python migration, async-first, bytes handling, ExpirySet | [from-redis-py](reference/migration/from-redis-py.md) |
| From ioredis: Node.js migration, object returns, Batch API differences | [from-ioredis](reference/migration/from-ioredis.md) |
| From Jedis: Java migration, CompletableFuture, builder config, compat | [from-jedis](reference/migration/from-jedis.md) |
| From go-redis: Go migration, Result[T] types, CGO requirement | [from-go-redis](reference/migration/from-go-redis.md) |
| From Lettuce: Java migration, reactive to async, Spring Data Valkey | [from-lettuce](reference/migration/from-lettuce.md) |
| From StackExchange.Redis: C# migration, async/await, .NET preview | [from-stackexchange](reference/migration/from-stackexchange.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Performance: benchmarks, GLIDE vs native clients, batching throughput | [performance](reference/best-practices/performance.md) |
| Error handling: exception types, reconnection, retry, batch errors | [error-handling](reference/best-practices/error-handling.md) |
| Production: timeout config, connection management, cloud defaults | [production](reference/best-practices/production.md) |
| Spring: Spring Data Valkey, Boot auto-config, Actuator health, drivers | [spring-integration](reference/best-practices/spring-integration.md) |
