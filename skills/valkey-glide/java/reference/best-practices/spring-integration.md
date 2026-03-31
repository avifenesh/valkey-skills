# Spring Data Valkey Integration

Use when integrating GLIDE with Spring Boot applications via Spring Data Valkey, configuring auto-wired connections, templates, caching, and health indicators. For GLIDE production deployment, see `production.md`. For error handling patterns, see `error-handling.md`.

---

## Overview

Spring Data Valkey is a dedicated Spring Boot integration for Valkey. It provides auto-configuration for connections, templates, repositories, and caching - with GLIDE as a first-class driver alongside Lettuce and Jedis.

The project lives at https://github.com/valkey-io/spring-data-valkey and is maintained by the Valkey community.

---

## Maven Dependency

```xml
<dependency>
    <groupId>io.valkey.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-valkey</artifactId>
    <version>0.2.0</version>
</dependency>
```

This starter includes:
- Spring Data Valkey core library
- Auto-configuration for connection factories, templates, and repositories
- Spring Boot Actuator health indicator for Valkey

### Supported Drivers

| Driver | Status | Use Case |
|--------|--------|----------|
| GLIDE | Supported | Production - multi-language consistency, cluster reliability |
| Lettuce | Supported | Reactive/async workloads, existing Lettuce users |
| Jedis | Supported | Legacy compatibility, synchronous-only workloads |

Spring Data Valkey auto-detects the driver on the classpath. If multiple drivers are present, configure the preferred one explicitly.

---

## Application Properties Configuration

### Basic Connection

```properties
# Standalone mode
spring.data.valkey.host=localhost
spring.data.valkey.port=6379
spring.data.valkey.password=your-password
spring.data.valkey.database=0

# Connection timeout
spring.data.valkey.timeout=2000ms
```

### Cluster Mode

```properties
spring.data.valkey.cluster.nodes=node1:6379,node2:6379,node3:6379
spring.data.valkey.cluster.max-redirects=5
```

### TLS

```properties
spring.data.valkey.ssl.enabled=true
```

### OpenTelemetry via Spring Properties

GLIDE's OpenTelemetry integration is configurable through Spring properties:

```properties
spring.data.valkey.valkey-glide.open-telemetry.enabled=true
spring.data.valkey.valkey-glide.open-telemetry.traces-endpoint=http://otel-collector:4317
spring.data.valkey.valkey-glide.open-telemetry.metrics-endpoint=http://otel-collector:4317
```

This configures GLIDE's native OTel integration - not the Spring Micrometer bridge. The traces and metrics come directly from the Rust core with per-command spans.

---

## Auto-Configuration

### Connection Factory

Spring Data Valkey auto-configures a `ValkeyConnectionFactory` based on the driver detected on the classpath. For GLIDE, this wraps `GlideClient` or `GlideClusterClient` depending on whether cluster nodes are configured.

### ValkeyTemplate

The auto-configured `ValkeyTemplate` provides the primary API for interacting with Valkey:

```java
@Service
public class UserService {
    private final ValkeyTemplate<String, User> template;

    public UserService(ValkeyTemplate<String, User> template) {
        this.template = template;
    }

    public void saveUser(User user) {
        template.opsForValue().set("user:" + user.getId(), user);
    }

    public User getUser(String id) {
        return template.opsForValue().get("user:" + id);
    }

    public void addToLeaderboard(String userId, double score) {
        template.opsForZSet().add("leaderboard", userId, score);
    }
}
```

### StringValkeyTemplate

For string-only workloads, use `StringValkeyTemplate` - auto-configured alongside `ValkeyTemplate`:

```java
@Service
public class CacheService {
    private final StringValkeyTemplate template;

    public CacheService(StringValkeyTemplate template) {
        this.template = template;
    }

    public void cache(String key, String value, Duration ttl) {
        template.opsForValue().set(key, value, ttl);
    }
}
```

---

## Spring Cache Abstraction

Enable caching with `@EnableCaching` and use Valkey as the cache store:

```java
@Configuration
@EnableCaching
public class CacheConfig {
    // Auto-configured ValkeyConnectionFactory is used
}
```

```java
@Service
public class ProductService {
    @Cacheable(value = "products", key = "#id")
    public Product findById(String id) {
        // This result is cached in Valkey
        return productRepository.findById(id);
    }

    @CacheEvict(value = "products", key = "#id")
    public void updateProduct(String id, Product product) {
        productRepository.save(product);
    }

    @CachePut(value = "products", key = "#product.id")
    public Product createProduct(Product product) {
        return productRepository.save(product);
    }
}
```

### Cache TTL Configuration

```properties
spring.cache.type=valkey
spring.cache.valkey.time-to-live=600000
spring.cache.valkey.cache-null-values=false
spring.cache.valkey.key-prefix=app:
spring.cache.valkey.use-key-prefix=true
```

---

## Spring Boot Actuator Health Indicators

Spring Data Valkey registers a health indicator automatically when Actuator is on the classpath:

```properties
management.health.valkey.enabled=true
management.endpoint.health.show-details=always
```

The health endpoint reports:
- Connection status (UP/DOWN)
- Valkey server version
- Cluster state (if applicable)

```json
{
    "status": "UP",
    "details": {
        "valkey": {
            "status": "UP",
            "details": {
                "version": "8.1.0"
            }
        }
    }
}
```

---

## Spring Data Repositories

Spring Data Valkey supports repository-style access for entities stored as Valkey hashes:

```java
@RedisHash("person")  // Stored as Valkey hash
public class Person {
    @Id
    private String id;
    private String name;
    private int age;
}

public interface PersonRepository extends CrudRepository<Person, String> {
    List<Person> findByName(String name);
}
```

Repository support uses secondary indexes via Valkey SETs. This works well for small to medium datasets but is not designed for high-cardinality queries.

---

## Alternative Integration: Spring Data Redis Fork

For teams that cannot adopt Spring Data Valkey (dependency constraints, existing Spring Data Redis investments), there is an alternative path: fork Spring Data Redis and replace the driver with GLIDE using a sed-based script.

This approach rewrites imports and class references from Lettuce/Jedis to GLIDE equivalents. It preserves the full Spring Data Redis API surface while routing all operations through GLIDE's Rust core.

### Lettuce Compatibility Layer

A Lettuce compatibility layer for drop-in migration to GLIDE is being developed. This would allow existing Spring Data Redis applications using Lettuce to switch to GLIDE without changing application code.

### Driver Comparison Test Suite

When evaluating GLIDE against Lettuce and Jedis for Spring integration, build a comparison test suite that exercises all three Java drivers against the same workload:
- Connection lifecycle (create, reconnect, close)
- Template operations (opsForValue, opsForHash, opsForZSet)
- Cache abstraction (@Cacheable, @CacheEvict, @CachePut)
- Cluster failover behavior
- Latency percentiles (p50, p95, p99) under load

This validates that the Spring abstraction layer does not mask driver-specific behaviors or performance characteristics.

---

## When to Use Spring Data Valkey vs Direct GLIDE API

### Use Spring Data Valkey When

- You are building a Spring Boot application and want idiomatic integration
- You need Spring Cache abstraction (`@Cacheable`, `@CacheEvict`)
- You want auto-configuration for connections, templates, and health checks
- Your team follows Spring conventions and expects dependency injection
- You need repository-style CRUD for simple entity persistence

### Use Direct GLIDE API When

- You need fine-grained control over batching (pipeline/transaction tuning)
- You use advanced features not exposed through Spring Data (AZ Affinity, custom scripts, streams consumer groups)
- You need maximum performance and want to avoid the Spring abstraction overhead
- Your application is not Spring-based
- You need control over reconnection strategy and inflight request limits

### Hybrid Approach

You can use both. Configure Spring Data Valkey for auto-wired templates and caching, then inject the underlying GLIDE client for advanced operations:

```java
@Service
public class HybridService {
    private final StringValkeyTemplate template;  // Spring abstraction
    private final GlideClient glideClient;         // Direct GLIDE

    public HybridService(StringValkeyTemplate template, GlideClient glideClient) {
        this.template = template;
        this.glideClient = glideClient;
    }

    public String cachedLookup(String key) {
        return template.opsForValue().get(key);
    }

    public Object[] batchOperation() throws Exception {
        // Use direct GLIDE for batch operations
        Batch tx = new Batch(true);
        tx.set("key1", "value1");
        tx.set("key2", "value2");
        tx.incr("counter");
        return glideClient.exec(tx, false).get();
    }
}
```

---

## Version Compatibility

| Spring Data Valkey | Spring Boot | GLIDE | Valkey |
|-------------------|-------------|-------|--------|
| 0.2.0 | 3.x | 2.x | 7.2+ |

The project is under active development. Check the GitHub repository at https://github.com/valkey-io/spring-data-valkey for the latest compatibility matrix and release notes.
