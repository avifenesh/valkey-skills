---
name: valkey-glide
description: "Router for Valkey GLIDE per-language skills. Use when you need to find the right language-specific GLIDE skill or migration skill. Not for GLIDE library internals or contributing to GLIDE source code - use glide-dev instead."
version: 1.1.0
argument-hint: "[language or migration target]"
---

# Valkey GLIDE - Skill Router

Parent router for the official Valkey GLIDE multi-language client skills. Each per-language skill is fully self-contained - it includes its own connection setup, data types, batching, PubSub, streams, OTel, TLS, error handling, performance tuning, and production best practices. No shared reference files exist at this level.

## Routing

- Python setup, async/sync API, redis-py migration -> **valkey-glide-python**
- Java setup, CompletableFuture API, Spring -> **valkey-glide-java**
- Node.js setup, Promise/TypeScript API -> **valkey-glide-nodejs**
- Go setup, CGO, Result[T] API -> **valkey-glide-go**
- PHP setup, C extension, PIE/Composer -> **valkey-glide-php**
- C# setup, async/await, .NET 8.0+ -> **valkey-glide-csharp**
- Ruby setup, valkey-rb gem -> **valkey-glide-ruby**
- Switching from redis-py -> **migrate-redis-py**
- Switching from ioredis -> **migrate-ioredis**
- Switching from Jedis -> **migrate-jedis**
- Switching from Lettuce -> **migrate-lettuce**
- Switching from go-redis -> **migrate-go-redis**
- Switching from StackExchange.Redis -> **migrate-stackexchange**
- Spring Boot / Spring Data Valkey -> **spring-data-valkey**
- Building queues, job scheduling, workers, BullMQ/Bee-Queue migration -> **glide-mq**
- How GLIDE works internally (Rust core, FFI, Protobuf) -> **glide-dev** (contributor skill)
- Contributing to GLIDE, adding commands, build system -> **glide-dev**
- Cluster vs standalone, slot routing, ReadFrom -> any per-language skill covers connection/cluster


## Language Skills

| Language | Skill | Key Content |
|----------|-------|-------------|
| Python | **valkey-glide-python** | Async/sync API, GlideClient, batching, PubSub, streams, OTel, TLS, error handling, production |
| Java | **valkey-glide-java** | CompletableFuture API, builders, batching, PubSub, streams, server modules, Spring |
| Node.js | **valkey-glide-nodejs** | Promise API, TypeScript, ESM/CJS, batching, PubSub, streams, advanced features |
| Go | **valkey-glide-go** | Synchronous API, CGO, Result[T], batching, PubSub, streams, advanced features |
| PHP | **valkey-glide-php** | C extension (PHP 8.1+), PIE/Composer/PECL, PubSub |
| C# | **valkey-glide-csharp** | Async/await, .NET 8.0+ (preview), PubSub |
| Ruby | **valkey-glide-ruby** | GA (`valkey-rb` gem), redis-rb drop-in replacement, PubSub |

Each skill includes connection setup, configuration, data types, features, best practices, and error handling - all language-specific with verified code examples.


## Migration Skills

| Source Library | Migration Skill |
|----------------|----------------|
| redis-py (Python) | **migrate-redis-py** |
| ioredis (Node.js) | **migrate-ioredis** |
| Jedis (Java) | **migrate-jedis** |
| Lettuce (Java) | **migrate-lettuce** |
| go-redis (Go) | **migrate-go-redis** |
| StackExchange.Redis (C#) | **migrate-stackexchange** |
| Spring Data Redis (Java) | **spring-data-valkey** |
