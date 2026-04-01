# Spring Data Valkey Migration and Comparison

Use when migrating from Spring Data Redis, comparing GLIDE vs Lettuce vs Jedis drivers, or deciding between Spring Data Valkey and the direct GLIDE API.

## Contents

- Migrating from Spring Data Redis (line 12)
- Driver Comparison Test Suite (line 29)
- When to Use Spring Data Valkey vs Direct GLIDE API (line 42)
- Hybrid Approach (line 64)

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

---

## Driver Comparison Test Suite

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

---

## Hybrid Approach

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
