# Spring Data Redis to Spring Data Valkey Migration

Migrate this Spring Boot 3.x application from Spring Data Redis (with Jedis) to Spring Data Valkey (with GLIDE Java).

## What to do

1. Replace `spring-boot-starter-data-redis` with `spring-boot-starter-data-valkey` in pom.xml
2. Remove the `jedis` dependency entirely
3. Add the `valkey-glide` driver dependency with the platform classifier and `os-maven-plugin` build extension
4. Update ALL Java imports from `org.springframework.data.redis` to the Spring Data Valkey equivalents
5. Rename Redis-prefixed classes to Valkey equivalents (RedisTemplate -> ValkeyTemplate, RedisConnectionFactory -> ValkeyConnectionFactory, etc.)
6. Update `application.properties` from `spring.data.redis.*` to `spring.data.valkey.*`
7. Ensure all 6 tests pass against a Valkey server on localhost:6509

## Important

- Do NOT just add Valkey alongside Redis - completely replace all Redis references
- Do NOT leave any `spring-boot-starter-data-redis` or `jedis` in pom.xml
- Do NOT leave any `org.springframework.data.redis` imports in Java files
- Do NOT leave any `spring.data.redis` properties in application.properties
- The application must compile and all 6 tests must pass

## Valkey Server

A Valkey server is available on `localhost:6509`.
