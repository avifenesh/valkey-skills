# Migration from Redis

Use when planning or executing a migration from Redis to Valkey - covers server compatibility, migration methods, client swaps, and effort estimation.

---

## Server Compatibility

### What Migrates Cleanly

| Source | Target | Compatible | Method |
|--------|--------|------------|--------|
| Redis OSS 6.2 | Valkey 7.2+ | Yes | RDB, replication, or endpoint swap |
| Redis OSS 7.0 | Valkey 7.2+ | Yes | RDB, replication, or endpoint swap |
| Redis OSS 7.2 | Valkey 7.2+ | Yes | RDB, replication, or endpoint swap |
| Redis 7.4+ | Valkey | No | Post-fork divergence; RDB format and features incompatible |

The critical boundary is Redis 7.2. Valkey forked from Redis 7.2.4 in March 2024, so any Redis version up to and including 7.2.x is fully compatible. Redis 7.4 and later introduced changes that break forward compatibility with Valkey.

### Redis 7.4+ Incompatibility

Redis 7.4 (released after the fork) introduces:

- New RDB encoding versions that Valkey does not recognize
- Commands and behaviors that diverge from the shared 7.2 baseline
- License change to SSPL/RSALv2 (no longer open source)

If you are running Redis 7.4+, you cannot directly migrate data to Valkey. Options include:

1. Downgrade Redis to 7.2.x first, then migrate to Valkey
2. Export data at the application level and reimport
3. Use a Redis-to-Valkey migration tool that handles format translation (check community tooling)

---

## Migration Methods

### Method 1: RDB Snapshot

The simplest approach for offline migrations or scheduled maintenance windows.

1. On the Redis server, trigger a background save:
   ```
   BGSAVE
   ```
2. Wait for the save to complete:
   ```
   LASTSAVE
   ```
3. Copy the `dump.rdb` file to the Valkey data directory
4. Start Valkey - it loads the RDB on startup

**Advantages**: Simple, well-understood, works for any data size.
**Disadvantages**: Requires downtime during the copy-and-restart window. Data written after BGSAVE is lost.

### Method 2: Replication

Zero-downtime migration using Valkey's replication capability.

1. Start a Valkey instance
2. Point it at the Redis primary:
   ```
   REPLICAOF redis-host 6379
   ```
3. Wait for initial sync to complete (monitor with `INFO replication`)
4. Verify data consistency
5. Promote Valkey to primary:
   ```
   REPLICAOF NO ONE
   ```
6. Redirect application traffic to the Valkey endpoint

**Advantages**: Near-zero downtime. Data stays in sync until cutover.
**Disadvantages**: Requires network connectivity between Redis and Valkey. Both servers run simultaneously during sync.

### Method 3: Endpoint Swap

For applications using Redis as a cache (where data loss on restart is acceptable):

1. Deploy Valkey alongside Redis
2. Update application connection URLs to point at Valkey
3. Restart or rolling-deploy the application
4. Decommission Redis

This works because most Redis clients speak the RESP protocol, which Valkey implements identically. No data migration needed - the cache warms up naturally.

**Advantages**: Simplest approach for cache workloads.
**Disadvantages**: Cold cache after switchover. Not suitable for persistent data.

---

## Client Migration Matrix

Most Redis clients work with Valkey by changing only the connection endpoint. For dedicated Valkey support, swap to the Valkey-native client.

| From | To | Effort | Notes |
|------|----|--------|-------|
| redis-py | valkey-py | Low | Change import from `redis` to `valkey`; `Redis` alias available in valkey-py |
| redis-py | Valkey GLIDE (Python) | Medium | New API; different connection model and defaults |
| ioredis | iovalkey | Low | npm package swap; API fully compatible |
| node-redis | iovalkey | Medium | Different API surface; migration guide available |
| Jedis | valkey-java | Low | Drop-in replacement; fork of Jedis |
| Jedis | Valkey GLIDE (Java) | Low-Medium | GLIDE includes Jedis compatibility layer |
| Lettuce | Lettuce (keep) | None | Lettuce works with Valkey unchanged |
| go-redis | valkey-go | Medium | API differences exist; valkey-go has auto-pipelining |
| Redisson | Redisson (keep) | None | Redisson supports Valkey natively |
| StackExchange.Redis | StackExchange.Redis (keep) | None | Explicitly supports Valkey; auto-detects via GetProductVariant |
| StackExchange.Redis | Valkey GLIDE (C#) | Low | API designed for SE.Redis compatibility |

### Effort Levels Explained

- **None**: No code changes. Change the connection endpoint only.
- **Low**: Package swap with minimal code changes (import rename, dependency update).
- **Medium**: API differences require code modifications. Migration guides available.

For detailed client migration patterns, API mapping, and GLIDE adoption guidance, see the **valkey-glide** skill.

---

## Migration Planning Checklist

### 1. Inventory Your Redis Usage

- Which Redis version are you running? (must be <= 7.2 for direct migration)
- Which clients and languages connect to Redis?
- Is Redis used as a cache, session store, primary database, or message broker?
- Are you using Redis modules (RedisJSON, RediSearch, RedisBloom)?
- Are you using Redis Sentinel or Cluster mode?

### 2. Module Compatibility

| Redis Module | Valkey Equivalent | Status |
|-------------|-------------------|--------|
| RedisJSON | valkey-json | GA; API and RDB compatible |
| RedisBloom | valkey-bloom | GA; API compatible for BF.* commands |
| RediSearch | valkey-search | GA; vector search, full-text search, tag, numeric, aggregations (1.2.0) |
| RedisTimeSeries | No official module | Community redistimeseries.so works on Valkey 7.2 |
| RedisGraph | Not available | RedisGraph was EOL'd Jan 2025; consider FalkorDB |

If you depend on advanced RediSearch features like phonetic matching or auto-complete, these are not yet available in valkey-search. Full-text search with stemming, keyword, phrase, prefix, suffix, wildcard, and fuzzy queries is supported since valkey-search 1.2.0.

### 3. Managed Service Migration

If migrating from a managed Redis service:

| From | To | Path |
|------|----|------|
| AWS ElastiCache (Redis) | ElastiCache for Valkey | In-place engine swap or new cluster + replication |
| AWS MemoryDB (Redis) | MemoryDB for Valkey | New cluster + data migration |
| Google Memorystore (Redis) | Memorystore for Valkey | New instance + RDB import |
| Self-hosted Redis | Any managed Valkey | RDB export + import |

AWS ElastiCache supports in-place migration from Redis to Valkey for compatible versions, which is the lowest-friction path.

### 4. Testing Before Cutover

- Deploy Valkey in a staging environment with production-like data
- Run your integration test suite against Valkey
- Benchmark with valkey-benchmark to establish performance baseline
- Test failover scenarios if using Sentinel or Cluster mode
- Verify module behavior if using valkey-json, valkey-bloom, or valkey-search

See [testing.md](testing.md) for Testcontainers setup to automate integration testing against Valkey.

---

## Valkey 9.0 Migration Considerations

If migrating directly to Valkey 9.0 (released October 2025), be aware of new capabilities that may influence your architecture:

- **Performance**: Up to 40% higher throughput vs Valkey 8.1. Zero-copy responses, memory prefetching, MPTCP, and AVX-512 SIMD optimizations.
- **Scalability**: Clusters support up to 2,000 nodes and 1 billion+ requests per second.
- **Atomic slot migration**: Slots move atomically in AOF format rather than key-by-key, reducing migration latency and risk.
- **Hash field expiration**: Individual hash fields can now expire independently - a feature that Redis does not have.
- **Multi-DB clustering**: Numbered databases work in cluster mode, providing namespace isolation without separate clusters.
- **Official modules**: JSON, Bloom, Search (vector), and LDAP are bundled in the valkey-bundle container image.

These features are Valkey-only and represent the beginning of divergence from Redis. Applications migrating from Redis 7.2 can adopt them incrementally.

---

## Framework-Specific Migration Notes

### Spring

Existing Spring Data Redis applications work with Valkey unchanged. For native Valkey support, add the Spring Boot Starter for Valkey. See [frameworks.md](frameworks.md) for Maven coordinates and feature comparison.

### Django

Switch from django-redis to django-valkey for native support, or keep django-redis and change only the endpoint. See [frameworks.md](frameworks.md) for configuration details.

### Celery

Continue using the `redis://` URL scheme when connecting Celery to Valkey. The `valkey://` scheme is not yet supported by the kombu transport layer. See [frameworks.md](frameworks.md) for the Celery caveat.

### Sidekiq

Sidekiq 8.0+ officially supports Valkey 7.2+. Update your Sidekiq configuration with the Valkey endpoint. Earlier Sidekiq versions work via RESP compatibility but are not officially supported.

---

## See Also

- [Framework Integrations](frameworks.md) - framework-specific setup after migration
- [CLI and Benchmarking Tools](cli-benchmarking.md) - valkey-benchmark for post-migration performance validation
- [Infrastructure as Code](iac.md) - Terraform for provisioning Valkey infrastructure
- [Testing Tools](testing.md) - Testcontainers for pre-migration integration testing
