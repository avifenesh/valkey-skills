Spring Boot 3.x app using Spring Data Redis + Jedis. Migrate to Spring Data Valkey + GLIDE Java. All tests must pass.

## Current Stack

- Spring Boot 3.2.x with `spring-boot-starter-data-redis`
- Jedis driver
- `@EnableCaching` with `@Cacheable` / `@CacheEvict` on user CRUD
- `RedisTemplate<String, String>` for session storage
- `RedisMessageListenerContainer` for pub/sub notifications
- 6 integration tests covering cache, sessions, pub/sub, and CRUD

## Migration Requirements

1. Replace `spring-boot-starter-data-redis` with `spring-boot-starter-data-valkey`
2. Replace Jedis driver with GLIDE Java driver
3. Update all imports from `org.springframework.data.redis` to `io.valkey.springframework.data.valkey`
4. Update `application.properties` from `spring.data.redis.*` to `spring.data.valkey.*`
5. Replace `RedisTemplate` with `ValkeyTemplate`, `RedisMessageListenerContainer` with the Valkey equivalent
6. Preserve all existing functionality - caching, sessions, pub/sub
7. All 6 integration tests must pass without changes to test assertions

## Workspace

The `workspace/` directory contains the full Maven project. A `docker-compose.yml` provides a single Valkey instance. Run `mvn test` to verify.
