# Spring Data Valkey Auto-Configuration and Templates

Use when configuring ValkeyTemplate, StringValkeyTemplate, Spring Cache abstraction, Actuator health indicators, or Spring Data repositories with Valkey.

## Contents

- Connection Factory (line 12)
- ValkeyTemplate (line 18)
- StringValkeyTemplate (line 43)
- Spring Cache Abstraction (line 63)
- Cache TTL Configuration (line 96)
- Spring Boot Actuator Health Indicators (line 107)
- Spring Data Repositories (line 132)

---

## Connection Factory

Spring Data Valkey auto-configures a `ValkeyConnectionFactory` based on the classpath driver. For GLIDE, this wraps `GlideClient` or `GlideClusterClient` depending on whether cluster nodes are configured.

---

## ValkeyTemplate

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

---

## StringValkeyTemplate

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

---

## Cache TTL Configuration

```properties
spring.cache.type=valkey
spring.cache.valkey.time-to-live=600000
spring.cache.valkey.cache-null-values=false
spring.cache.valkey.key-prefix=app:
spring.cache.valkey.use-key-prefix=true
```

---

## Spring Boot Actuator Health Indicators

A health indicator is registered automatically when Actuator is on the classpath:

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

Repository support uses secondary indexes via Valkey SETs. Suitable for small to medium datasets; not designed for high-cardinality queries.
