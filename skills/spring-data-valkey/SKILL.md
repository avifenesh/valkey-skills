---
name: spring-data-valkey
description: "Spring Data Valkey integration for Spring Boot - GLIDE as first-class driver. Covers auto-configuration, ValkeyTemplate, caching, Actuator health, IAM auth, Spring Data Redis migration. Not for raw GLIDE Java API - use valkey-glide-java."
version: 1.1.0
argument-hint: "[Spring config, template, or migration question]"
---

# Spring Data Valkey Integration

Use when integrating GLIDE with Spring Boot applications via Spring Data Valkey, configuring auto-wired connections, templates, caching, health indicators, and IAM authentication.

## Routing

- ValkeyTemplate, StringValkeyTemplate, auto-configuration, repositories -> Auto-Configuration and Templates
- @Cacheable, @CacheEvict, @CachePut, Spring Cache, cache TTL -> Auto-Configuration and Templates
- Actuator, health indicator, health check -> Auto-Configuration and Templates
- Spring Data Redis, migration, RedisTemplate rename -> Migration and Comparison
- Driver comparison, Lettuce vs GLIDE, when to use -> Migration and Comparison
- Hybrid approach, direct GLIDE API -> Migration and Comparison

## Overview

Spring Data Valkey is a dedicated Spring Boot integration for Valkey. It provides auto-configuration for connections, templates, repositories, and caching - with GLIDE as a first-class driver alongside Lettuce and Jedis.

The project lives at https://github.com/valkey-io/spring-data-valkey and is maintained by the Valkey community.

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

### Supported Drivers

| Driver | Status | Use Case |
|--------|--------|----------|
| GLIDE | Supported | Production - multi-language consistency, cluster reliability |
| Lettuce | Supported | Reactive/async workloads, existing Lettuce users |
| Jedis | Supported | Legacy compatibility, synchronous-only workloads |

Spring Data Valkey auto-detects the driver on the classpath. Explicit configuration:

```properties
spring.data.valkey.client-type=valkeyglide
# Options: valkeyglide, lettuce, jedis
```

## Application Properties Configuration

### Basic Connection

```properties
spring.data.valkey.host=localhost
spring.data.valkey.port=6379
spring.data.valkey.password=your-password
spring.data.valkey.database=0
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

```properties
spring.data.valkey.host=your-cluster-endpoint.cache.amazonaws.com
spring.data.valkey.username=your-iam-user-id
spring.data.valkey.ssl.enabled=true
spring.data.valkey.client-type=valkeyglide
spring.data.valkey.valkey-glide.iam-authentication.cluster-name=your-cluster-name
spring.data.valkey.valkey-glide.iam-authentication.service=ELASTICACHE
spring.data.valkey.valkey-glide.iam-authentication.region=us-east-1
```

IAM auth requires TLS and the GLIDE driver. AWS credentials must be available in the environment. Token refresh is automatic.

### OpenTelemetry via Spring Properties

```properties
spring.data.valkey.valkey-glide.open-telemetry.enabled=true
spring.data.valkey.valkey-glide.open-telemetry.traces-endpoint=http://otel-collector:4317
spring.data.valkey.valkey-glide.open-telemetry.metrics-endpoint=http://otel-collector:4317
```

## Version Compatibility

| Spring Data Valkey | Spring Boot | GLIDE | Valkey | Java |
|-------------------|-------------|-------|--------|------|
| 1.0.0 | 3.5.x | 2.3.x | 7.2+ | 17+ |

## Reference

| Topic | File |
|-------|------|
| ValkeyTemplate, StringValkeyTemplate, caching, Actuator health, repositories | [auto-configuration](reference/auto-configuration.md) |
| Spring Data Redis migration, driver comparison, when to use, hybrid approach | [migration-and-comparison](reference/migration-and-comparison.md) |

## See Also

- **valkey-glide-java** skill - full GLIDE Java API details
- Production deployment (see valkey-glide skill) - timeout tuning, connection management, observability
- Error handling (see valkey-glide skill) - error types, reconnection, batch error semantics
