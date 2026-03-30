# Client Library Landscape

Use when choosing a Valkey client library, understanding RESP compatibility with Redis clients, evaluating migration effort, or comparing native Valkey clients with Redis-maintained alternatives.

---

> Decision framework for choosing a Valkey client library across languages and use cases.

## Why Redis Clients Work with Valkey

Valkey maintains full RESP (REdis Serialization Protocol) compatibility with Redis OSS. Any client that speaks RESP2 or RESP3 can connect to a Valkey server by changing only the connection endpoint. This means the entire Redis client ecosystem - hundreds of libraries across dozens of languages - works with Valkey out of the box.

However, "compatible" and "native" are different levels of support:

- **Native Valkey clients** - track Valkey-specific features, use Valkey branding, and are maintained by or aligned with the Valkey project
- **Compatible Redis clients** - work via RESP protocol but may not expose Valkey-specific features (multi-DB clustering, hash field expiration) and have no guarantee of long-term compatibility as Redis and Valkey diverge

## Client Categories

### 1. Official Valkey Forks

Forked from established Redis clients by the Valkey community. These are drop-in replacements with API compatibility and Valkey-native awareness.

| Language | Client | Forked From |
|----------|--------|-------------|
| Python | valkey-py | redis-py |
| Node.js | iovalkey | ioredis |
| Java | valkey-java | Jedis |
| Go | valkey-go | (built from scratch) |
| Swift | valkey-swift | (new) |

valkey-go is notable - it is not a fork but a purpose-built client with auto-pipelining designed specifically for Valkey.

**iovalkey staleness concern**: iovalkey has had infrequent npm publishes and remains at v0.x versioning, suggesting it has not reached 1.0 stability. Teams wanting active Valkey Node.js development should evaluate GLIDE Node.js as an alternative.

### 2. Valkey GLIDE (Official Multi-Language Client)

GLIDE (General Language Independent Driver for the Enterprise) is the official Valkey client, written in Rust with language-specific bindings. It ships with production-learned defaults informed by years of operating Redis-compatible services at scale within AWS.

- **GA**: Python, Java, Node.js, Go, PHP, Ruby (`valkey-rb` gem)
- **Preview**: C#
- **In development**: C++ (separate repo: valkey-glide-cpp)
- **Key features**: AZ-affinity routing, auto-reconnect, connection pooling, cluster-aware, mTLS, OpenTelemetry
- **Java bonus**: Jedis compatibility layer for zero-code migration; Java 8 backward compatibility
- **C# bonus**: API designed for StackExchange.Redis compatibility

The GLIDE project is splitting language-specific clients into separate repos (valkey-glide-ruby, valkey-glide-cpp, valkey-glide-php, valkey-glide-csharp) while the core monorepo continues to host Python, Java, Node.js, and Go.

> See the **valkey-glide** skill for GLIDE implementation details, API reference, and usage patterns.

### 3. Redis-Maintained (Compatible)

These clients are maintained by Redis Ltd. or the broader Redis community. They work with Valkey today but have no commitment to Valkey-specific features. As the projects diverge (Redis 8+ vs Valkey 9+), compatibility gaps may emerge.

| Language | Client | Notes |
|----------|--------|-------|
| Python | redis-py | Endpoint swap only |
| Node.js | node-redis | Endpoint swap only |
| Node.js | ioredis | Community-maintained, endpoint swap; lacks AZ-affinity routing |
| Java | Jedis | AWS recommends for ElastiCache |
| Java | Lettuce | 7.4.0; async/reactive, recommended for ElastiCache |
| Go | go-redis | Endpoint swap |
| Rust | redis-rs | Explicitly supports Valkey in docs |
| .NET | StackExchange.Redis | Added Valkey detection via `GetProductVariant` |

### 4. Community Clients with Native Valkey Support

| Language | Client | Version | Notes |
|----------|--------|---------|-------|
| Java | Redisson | 4.3.0 | 50+ distributed objects; Spring/Hibernate/Quarkus; multi-DB cluster support |
| Scala | valkey4cats | - | Built on GLIDE + Cats Effect + Fs2 |
| PHP | phpredis | 6.3.0 | C extension, recommended for Valkey |
| PHP | Predis | 3.4.2 | Pure PHP; explicit "Redis/Valkey client" branding; VRANGE support |
| C | hiredis-cluster | 0.14.0 | Maintained by Ericsson/Nordix |
| TypeScript | thin-redis | - | Lightweight client for Node.js and Cloudflare Workers |

## Decision Framework: Which Client for My Language?

### Quick Decision Table

| Language | First Choice | When to Use Alternative |
|----------|-------------|----------------------|
| Python | valkey-py | GLIDE for AZ-affinity, managed service optimization |
| Node.js | iovalkey or GLIDE | GLIDE preferred for active development; ioredis if migration cost too high |
| Java | valkey-java | GLIDE for Jedis compat layer; Redisson for distributed objects |
| Go | valkey-go | GLIDE Go (GA) for managed service optimization |
| Rust | redis-rs | Only viable option; works well |
| .NET/C# | StackExchange.Redis | GLIDE C# (preview) for Valkey-native features |
| PHP | phpredis | Predis for pure PHP; GLIDE PHP (1.0 GA) for Valkey-native |
| Swift | valkey-swift | Only Valkey-native option |
| Scala | valkey4cats | Built on Lettuce for reactive |

### Decision Criteria

**Choose an official Valkey fork (valkey-py, iovalkey, valkey-java, valkey-go) when:**
- Starting a new project on Valkey
- You want Valkey-specific features (multi-DB clustering, hash field TTL)
- You need long-term maintenance alignment with the Valkey project
- Migration from the Redis equivalent is straightforward (usually a package swap)

**Choose GLIDE when:**
- Running on AWS ElastiCache or MemoryDB for Valkey (AZ-affinity reduces cross-AZ costs)
- You want production-learned connection management and AZ-affinity routing
- You want a single client API pattern across multiple languages
- Your Java project uses Jedis and you want zero-code migration via the Jedis compat layer

**Stay with a Redis client (endpoint swap only) when:**
- Migration budget is zero and current setup works
- You need a feature or ecosystem integration only available in the Redis client
- Your language has no Valkey-native option (Rust with redis-rs)
- You are using a framework that bundles a specific Redis client (Rails with redis-rb)

**Choose Redisson when:**
- You need distributed Java data structures (locks, maps, queues, semaphores)
- Your stack includes Spring, Hibernate, JCache, Quarkus, or Micronaut
- You want higher-level abstractions over raw key-value operations

## Migration Effort by Language

| From | To | Effort | What Changes |
|------|----|--------|-------------|
| redis-py | valkey-py | Minimal | Import path; `Redis` alias still available |
| ioredis | iovalkey | Minimal | npm package swap; API-compatible |
| Jedis | valkey-java | Minimal | Drop-in replacement |
| Jedis | GLIDE Java | Zero | Jedis compatibility layer |
| go-redis | valkey-go | Moderate | API differences; migration guide available |
| SE.Redis | GLIDE C# | Minimal | API designed for SE.Redis compatibility |
| Any Redis client | Same client | Zero | Change connection endpoint only |

## RESP Protocol Compatibility Notes

Valkey and Redis both implement RESP2 and RESP3. Key compatibility facts:

- Commands added by Redis after 7.2 are not guaranteed to exist in Valkey (and vice versa)
- Valkey 9.0 introduced features like hash field expiration and multi-DB clustering that have no Redis equivalent - only native Valkey clients expose these
- Redis 8.0 bundled formerly-separate modules (JSON, Search, TimeSeries) into core - Valkey keeps these as separate modules with different command availability
- The `INFO` command output differs between Valkey and Redis (server identification fields)
- StackExchange.Redis added `GetProductVariant` specifically to detect whether the server is Valkey or Redis

### Growing Divergence Risks

As Valkey and Redis diverge, Redis clients face specific gaps:
- **AZ-affinity routing** - critical for cloud deployments; available in valkey-go, iovalkey, and GLIDE but missing from ioredis and go-redis
- **Valkey-only commands** - `SETIFEQ`, `DELIFEQ`, hash field expiration commands are not implemented in Redis clients
- **Multi-DB clustering** - Valkey 9 supports multiple databases in cluster mode; Redisson 4.0+ added a `database` setting for this, but most Redis clients assume single-DB clusters
- **Client-side caching divergence** - as Valkey's tracking/invalidation protocol evolves, Redis client implementations may break

## Version Reference

Versions listed here are from late 2025 / early 2026 and will change. Always check the relevant package registry (PyPI, npm, Maven Central, crates.io) for current versions.

| Client | Version (as of writing) | Package |
|--------|------------------------|---------|
| valkey-py | 6.1.1 | `pip install valkey` |
| iovalkey | 0.3.3 | `npm install iovalkey` |
| valkey-java | 5.5.0 | Maven: `io.valkey:valkey-java` |
| valkey-go | 1.0.73 | `go get github.com/valkey-io/valkey-go` |
| valkey-swift | 1.1.0 | Swift Package Manager |
| Valkey GLIDE | 2.3.0 | Language-specific packages |
| Redisson | 4.3.0 | Maven: `org.redisson:redisson` |
| phpredis | 6.3.0 | PECL |
| Predis | 3.4.2 | `composer require predis/predis` |
| Lettuce | 7.4.0 | Maven: `io.lettuce:lettuce-core` |
| StackExchange.Redis | 2.12.8 | NuGet: `StackExchange.Redis` |

## Download Metrics

Adoption snapshot showing Valkey-native client traction relative to Redis equivalents:

| Ecosystem | Valkey-Native | Redis Equivalent | Notes |
|-----------|--------------|-----------------|-------|
| Python | valkey-py, valkey-glide | redis-py | Check PyPI for current download stats |
| Node.js | iovalkey, @valkey/valkey-glide | ioredis | Check npm for current download stats |

Valkey-native client adoption is early but growing. Check package registries for current download metrics.

## Cross-References

- **valkey-glide** skill - GLIDE API details, connection management, AZ-affinity, batching, PubSub, migration patterns
- `clients/python.md` - valkey-py deep dive, redis-py migration
- `clients/nodejs.md` - iovalkey deep dive, ioredis migration
- `clients/java.md` - valkey-java, Redisson, Spring Data Valkey
- `clients/other-languages.md` - Go, Rust, .NET, PHP, Swift, Scala, C
- `../tools/frameworks.md` - framework integrations including glide-mq (Valkey-native message queue for Node.js)
- **glide-mq** skill - greenfield queue development with Valkey-native FCALL operations
- `modules/overview.md` - module system overview; GLIDE provides dedicated APIs for JSON and Search modules
- `modules/gaps.md` - feature gaps between Valkey modules and Redis Stack/Redis 8
