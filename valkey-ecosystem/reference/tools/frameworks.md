# Framework Integrations

Use when integrating Valkey into application frameworks - Spring, Django, Rails, queue systems, or ORM caching layers.

---

## Spring Data Valkey (Java)

Spring Data Valkey is the official first-class Valkey integration for the Spring ecosystem. It is a fork of Spring Data Redis, maintained by the Valkey project. It has reached GA and is production-ready.

- **Repo**: [valkey-io/spring-data-valkey](https://github.com/valkey-io/spring-data-valkey)

### Maven Coordinates

```xml
<!-- Core library -->
<dependency>
  <groupId>io.valkey.springframework.data</groupId>
  <artifactId>spring-data-valkey</artifactId>
  <version>1.0.0</version>
</dependency>

<!-- Spring Boot Starter (recommended) -->
<dependency>
  <groupId>io.valkey.springframework.boot</groupId>
  <artifactId>spring-boot-starter-data-valkey</artifactId>
  <version>1.0.0</version>
</dependency>
```

### Key Features

**ValkeyTemplate** - The primary API for data access, with pluggable serializers:

- StringValkeyTemplate for String-based operations
- Jackson, JDK, and custom serialization support
- Operations interfaces: ValueOperations, HashOperations, ListOperations, SetOperations, ZSetOperations, StreamOperations

**Pub/Sub** - MessageListenerContainer for subscribing to channels and patterns. Supports both imperative and reactive message handling.

**Reactive API** - Full reactive support via Project Reactor and the Lettuce driver. ReactiveValkeyTemplate mirrors the imperative API with Mono/Flux return types.

**Driver support** - Valkey GLIDE, Lettuce, and Jedis are all supported as
underlying drivers.

**OpenTelemetry** - Built-in instrumentation when using the GLIDE client as the underlying driver. The Spring Boot starter provides property-based OTel configuration.

**AWS IAM authentication** - Built-in support for ElastiCache and MemoryDB IAM auth.

**Spring Boot Actuator** - Health indicators and metrics exposed automatically when the starter is on the classpath.

**Repository support** - `@EnableValkeyRepositories` for Spring Data repository interfaces.

**Testing support** - `@DataValkeyTest` slice test annotation, `@ServiceConnection` for Testcontainers auto-wiring, and Docker Compose service detection. See [testing.md](testing.md) for details.

### Choosing Between Spring Data Valkey and Spring Data Redis

Spring Data Redis also works with Valkey - just point the connection at a Valkey server. Use Spring Data Valkey when you want:

- Native Valkey naming (ValkeyTemplate vs RedisTemplate)
- GLIDE client integration with AZ-affinity routing
- OpenTelemetry instrumentation out of the box
- Future Valkey-specific features as the projects diverge

For existing Spring Data Redis projects, migration is a package rename with API-compatible classes.

---

## Django (Python)

### django-valkey

Full-featured cache and session backend for Django, forked from django-redis with Valkey-native improvements. Part of the Django Commons organization (community-maintained Django packages).

- **Repo**: [django-commons/django-valkey](https://github.com/django-commons/django-valkey)
- **Version**: Check PyPI for latest
- **Install**: `pip install django-valkey`

Configuration:

```python
CACHES = {
    "default": {
        "BACKEND": "django_valkey.cache.ValkeyCache",
        "LOCATION": "valkey://127.0.0.1:6379",
    }
}
```

Features:

- ACL authentication support
- Cluster backend for multi-node deployments
- Compressor support: bz2, brotli, zstd (stdlib zstd since 0.4.0)
- msgspec serialization support (0.4.0)
- `IGNORE_EXCEPTIONS` setting for cache failure resilience
- Session backend for storing Django sessions in Valkey
- Connection pooling
- Django 6.0 support (0.4.0), Django 4.2 maintained; dropped Django 5.0/5.1 (EOL)

### django-redis Compatibility

django-redis also works with Valkey by changing only the server endpoint (using the `redis://` URL scheme). Switch to django-valkey when you want native `valkey://` URL scheme support and Valkey-specific improvements.

---

## Rails (Ruby)

### Sidekiq

Sidekiq 8.0+ officially supports Valkey 7.2+. The README
states: "Sidekiq supports Valkey and Dragonfly as Redis alternatives." CI runs
against Valkey. A proposal for a GLIDE adapter (pluggable datastore interface)
was rejected - Sidekiq stays coupled to redis-client, and Valkey works through
protocol compatibility.

### ActiveSupport Cache

Rails `ActiveSupport::Cache::RedisCacheStore` works with Valkey by changing only the connection endpoint. No code changes required.

### Session Store

The `redis-rails` gem works unchanged with Valkey for session storage.

### valkey-namespace

The [valkey-namespace](https://github.com/valkey-io/valkey-namespace) gem provides namespaced access to a subset of your Valkey keyspace. It automatically prefixes keys with a namespace string, allowing multiple logical namespaces within a single Valkey instance.

- **Repo**: [valkey-io/valkey-namespace](https://github.com/valkey-io/valkey-namespace)
- **Install**: `gem install valkey-namespace`
- **Requires**: `valkey-rb` gem

```ruby
require 'valkey-namespace'

valkey_connection = Valkey.new
namespaced = Valkey::Namespace.new(:myapp, valkey: valkey_connection)

namespaced.set('foo', 'bar')   # Actually sets 'myapp:foo'
namespaced.get('foo')           # Actually gets 'myapp:foo'
```

The namespace can be a static string or a `Proc` for dynamic namespacing - useful for multi-tenant Rails applications:

```ruby
namespaced = Valkey::Namespace.new(
  Proc.new { Tenant.current_tenant },
  valkey: valkey_connection
)
```

Key points:
- Automatically prepends namespace to keys on write and strips it on read
- Administrative commands (`FLUSHALL`, etc.) bypass namespacing - use `namespaced.valkey.flushall()` explicitly
- Blind passthrough of unknown commands is deprecated in v1.0.0 and will be removed in v2.0
- Compatible with Valkey and Redis 6.2, 7.0, 7.1, 7.2 via `valkey-rb`

This gem is particularly useful for Rails applications where multiple services or environments share a single Valkey instance - for example, separating Sidekiq queues, cache entries, and session data by namespace.

### Current Limitations

No dedicated `valkey-rails` gem exists yet. The Rails ecosystem relies on the redis gem's RESP compatibility with Valkey, supplemented by valkey-namespace for key isolation. This works today but long-term Valkey-specific features may require dedicated gems.

---

## Queue Frameworks

Queue frameworks are among the most common integrations for Valkey. They use Valkey as a job broker for background task processing.

| Framework | Language | Valkey Status | Migration Effort |
|-----------|----------|---------------|------------------|
| **glide-mq** | Node.js | **Valkey-native** | New or migrate from BullMQ/Bee-Queue |
| Sidekiq | Ruby | Official (v8.0+) | Config change only |
| BullMQ | Node.js | Compatible | Endpoint swap |
| Celery | Python | Partial | Endpoint swap, caveats |
| RQ | Python | Compatible | Endpoint swap |

### glide-mq (Node.js) - Valkey-Native

glide-mq is a message queue library built from the ground up for Valkey. Unlike BullMQ and other Redis-based queues that work with Valkey through RESP compatibility, glide-mq uses Valkey Functions (FCALL) for single-round-trip operations and native cluster support via hash-tagged keys.

- **Install**: `npm install glide-mq`
- **Requires**: Node.js 20+, Valkey 7.0+
- **Key features**: Per-key ordered processing, runtime group rate limiting, dead letter queues, gzip compression, in-memory testing mode, cron scheduling, workflow DAGs
- **Connection**: Uses `{ addresses: [{ host, port }] }` format (not ioredis-style `{ host, port }`)
- **Classes**: Queue, Worker, Producer, FlowProducer, QueueEvents, Broadcast

```typescript
import { Queue, Worker } from 'glide-mq';

const connection = { addresses: [{ host: 'localhost', port: 6379 }] };
const queue = new Queue('tasks', { connection });
await queue.add('email', { to: 'user@example.com' }, { attempts: 3, priority: 1 });

const worker = new Worker('tasks', async (job) => {
  // process job
  return { sent: true };
}, { connection, concurrency: 10 });
```

Migration guides available for BullMQ and Bee-Queue users. See the **glide-mq**, **glide-mq-migrate-bullmq**, and **glide-mq-migrate-bee** skills for details.

### Sidekiq (Ruby)

Version 8.0+ officially supports Valkey 7.2+. Update the connection URL in your Sidekiq configuration:

```ruby
Sidekiq.configure_server do |config|
  config.redis = { url: "valkey://localhost:6379/0" }
end
```

### BullMQ (Node.js)

BullMQ works with Valkey as a drop-in Redis
replacement via ioredis. GLIDE integration has been requested but is not yet
implemented. Taskforce maintains an active benchmarking repo
(taskforcesh/bullmq-valkey-bench), suggesting deeper Valkey evaluation is
underway.

```typescript
const queue = new Queue('tasks', {
  connection: { host: 'localhost', port: 6379 }
});
```

### Celery (Python)

Celery works with Valkey using the `redis://` URL scheme:

```python
app = Celery('tasks', broker='redis://localhost:6379/0')
```

**No native valkey:// transport exists.** The feature request for `celery[valkey]`
has been open for nearly two years with no progress. The kombu transport library
does not have a `valkey://` scheme. Switching the broker URL to `valkey://`
breaks celery-beat scheduling. Continue using `redis://` URLs.

A community workaround exists: `vuonglv1612/celery-valkey-backend` - a
custom result backend for Valkey, but not an official Celery package.

### RQ - Redis Queue (Python)

RQ works with Valkey via endpoint change. Use valkey-py or redis-py as the connection library. See the **valkey-glide** skill for client-level migration details.

---

## ORM and Caching Integrations

These integrations use Valkey as a caching layer for object-relational mappers and application caching frameworks.

### Hibernate Second-Level Cache (via Redisson)

Redisson provides a Hibernate second-level cache backed by Valkey. Redisson explicitly supports both Valkey and Redis.

Configuration in `hibernate.cfg.xml`:

```xml
<property name="hibernate.cache.use_second_level_cache">true</property>
<property name="hibernate.cache.region.factory_class">
  org.redisson.hibernate.RedissonRegionFactory
</property>
```

Redisson maps Hibernate cache regions to Valkey data structures, providing distributed caching for entities, collections, and query results.

### JCache (JSR-107)

Redisson implements the JCache (JSR-107) specification with Valkey as the backing store. This allows any JCache-compatible framework to use Valkey transparently:

```java
CachingProvider provider = Caching.getCachingProvider();
CacheManager manager = provider.getCacheManager();
Cache<String, Object> cache = manager.getCache("myCache");
```

### Spring Cache Abstraction

Two paths for Spring Cache with Valkey:

1. **Spring Data Valkey** - native ValkeyCache and ValkeyCacheManager
2. **Spring Data Redis** - RedisCacheManager works with Valkey by endpoint swap

Both support TTL configuration, cache key prefixes, and null value caching.

### Keyv (Node.js)

The `@keyv/valkey` adapter provides a Keyv-compatible store backed by Valkey via iovalkey:

```
npm install keyv @keyv/valkey
```

Keyv is a popular key-value abstraction used by libraries like got, cacheable-request, and Apollo Server for caching.

---

## Choosing a Framework Integration Path

| Scenario | Recommended Path |
|----------|-----------------|
| New Spring project | Spring Boot Starter for Valkey (GA) |
| Existing Spring + Redis | Keep Spring Data Redis, swap endpoint |
| New Django project | django-valkey |
| Existing Django + Redis | django-redis works, migrate at your pace |
| New Rails project | Sidekiq 8.0+ with Valkey endpoint |
| Existing Rails + Redis | Swap endpoints, no code changes |
| Rails multi-tenant | valkey-namespace for key isolation |
| Java distributed objects | Redisson (supports Valkey natively) |

For client-level details and migration patterns, see the **valkey-glide** skill.

---

## See Also

- [CLI and Benchmarking Tools](cli-benchmarking.md) - valkey-cli, valkey-benchmark, and valkey-perf-benchmark
- [Testing Tools](testing.md) - Testcontainers, Spring Data Valkey test support
- [Migration from Redis](migration.md) - server and client migration paths
