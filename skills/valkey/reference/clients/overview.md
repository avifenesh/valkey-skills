# Client Libraries Overview

Use when choosing a Valkey client library for your application, migrating from a Redis client, or evaluating Valkey GLIDE versus existing clients.

---

## Valkey GLIDE (Official Client)

GLIDE (General Language Independent Driver for the Enterprise) is the official Valkey client. Built in Rust with language bindings, it uses a single multiplexed connection per cluster node with auto-pipelining.

### Language Support

| Language | Package | Status |
|----------|---------|--------|
| Python | `pip install valkey-glide` | GA |
| Node.js | `npm install @valkey/valkey-glide` | GA |
| Java | `io.valkey:valkey-glide` (Maven) | GA |
| Go | `go get github.com/valkey-io/valkey-glide/go/v2` | GA |
| PHP | `valkey-io/valkey-glide-php` (Composer) | GA |
| C# | `Valkey.Glide` (NuGet) | Preview |
| Ruby | `valkey-rb` (RubyGems) | GA |

### Key Advantages

- **AZ Affinity routing**: Route reads to the closest availability zone replica - reduces latency by ~500us and cross-AZ transfer costs by up to 75%. GLIDE-only feature, not available in any other client.
- **IAM authentication**: Native token-based auth for AWS ElastiCache/MemoryDB without managing passwords. GLIDE-only.
- **Built-in OpenTelemetry**: Per-command tracing spans and metrics without wrapping calls. GLIDE-only.
- **Auto-pipelining**: Commands are automatically batched, reducing round-trips without explicit pipeline management
- **Single connection per node**: Multiplexed design eliminates connection pool sizing decisions
- **Rust core**: One implementation shared across all languages, reducing per-language bugs
- **First-class Valkey support**: Immediate support for new Valkey commands ([SET IFEQ, DELIFEQ](../valkey-features/conditional-ops.md), [hash field TTL](../valkey-features/hash-field-ttl.md))
- **Cluster-aware**: Automatic topology discovery, redirect handling, and reconnection
- **Dynamic PubSub**: Runtime subscribe/unsubscribe (GLIDE 2.3+), with automatic resubscription on reconnect
- **Transparent compression**: Zstd/LZ4 compression for large values on SET/GET

> See the **valkey-glide** skill for detailed API reference, configuration, and migration guides per language.

### Installation

```bash
# Node.js
npm install @valkey/valkey-glide

# Python
pip install valkey-glide

# Java (Maven)
# Add to pom.xml:
# <dependency>
#   <groupId>io.valkey</groupId>
#   <artifactId>valkey-glide</artifactId>
# </dependency>

# Go
go get github.com/valkey-io/valkey-glide/go
```

---

## Existing Redis Clients (Compatible)

All major Redis clients work with Valkey out of the box. No code changes required for basic operations.

### Node.js

| Client | Notes |
|--------|-------|
| **ioredis** | Most popular. Full cluster support, Lua scripting, pipelining. Works unchanged with Valkey. |
| **node-redis** | Official Redis client. Works unchanged with Valkey. |

### Python

| Client | Notes |
|--------|-------|
| **redis-py** | Standard Redis client. Works unchanged with Valkey. |
| **valkey-py** | Fork of redis-py with Valkey-specific features (SET IFEQ, DELIFEQ, hash field TTL). |

### Java

| Client | Notes |
|--------|-------|
| **Jedis** | Synchronous, simple API. Works unchanged with Valkey. |
| **Lettuce** | Async/reactive, Netty-based. Works unchanged with Valkey. |
| **Redisson** | Higher-level abstractions (distributed locks, queues). Works unchanged. |

### Go

| Client | Notes |
|--------|-------|
| **go-redis** | Most popular Go client. Works unchanged with Valkey. |
| **rueidis** | High-performance, auto-pipelining. Works unchanged with Valkey. |

### .NET

| Client | Notes |
|--------|-------|
| **StackExchange.Redis** | Standard .NET client. Works unchanged with Valkey. |

---

## Valkey-Native Client Libraries

Beyond GLIDE, several language-specific clients are maintained as first-party Valkey projects:

| Language | Client | License | Notes |
|----------|--------|---------|-------|
| Python | valkey-py | MIT | Fork of redis-py |
| Node.js | iovalkey | MIT | Fork of ioredis |
| Java | valkey-java | MIT | Fork of jedis |
| Java | redisson | Apache-2.0 | 50+ Java objects/services |
| Go | valkey-go | Apache-2.0 | Auto-pipelining, client-side caching |
| PHP | phpredis | PHP-3.01 | C extension |
| PHP | predis | MIT | Pure PHP |
| Swift | valkey-swift | Apache-2.0 | First-party Swift client |

### Advanced Feature Comparison

| Feature | GLIDE | valkey-py | iovalkey | valkey-java | redisson | valkey-go | phpredis |
|---------|-------|-----------|----------|-------------|----------|-----------|----------|
| Read from Replica | Yes | Yes | Yes | No | Yes | Yes | Yes |
| PubSub State Restoration | Yes | No | No | No | Yes | Yes | No |
| Cluster Scan | Yes | No | No | No | Yes | No | No |
| AZ-Based Read from Replica | Yes | No | No | No | No | Yes | No |
| Client-Side Caching | No | No | No | No | Yes | Yes | No |
| Persistent Connection Pool | No | Yes | Yes | Yes | Yes | Yes | Yes |
| Smart Backoff (Storm Prevention) | Yes | Yes | Yes | Yes | Yes | Yes | Yes |

**When to use GLIDE over traditional clients**: GLIDE is the only client with AZ Affinity routing (cloud cost optimization), IAM authentication (AWS managed services), and built-in OpenTelemetry. It also has the broadest cluster feature support (cluster scan, PubSub restoration). Use traditional clients when you need client-side caching (valkey-go, redisson) or persistent connection pools.

---

## When to Choose GLIDE vs Existing Clients

### Choose GLIDE when:

- You deploy on **AWS ElastiCache/MemoryDB** and want AZ Affinity (cross-AZ cost savings up to 75%) and IAM authentication - these are GLIDE-only features
- You need **built-in observability** - OpenTelemetry tracing and metrics without additional instrumentation
- Starting a **new project** with no existing Redis client dependency
- You need **first-class support for Valkey-specific features** (SET IFEQ, DELIFEQ, hash field TTL commands)
- You want **auto-pipelining without managing pipelines** explicitly
- You want to **avoid connection pool sizing** decisions (GLIDE handles this internally)
- You are building a **multi-language service** and want consistent client behavior

### Keep your existing client when:

- Your application already uses ioredis, Jedis, redis-py, or similar - **it works, no migration needed**
- You rely on client-specific features (ioredis plugins, Redisson distributed objects, Lettuce reactive streams)
- Your team has deep expertise with the current client
- GLIDE does not yet support your language (or is in Preview status)

### Consider valkey-py (Python) when:

- You are on Python and want Valkey-specific commands without switching to GLIDE
- You want a drop-in replacement for redis-py with extra features

---

## Connection Patterns

### GLIDE: Multiplexed

GLIDE uses a single multiplexed connection per cluster node. Commands from multiple goroutines/threads/coroutines share the same connection. Auto-pipelining batches commands automatically.

No pool configuration needed.

### Traditional clients: Connection pool

Traditional clients use one connection per concurrent operation. You need to configure a pool:

- **Pool size**: Start with `(CPU cores * 2)` connections
- **Idle timeout**: Set to reclaim unused connections
- **Separate pools for pub/sub**: Subscriber connections are monopolized and cannot serve other commands (see [Pub/Sub Commands](../commands/pubsub.md))

```javascript
// ioredis example
const Redis = require('ioredis');
const cluster = new Redis.Cluster([
  { host: 'node1', port: 6379 },
  { host: 'node2', port: 6379 },
], {
  redisOptions: {
    password: 'your_password',
  },
  scaleReads: 'slave',      // Read from replicas
  natMap: {},                // NAT mapping if needed
});
```

```python
# redis-py example
import redis
pool = redis.ConnectionPool(
    host='localhost',
    port=6379,
    max_connections=20,
    decode_responses=True,
)
r = redis.Redis(connection_pool=pool)
```

---

## Valkey-Specific Command Support

Not all existing Redis clients support Valkey-specific commands immediately. Here is the current state:

| Command | GLIDE | valkey-py | ioredis | Jedis | go-redis |
|---------|-------|-----------|---------|-------|----------|
| SET IFEQ (8.1+) | Yes | Yes | Via raw command | Via raw command | Via raw command |
| DELIFEQ (9.0+) | Yes | Yes | Via raw command | Via raw command | Via raw command |
| HSETEX (9.0+) | Yes | Yes | Via raw command | Via raw command | Via raw command |
| HEXPIRE (9.0+) | Yes | Yes | Via raw command | Via raw command | Via raw command |
| HGETEX (9.0+) | Yes | Yes | Via raw command | Via raw command | Via raw command |

"Via raw command" means you can still use the command by sending it as a raw/custom command, but the client does not have a typed API for it.

---

## TLS Connections

All clients support TLS. Example configurations:

```javascript
// ioredis with TLS
const Redis = require('ioredis');
const client = new Redis({
  host: 'valkey.example.com',
  port: 6380,
  tls: {
    ca: fs.readFileSync('ca.crt'),
    cert: fs.readFileSync('client.crt'),    // For mTLS
    key: fs.readFileSync('client.key'),     // For mTLS
  },
});
```

```python
# redis-py with TLS
import redis
r = redis.Redis(
    host='valkey.example.com',
    port=6380,
    ssl=True,
    ssl_ca_certs='ca.crt',
    ssl_certfile='client.crt',    # For mTLS
    ssl_keyfile='client.key',     # For mTLS
)
```

Valkey 8.1+ offloads TLS handshakes to I/O threads, minimizing TLS overhead on multi-threaded deployments.

---

## See Also

**Best Practices**:
- [Performance Best Practices](../best-practices/performance.md) - connection pooling and pipelining guidance
- [Cluster Best Practices](../best-practices/cluster.md) - cluster-aware client behavior, redirects, and replica reads
- [High Availability Best Practices](../best-practices/high-availability.md) - Sentinel-aware client configuration and retry strategies
- [Key Best Practices](../best-practices/keys.md) - CLUSTER KEYSLOT for verifying key design
- [Memory Best Practices](../best-practices/memory.md) - client-side caching to reduce server memory pressure
- [Persistence Best Practices](../best-practices/persistence.md) - reconnection behavior after server restart

**Patterns**:
- [Caching Patterns](../patterns/caching.md) - client-side caching with CLIENT TRACKING
- [Queue Patterns](../patterns/queues.md) - dedicated connections for blocking queue consumers
- [Pub/Sub Patterns](../patterns/pubsub-patterns.md) - dedicated subscriber connections and PubSub state restoration
- [Lock Patterns](../patterns/locks.md) - Redlock library implementations across languages
- [Session Patterns](../patterns/sessions.md) - connection patterns for session middleware

**Security**:
- [Security: Auth and ACL](../security/auth-and-acl.md) - authentication and TLS setup

**Valkey Features**:
- [Performance Summary](../valkey-features/performance-summary.md) - auto-pipelining and I/O threading benefits
- [Conditional Operations](../valkey-features/conditional-ops.md) - SET IFEQ, DELIFEQ command support
- [Hash Field TTL](../valkey-features/hash-field-ttl.md) - HSETEX, HEXPIRE, HGETEX command support
- [Compatibility and Migration](../overview/compatibility.md) - migration from Redis clients

**Anti-Patterns**:
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - one-connection-per-request, missing pipelining, and other client pitfalls
