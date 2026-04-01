## Task 10: Spring Data Valkey + GLIDE Java - Judging Criteria

### Correct Spring Migration (30%)

- `spring-boot-starter-data-redis` fully replaced with `spring-boot-starter-data-valkey`
- Jedis dependency removed entirely from pom.xml
- GLIDE Java driver added with correct classifier and os-maven-plugin
- Property prefix changed from `spring.data.redis` to `spring.data.valkey`
- Client type set to `valkeyglide` (or GLIDE auto-detected on classpath)

### Import and API Migration (25%)

- All `org.springframework.data.redis` imports changed to `io.valkey.springframework.data.valkey`
- `RedisTemplate` replaced with `ValkeyTemplate`
- `StringRedisTemplate` replaced with `StringValkeyTemplate` (if used)
- `RedisMessageListenerContainer` replaced with Valkey equivalent
- `@RedisHash` replaced with `@ValkeyHash` (if used)
- No leftover Redis-specific class references

### Driver Configuration (15%)

- GLIDE driver properly configured (platform classifier, native library resolution)
- Connection factory auto-configuration works correctly
- No hardcoded Jedis or Lettuce connection factory beans

### Test Preservation (20%)

- All 6 original test cases pass
- Test assertions unchanged - tests validate behavior, not implementation
- Cache hit/miss semantics preserved
- Session read/write round-trip works
- Pub/sub message delivery confirmed
- CRUD operations functional

### No Broken Abstractions (10%)

- Spring Cache abstraction still works through annotations
- No raw GLIDE client calls where Spring abstractions suffice
- DI wiring is clean - no manual bean overrides unless required by GLIDE driver setup
- Application context loads without errors
