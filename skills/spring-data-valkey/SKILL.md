---
name: spring-data-valkey
description: "Spring Data Valkey integration for Spring Boot - GLIDE as first-class driver. Covers auto-configuration, ValkeyTemplate, caching, Actuator health, IAM auth, Spring Data Redis migration. Not for raw GLIDE Java API - use valkey-glide-java."
version: 1.1.0
argument-hint: "[Spring config, template, or migration question]"
---

# Spring Data Valkey Integration

Use when integrating GLIDE with Spring Boot applications via Spring Data Valkey, configuring auto-wired connections, templates, caching, health indicators, and IAM authentication. For GLIDE production deployment, see `production.md`. For error handling patterns, see `error-handling.md`.

---

## Contents

- [Overview](#overview)
- [Maven Dependency](#maven-dependency)
- [Application Properties Configuration](#application-properties-configuration)
- [Auto-Configuration](#auto-configuration)
- [Spring Cache Abstraction](#spring-cache-abstraction)
- [Spring Boot Actuator Health Indicators](#spring-boot-actuator-health-indicators)
- [Spring Data Repositories](#spring-data-repositories)
- [Migrating from Spring Data Redis](#migrating-from-spring-data-redis)
- [When to Use Spring Data Valkey vs Direct GLIDE API](#when-to-use-spring-data-valkey-vs-direct-glide-api)
- [Version Compatibility](#version-compatibility)

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
    <version>1.0.0</version>
</dependency>
<dependency>
    <groupId>io.valkey</groupId>
    <artifactId>valkey-glide</artifactId>
    <classifier>${os.detected.classifier}</classifier>
    <version>2.3.0</version>
</dependency>
```

GLIDE requires platform-specific native libraries. Add the os-maven-plugin to resolve the classifier:

```xml
<build>
    <extensions>
        <extension>
            <groupId>kr.motd.maven</groupId>
            <artifactId>os-maven-plugin</artifactId>
            <version>1.7.1</version>
        </extension>
    </extensions>
</build>
```

This starter includes:
- Spring Data Valkey core library
- Auto-configuration for connection factories, templates, and repositories
- Spring Boot Actuator health indicator for Valkey
- IAM authentication support for AWS ElastiCache and MemoryDB

### Supported Drivers

| Driver | Status | Use Case |
|--------|--------|----------|
| GLIDE | Supported | Production - multi-language consistency, cluster reliability |
| Lettuce | Supported | Reactive/async workloads, existing Lettuce users |
| Jedis | Supported | Legacy compatibility, synchronous-only workloads |

Spring Data Valkey auto-detects the driver on the classpath. If multiple drivers are present, configure the preferred one explicitly via `spring.data.valkey.client-type`:

```properties
spring.data.valkey.client-type=valkeyglide
# Options: valkeyglide, lettuce, jedis
```

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

### IAM Authentication (AWS ElastiCache / MemoryDB)

Spring Data Valkey 1.0 supports IAM authentication for GLIDE connections to AWS ElastiCache and MemoryDB:

```properties
spring.data.valkey.host=your-cluster-endpoint.cache.amazonaws.com
spring.data.valkey.username=your-iam-user-id
spring.data.valkey.ssl.enabled=true
spring.data.valkey.client-type=valkeyglide

# All three IAM properties are required
spring.data.valkey.valkey-glide.iam-authentication.cluster-name=your-cluster-name
spring.data.valkey.valkey-glide.iam-authentication.service=ELASTICACHE
spring.data.valkey.valkey-glide.iam-authentication.region=us-east-1
# Optional: token refresh interval (default 300s)
# spring.data.valkey.valkey-glide.iam-authentication.refresh-interval-seconds=300
```

IAM auth requires TLS and the GLIDE driver. AWS credentials must be available in the environment (environment variables, IAM role, or `~/.aws/credentials`). The driver handles token refresh automatically.

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
@ValkeyHash("persons")
public class Person {
    @Id
    private String id;
    @Indexed
    private String firstname;
    @Indexed
    private String lastname;
    private int age;
}

public interface PersonRepository extends CrudRepository<Person, String> {
    List<Person> findByFirstname(String firstname);
}
```

Import: `io.valkey.springframework.data.valkey.core.ValkeyHash`

Repository support uses secondary indexes via Valkey SETs. This works well for small to medium datasets but is not designed for high-cardinality queries.

---

## Migrating from Spring Data Redis

Spring Data Valkey provides a complete migration path from Spring Data Redis. The official migration guide is at https://github.com/valkey-io/spring-data-valkey/blob/main/MIGRATION.md.

Key migration steps:
1. Replace `spring-boot-starter-data-redis` with `spring-boot-starter-data-valkey`
2. Update package imports from `org.springframework.data.redis` to `io.valkey.springframework.data.valkey`
3. Replace `@RedisHash` annotations with `@ValkeyHash`
4. Update property prefixes from `spring.data.redis` to `spring.data.valkey`
5. Optionally add GLIDE driver (or continue with Lettuce/Jedis via `client-type`)

You can continue using Lettuce or Jedis as the driver - set `spring.data.valkey.client-type=lettuce` or `spring.data.valkey.client-type=jedis`.

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

| Spring Data Valkey | Spring Boot | GLIDE | Valkey | Java |
|-------------------|-------------|-------|--------|------|
| 1.0.0 | 3.5.x | 2.3.x | 7.2+ | 17+ |

Check the GitHub repository at https://github.com/valkey-io/spring-data-valkey for the latest compatibility matrix and release notes.
