# Valkey Ecosystem Guide

> Comprehensive map of the Valkey ecosystem - clients, modules, managed services, frameworks, monitoring, and developer tools.

Valkey is an open-source (BSD-licensed), high-performance key-value datastore stewarded by the Linux Foundation. Forked from Redis 7.2.4 in March 2024 after Redis changed to a source-available license, Valkey maintains full RESP protocol compatibility with Redis OSS while diverging with its own features and roadmap. As of late 2025, Valkey 9.0 is GA, capable of 1 billion+ requests per second in cluster mode with up to 40% higher throughput than 8.1.

---

## 1. Client Libraries

Valkey maintains RESP protocol compatibility with Redis, so most Redis clients work without code changes - just point at a Valkey endpoint. However, the Valkey project also maintains dedicated forks and an official multi-language client (GLIDE) for first-class support.

### 1.1 Valkey GLIDE (Official Multi-Language Client)

> See the **valkey-glide** skill for implementation details and usage patterns.

GLIDE (General Language Independent Driver for the Enterprise) is the official Valkey client library, written in Rust with language bindings. It ships pre-configured with best practices from over a decade of operating Redis-compatible services.

- **Languages**: Python, Java, Node.js, Go (GA); C# and PHP (preview); C++ and Ruby (in development)
- **Server support**: Valkey 7.2+, Redis OSS 6.2/7.0/7.2
- **Key features**: AZ-affinity routing, auto-reconnect, connection pooling, cluster-aware, Jedis compatibility layer for Java
- **Latest version**: v2.1.1
- **Repo**: [valkey-io/valkey-glide](https://github.com/valkey-io/valkey-glide)

### 1.2 Python

| Client | Version | Type | Valkey Status | Notes |
|--------|---------|------|---------------|-------|
| **valkey-py** | 6.1.0 | Official Valkey fork | Native | Fork of redis-py; `pip install valkey[hiredis]`; cluster support built in |
| **redis-py** | - | Redis-maintained | Compatible | Works by changing only the server endpoint; long-term Valkey compat not guaranteed |
| **Valkey GLIDE** | 2.1.1 | Official | Native | See valkey-glide skill |

**Migration from redis-py to valkey-py**: Change `from redis import Redis` to `from valkey import Valkey`. The `Redis` class alias is still available in valkey-py for convenience. Install with `pip install valkey`.

### 1.3 Node.js

| Client | Version | Type | Valkey Status | Notes |
|--------|---------|------|---------------|-------|
| **iovalkey** | 0.3.1 | Official Valkey fork | Native | Fork of ioredis; TypeScript; Cluster/Sentinel/Streams/Pub-Sub |
| **ioredis** | - | Community | Compatible | Works with Valkey via RESP protocol; no native Valkey awareness |
| **node-redis** | - | Redis-maintained | Compatible | Works by endpoint swap; long-term compat uncertain |
| **Valkey GLIDE** | 2.1.1 | Official | Native | See valkey-glide skill |

**Migration**: For dedicated Valkey support, switch from `ioredis` to `iovalkey` (API-compatible fork). For existing ioredis/node-redis users, changing the server endpoint is sufficient.

### 1.4 Java

| Client | Version | Type | Valkey Status | Notes |
|--------|---------|------|---------------|-------|
| **valkey-java** | 5.3.0 | Official Valkey fork | Native | Fork of Jedis; simplicity and high performance focused |
| **Jedis** | - | Redis-maintained | Compatible | Works via RESP; AWS recommends for ElastiCache |
| **Lettuce** | 6.2.2+ | Community | Compatible | Async/reactive; works with Valkey; recommended for ElastiCache |
| **Redisson** | 3.48.0 | Community | Native | 50+ distributed Java objects; Spring/Hibernate/JCache integration |
| **Valkey GLIDE** | 2.1.1 | Official | Native | Includes Jedis compatibility layer; see valkey-glide skill |

**Redisson** deserves special mention - it provides distributed locks, maps, queues, semaphores, bloom filters, and integrates with Spring, Hibernate, MyBatis, JCache, Quarkus, Micronaut, and Helidon. It explicitly supports both Valkey and Redis.

### 1.5 Go

| Client | Version | Type | Valkey Status | Notes |
|--------|---------|------|---------------|-------|
| **valkey-go** | 1.0.67 | Official | Native | Auto-pipelining; built for Valkey from the ground up |
| **go-redis** | - | Community | Compatible | Works via RESP protocol |
| **Valkey GLIDE** | 2.1.1 | Official | Native | Public preview (March 2025); see valkey-glide skill |

### 1.6 Rust

| Client | Version | Type | Valkey Status | Notes |
|--------|---------|------|---------------|-------|
| **redis-rs** | - | Community | Compatible | Explicitly supports Valkey in docs; GLIDE core is built on it |

No dedicated Valkey Rust client binding exists yet. GLIDE's core is written in Rust but does not expose a Rust-language binding. redis-rs remains the recommended choice for Rust applications.

### 1.7 .NET / C#

| Client | Version | Type | Valkey Status | Notes |
|--------|---------|------|---------------|-------|
| **StackExchange.Redis** | - | Community | Compatible | Explicitly lists Valkey; added `GetProductVariant` for Valkey detection; multi-DB on Valkey clusters |
| **Valkey GLIDE (C#)** | preview | Official | Native | API-compatible with StackExchange.Redis v2.8.58 |

### 1.8 Other Languages

| Language | Client | Version | Notes |
|----------|--------|---------|-------|
| PHP | phpredis | 6.1.0 | C extension; recommended for Valkey |
| PHP | Predis | 2.3.0 | Pure PHP; feature-complete |
| Swift | valkey-swift | 1.0.0 | Official; released Feb 2026 |
| Scala | valkey4cats | - | Built on Lettuce + Cats Effect + Fs2 |
| C | hiredis-cluster | - | Maintained by Ericsson/Nordix for Valkey/Redis Cluster |

---

## 2. Modules and Extensions

Valkey supports a module system compatible with Redis modules built for Redis 7.2. The Valkey project has developed official BSD-licensed modules to replace proprietary Redis Stack modules.

### 2.1 Valkey Bundle

The **valkey-bundle** container packages Valkey with all official modules in a single image:

```
docker pull valkey/valkey-bundle
```

Includes (as of v8.1):
- valkey-json 1.0
- valkey-bloom 1.0
- valkey-search 1.0
- valkey-ldap 1.0

### 2.2 Module Status

| Module | Valkey Status | Version | Redis Equivalent | Compatibility |
|--------|--------------|---------|------------------|---------------|
| **JSON** | GA | 1.0.0 (Apr 2025) | RedisJSON | API + RDB compatible with RedisJSON v1/v2; drop-in replacement |
| **Bloom** | GA | 1.0.0 (Apr 2025) | RedisBloom | API compatible with `BF.*` commands from Redis Bloom |
| **Search** (Vector) | Beta, GA expected Q2 2026 | 1.0.0 | RediSearch (partial) | Vector similarity search only; not full-text search. Google-contributed |
| **LDAP** | GA | 1.0.0 (Jun 2025) | N/A | Enterprise auth; new to Valkey |
| **TimeSeries** | No official module | - | RedisTimeSeries | Community-maintained `redistimeseries.so` built for Redis 7.2 works on Valkey 7.2; no official Valkey module yet |
| **Graph** | Not available | - | RedisGraph | RedisGraph was EOL'd Jan 2025 by Redis Inc. No Valkey equivalent. Consider Memgraph or FalkorDB |

### 2.3 Module Details

**valkey-json** - Native JSON data type with JSONPath query language. Supports both restricted (RedisJSON v1 compatible) and enhanced (Goessner-style) JSONPath syntax. RDB-compatible with RedisJSON v1.0.8+ and v2.

**valkey-bloom** - Bloom filters as a native data type. Supports scalable and non-scalable variants. Written in Rust. Commands: `BF.ADD`, `BF.EXISTS`, `BF.MEXISTS`, `BF.MADD`, `BF.CARD`, `BF.RESERVE`, `BF.INFO`, `BF.INSERT`, `BF.LOAD`.

**valkey-search** - Vector similarity search contributed by Google Cloud. Supports KNN (exact) and HNSW (approximate) nearest-neighbor algorithms. Single-digit millisecond latency at 99%+ recall on billions of vectors. Indexes Hash and JSON data types. Supports hybrid queries combining vector search with numeric/tag filters.

### 2.4 Key Gaps vs Redis Stack

| Feature | Redis 8 | Valkey 9 | Notes |
|---------|---------|----------|-------|
| Full-text search | Bundled in core | Vector search only (beta) | valkey-search focuses on vector similarity, not full-text |
| Time series | Bundled in core | No official module | Use Sorted Sets or external redistimeseries.so |
| Graph | EOL (was RedisGraph) | Not available | Neither platform supports graph natively now |
| Probabilistic (Bloom, etc.) | Bundled in core | valkey-bloom module | Feature parity for bloom filters |
| JSON | Bundled in core | valkey-json module | Feature parity |

---

## 3. Managed Services

### 3.1 Major Cloud Providers

| Provider | Service | Valkey Versions | Key Features |
|----------|---------|-----------------|--------------|
| **AWS ElastiCache** | ElastiCache for Valkey | 7.2, 8.x | Serverless + node-based; 33% cheaper serverless, 20% cheaper node vs Redis; GLIDE AZ-affinity |
| **AWS MemoryDB** | MemoryDB for Valkey | 7.2+ | Durable in-memory with transaction log; multi-AZ |
| **Google Cloud** | Memorystore for Valkey | 7.2, 8.0, 9.0 | 99.99% SLA; vector search built-in; 1-250 nodes; cross-region replication |
| **Akamai** | Managed Database (Valkey) | - | Announced; details emerging |

### 3.2 Platform Providers

| Provider | Service | Valkey Versions | Key Features |
|----------|---------|-----------------|--------------|
| **Aiven** | Aiven for Valkey | 7.2, 8.x, 9.0 | Multi-version support; free tier; multi-cloud (AWS/GCP/Azure); 24h auto backups |
| **DigitalOcean** | Managed Valkey | 7.2+ | Replaces Managed Redis; from $15/mo single node; HA from $30/mo |
| **Heroku** | Key-Value Store | 8.x | Built on Valkey; JSON + Bloom modules; HIPAA-compliant Shield plan; performance analytics |
| **Percona** | Support for Valkey | All | Enterprise support, consulting, migration services; not a hosted service but managed support |
| **UpCloud** | Managed Valkey | - | GDPR-compliant EU cloud |
| **Exoscale** | DBaaS Valkey | - | Terraform provider support |
| **Yandex Cloud** | Managed Service for Valkey | - | Terraform reference available |

### 3.3 Cost Comparison (AWS)

- ElastiCache Serverless for Valkey: **33% cheaper** than ElastiCache Serverless for Redis OSS
- Node-based ElastiCache for Valkey: **20% cheaper** than other node-based ElastiCache engines
- Google Memorystore: 20% savings with 1-year commit, 40% with 3-year commit

### 3.4 Notable Absences

- **Upstash**: No Valkey support as of early 2026. Remains Redis-only with their serverless model.
- **Azure Cache for Redis**: No Valkey support announced. Microsoft maintains Azure Managed Redis.

---

## 4. Monitoring and Observability

### 4.1 Prometheus + Grafana

**redis_exporter** (oliver006/redis_exporter) - The standard Prometheus exporter for Valkey and Redis metrics.
- Supports Valkey 7.x, 8.x, 9.x
- Exposes metrics on port 9121
- Covers memory, connections, commands, replication, keyspace stats
- Repo: [oliver006/redis_exporter](https://github.com/oliver006/redis_exporter)

**Grafana Dashboards** - Pre-built dashboards available:
- Valkey monitoring dashboard (ID: 24733) on Grafana Labs
- Numerous Redis dashboards work with Valkey unchanged

### 4.2 Monitoring Platforms

| Platform | Valkey Support | Notes |
|----------|---------------|-------|
| **Percona PMM** | Yes | Uses VictoriaMetrics (Prometheus-compatible); dedicated Valkey monitoring |
| **Datadog** | Via Redis integration | Redis integration works with Valkey; 500+ integrations |
| **New Relic** | Via Redis integration | Redis APM integration detects Valkey endpoints |

### 4.3 GUI Tools

| Tool | Type | Valkey Support | Key Features |
|------|------|---------------|--------------|
| **Redimo** | Desktop (Win/Mac/Linux) | Native (auto-detects) | Real-time monitoring; data visualization; production-safe editing |
| **Keyscope** | Desktop + JetBrains plugin | Native (Valkey 9 multi-DB cluster) | Lightweight; read-only mode; connection recovery |
| **Another Redis Desktop Manager (ARDM)** | Desktop | Compatible | Open source; SSH tunnels; Cluster/Sentinel; Mac/Windows Store |
| **Redis Commander** | Web UI (Docker/self-hosted) | Compatible | Lightweight; multi-connection; Cluster/Sentinel |
| **P3X Redis UI** | Web + Electron desktop | Compatible | JSON editing; versatile deployment |

**Note**: RedisInsight (by Redis Inc.) may have reduced compatibility with future Valkey versions as the projects diverge. Redimo and Keyscope are the most Valkey-aware GUI tools.

### 4.4 Kubernetes Monitoring

- **PodMonitor CRD** for Prometheus Operator with redis_exporter sidecar
- **VMware Tanzu** for Valkey on Kubernetes includes built-in monitoring
- Official Valkey Helm chart supports metrics export configuration

### 4.5 Future: Native OBSERVE Command

A proposed `OBSERVE` command suite (RFC on GitHub) would bring observability as a core Valkey feature through user-defined observability pipelines, producing structured insights natively.

---

## 5. Frameworks and Integrations

### 5.1 Spring Ecosystem (Java)

**Spring Data Valkey** - Official first-class Valkey integration, forked from Spring Data Redis 3.5.1.

- **Repo**: [valkey-io/spring-data-valkey](https://github.com/valkey-io/spring-data-valkey)
- **Latest**: v0.2.0 (Jan 2026)
- **Maven**: `io.valkey.springframework.data:spring-data-valkey`
- **Spring Boot Starter**: `io.valkey.springframework.boot:spring-boot-starter-data-valkey`
- **Features**:
  - ValkeyTemplate with serialization support
  - Pub/Sub with MessageListenerContainer
  - Reactive API via Lettuce
  - OpenTelemetry instrumentation with GLIDE client
  - Spring Boot Actuator health indicators and metrics
  - `@DataValkeyTest` slice test annotation
  - Testcontainers integration with `@ServiceConnection`
  - Docker Compose service detection

**Spring Data Redis** also works with Valkey without changes - just point the connection at a Valkey server.

### 5.2 Django (Python)

**django-valkey** - Full-featured cache and session backend for Django.

- **Repo**: [django-commons/django-valkey](https://github.com/django-commons/django-valkey)
- **Install**: `pip install django-valkey`
- **Backend**: `django_valkey.cache.ValkeyCache`
- **URL scheme**: `valkey://127.0.0.1:6379`
- **Features**: ACL auth, cluster backend, bz2/brotli compressors, `IGNORE_EXCEPTIONS` setting
- Fork of django-redis with Valkey-native improvements

**django-redis** also works with Valkey by changing only the server endpoint (using `redis://` scheme).

### 5.3 Rails (Ruby)

- **Sidekiq 8.0+** officially supports Valkey 7.2+ (announced March 2025)
- Rails `ActiveSupport::Cache::RedisCacheStore` works with Valkey by endpoint change
- `redis-rails` gem works unchanged with Valkey
- No dedicated `valkey-rails` gem exists yet

### 5.4 Queue Frameworks

| Framework | Language | Valkey Status | Notes |
|-----------|----------|---------------|-------|
| **Sidekiq** | Ruby | Official support | v8.0+ supports Valkey 7.2+ |
| **BullMQ** | Node.js | Compatible | Works with Valkey as drop-in Redis replacement; Valkey GLIDE integration requested |
| **Celery** | Python | Partial | Works with `redis://` scheme; native `valkey://` transport not yet in kombu; `celery[valkey]` bundle requested |
| **RQ (Redis Queue)** | Python | Compatible | Works via endpoint change |

**Celery caveat**: Celery works with Valkey using the `redis://` URL scheme, but switching to `valkey://` breaks celery-beat. The Celery team has an open issue for native Valkey transport support.

### 5.5 ORM and Caching Integrations

| Framework | Valkey Support | Mechanism |
|-----------|---------------|-----------|
| **Hibernate (via Redisson)** | Yes | Redisson provides Hibernate second-level cache backed by Valkey |
| **JCache (JSR-107)** | Yes | Redisson implements JCache with Valkey backend |
| **Spring Cache** | Yes | Via Spring Data Valkey or Spring Data Redis |
| **Keyv** | Yes | `@keyv/valkey` adapter using iovalkey |

---

## 6. Developer Tools

### 6.1 CLI Tools

**valkey-cli** - Interactive command-line interface for Valkey servers.
- Command history (stored in `~/.valkeycli_history`)
- Cluster mode with automatic node redirection
- Bulk command execution via stdin pipelining
- Latency monitoring mode
- Stat mode for real-time server stats
- Pub/Sub message monitoring

**valkey-server** - The server binary, drop-in replacement for redis-server.

### 6.2 Benchmarking

**valkey-benchmark** - Built-in load testing and performance measurement tool.
- Multi-threaded execution
- Cluster and standalone modes
- HDR histogram latency distribution
- Pipelining and rate limiting
- Custom command benchmarks via `-t` flag
- Configurable number of virtual clients

**valkey-perf-benchmark** - Advanced benchmarking tool from the Valkey project.
- Repo: [valkey-io/valkey-perf-benchmark](https://github.com/valkey-io/valkey-perf-benchmark)
- TLS and cluster mode benchmarking
- Cross-configuration comparison

### 6.3 Testing Tools

**Testcontainers** - Lightweight, throwaway Valkey instances for integration testing.

| Language | Package | Status |
|----------|---------|--------|
| Java | Testcontainers Valkey module | GA |
| Go | `testcontainers.org/modules/valkey` | GA |
| Node.js | `@testcontainers/valkey` (v11.13.0) | GA |
| Rust | `testcontainers_modules` crate | GA |
| Elixir | testcontainers-elixir | GA |

Features include TLS support, snapshotting configuration, and cluster mode testing.

**Spring Data Valkey Test Support**:
- `@DataValkeyTest` slice test annotation
- `@ServiceConnection` for Testcontainers auto-wiring
- Docker Compose service detection

### 6.4 Infrastructure as Code

**Terraform** support across providers:
- **AWS**: ElastiCache for Valkey via `terraform-provider-aws`; Gruntwork module available
- **Azure**: AKS-based Valkey clusters via Azure Verified Modules
- **Exoscale**: Native Valkey DBaaS in Terraform provider
- **Yandex Cloud**: Managed Service for Valkey Terraform reference
- **Modules**: `terraform-aws-modules/memory-db/aws` supports Valkey

**Helm Charts**:
- **Official Valkey Helm Chart**: Project-maintained; standalone and primary-replica topologies; recommended over Bitnami since Aug 2025
- **Bitnami**: Valkey and Valkey Cluster charts available (require commercial subscription since Aug 2025)

---

## 7. Migration from Redis

### 7.1 Server Compatibility

| Source | Target | Method |
|--------|--------|--------|
| Redis OSS <= 7.2 | Valkey 7.2.x or 8.0.x | Direct migration via RDB snapshot or replication |
| Redis 7.4+ | Valkey | Not supported (post-fork divergence) |

### 7.2 Migration Methods

1. **RDB Snapshot**: Run `BGSAVE` on Redis, copy `.rdb` to Valkey data directory, start Valkey
2. **Replication**: Point Valkey at Redis with `REPLICAOF`, sync, then promote with `REPLICAOF NO ONE`
3. **Endpoint Swap**: For most clients, change only the connection URL

### 7.3 Client Migration Matrix

| From | To | Effort |
|------|----|--------|
| redis-py | valkey-py | Change import; or just change endpoint |
| ioredis | iovalkey | npm package swap; API-compatible |
| Jedis | valkey-java | Drop-in; or use GLIDE Jedis compat layer |
| go-redis | valkey-go | API differences exist; migration guide available |
| StackExchange.Redis | Valkey GLIDE C# | API-compatible with SE.Redis v2.8.58; or just change endpoint |

---

## 8. Valkey 9.0 Highlights

Released October 2025, Valkey 9.0 brings significant improvements:

- **Performance**: Up to 40% higher throughput vs 8.1; zero-copy responses; memory prefetching; MPTCP; AVX-512 SIMD (19% faster string parsing)
- **Scalability**: 1 billion+ RPS clusters; up to 2,000 nodes
- **Atomic slot migration**: Entire slots move atomically (AOF format) instead of key-by-key
- **Hash field expiration**: Individual hash fields can expire independently
- **Multi-DB clustering**: Numbered databases in cluster mode for namespace isolation
- **Official modules**: JSON, Bloom, Search (vector), LDAP bundled in valkey-bundle

---

## 9. Quick Reference

### Which client should I use?

| Language | Recommended | Alternative |
|----------|-------------|-------------|
| Python | valkey-py or GLIDE | redis-py (endpoint swap) |
| Node.js | iovalkey or GLIDE | ioredis (endpoint swap) |
| Java | valkey-java, GLIDE, or Redisson | Jedis/Lettuce (endpoint swap) |
| Go | valkey-go or GLIDE | go-redis (endpoint swap) |
| Rust | redis-rs | - |
| .NET | StackExchange.Redis or GLIDE C# | - |
| PHP | phpredis or Predis | - |

### Which managed service?

| Use Case | Recommendation |
|----------|---------------|
| AWS, cost-sensitive | ElastiCache for Valkey (20-33% cheaper than Redis) |
| AWS, durability needed | MemoryDB for Valkey |
| Google Cloud | Memorystore for Valkey (built-in vector search) |
| Multi-cloud | Aiven for Valkey |
| Simple PaaS | Heroku Key-Value Store |
| Budget | DigitalOcean Managed Valkey ($15/mo) |
| EU/GDPR | UpCloud Managed Valkey |

### Do I need modules?

| Need | Solution |
|------|----------|
| JSON documents | valkey-json (or valkey-bundle container) |
| Bloom filters | valkey-bloom (or valkey-bundle) |
| Vector search | valkey-search (or Google Memorystore) |
| Full-text search | Not available in Valkey; consider Elasticsearch/OpenSearch |
| Time series | No official module; use Sorted Sets or external redistimeseries.so |
| Graph | Not available; consider FalkorDB or Memgraph |
