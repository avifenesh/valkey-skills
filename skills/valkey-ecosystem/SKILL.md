---
name: valkey-ecosystem
description: "Use when evaluating the Valkey ecosystem - client libraries, modules (JSON, Bloom, Search), managed services (AWS, GCP, Aiven), monitoring tools, frameworks (Spring, Django, Rails), Docker/Kubernetes deployment, CI/CD patterns, migration from Redis, and developer tooling."
version: 1.0.0
last-verified: 2026-03-30
argument-hint: "[tool, service, or module name]"
---

# Valkey Ecosystem Reference

28 web-verified reference docs mapping the Valkey ecosystem - clients, modules, managed services, monitoring, frameworks, and developer tools. All versions, URLs, and feature claims verified against official project sites and cloud provider documentation.

Browse by topic below. Each link leads to a focused reference with comparison tables, decision frameworks, and practical guidance.

## Routing

- Which client for my language? -> Clients (Landscape)
- Python/valkey-py/redis-py -> Clients (Python)
- Node.js/iovalkey/ioredis -> Clients (Node.js)
- Java/Jedis/Lettuce/Redisson -> Clients (Java)
- Go/Rust/.NET/PHP/Swift/C/libvalkey -> Clients (Other Languages)
- Module system/valkey-bundle/custom modules/Rust SDK -> Modules (Overview)
- JSON documents/JSONPath/RedisJSON -> Modules (JSON)
- Bloom filters/probabilistic/BF.ADD/BF.EXISTS -> Modules (Bloom)
- Vector search/full-text search/KNN/HNSW/FT.SEARCH -> Modules (Search)
- What's missing vs Redis Stack/Redis 8? -> Modules (Gaps)
- AWS ElastiCache/MemoryDB -> Services (AWS)
- Google Cloud Memorystore -> Services (GCP)
- Aiven/DigitalOcean/Heroku/Percona/UpCloud -> Services (Platform Providers)
- Which managed service?/cost comparison -> Services (Comparison)
- Prometheus/Grafana/redis_exporter/alerts -> Monitoring (Prometheus)
- Datadog/New Relic/Percona PMM -> Monitoring (Platforms)
- GUI tools/desktop clients/Redis Commander -> Monitoring (GUI Tools)
- Message queues/glide-mq/job processing/workers -> Tools (Frameworks)
- Spring Boot/Django/Rails/Sidekiq/BullMQ/Celery -> Tools (Frameworks)
- Docker/Compose/containers/valkey-bundle -> Tools (Docker)
- Kubernetes/operators/Helm/StatefulSet -> Tools (Kubernetes)
- GitHub Actions/GitLab CI/service containers -> Tools (CI/CD)
- Terraform/Helm charts/infrastructure as code -> Tools (IaC)
- Testcontainers/integration tests/@DataValkeyTest -> Tools (Testing)
- valkey-cli/valkey-benchmark/valkey-perf-benchmark -> Tools (CLI)
- Redis to Valkey migration/RDB/replication swap -> Tools (Migration)
- Supply chain/security/SBOM/OpenSSF/CVE -> Tools (Security)
- AI/ML/RAG/vector store/semantic caching -> Tools (AI/ML)
- Community/Discord/governance/TSC/RFC -> Community


## Clients

| Topic | Reference |
|-------|-----------|
| Decision framework: which client for which language and use case | [landscape](reference/clients/landscape.md) |
| Python: valkey-py, redis-py compatibility, GLIDE, Django/Celery | [python](reference/clients/python.md) |
| Node.js: iovalkey, ioredis/node-redis, GLIDE, BullMQ/Keyv | [nodejs](reference/clients/nodejs.md) |
| Java: valkey-java, Jedis, Lettuce, Redisson, GLIDE, Spring | [java](reference/clients/java.md) |
| Go, Rust, .NET, PHP, Swift, Scala, C, libvalkey | [other-languages](reference/clients/other-languages.md) |


## Modules

| Topic | Reference |
|-------|-----------|
| Module system, valkey-bundle, loading modules, custom module SDK | [overview](reference/modules/overview.md) |
| valkey-json: native JSON data type, JSONPath, RedisJSON compatible | [json](reference/modules/json.md) |
| valkey-bloom: probabilistic data structure, BF.* commands, Rust | [bloom](reference/modules/bloom.md) |
| valkey-search: vector + full-text search, FT.CREATE/FT.SEARCH/FT.AGGREGATE | [search](reference/modules/search.md) |
| Feature gaps vs Redis Stack/Redis 8, alternatives | [gaps](reference/modules/gaps.md) |


## Managed Services

| Topic | Reference |
|-------|-----------|
| AWS ElastiCache + MemoryDB for Valkey, pricing, when to choose | [aws](reference/services/aws.md) |
| Google Cloud Memorystore, vector search, SLA, pricing | [gcp](reference/services/gcp.md) |
| Aiven, DigitalOcean, Heroku, Percona, UpCloud, Vultr, more | [platform-providers](reference/services/platform-providers.md) |
| Decision framework: which service for which use case | [comparison](reference/services/comparison.md) |


## Monitoring

| Topic | Reference |
|-------|-----------|
| redis_exporter, Prometheus scrape config, Grafana dashboards, alerts | [prometheus-grafana](reference/monitoring/prometheus-grafana.md) |
| Percona PMM, Datadog, New Relic, self-hosted vs SaaS | [platforms](reference/monitoring/platforms.md) |
| Valkey Admin, Redimo, Keyscope, ARDM, Redis Commander | [gui-tools](reference/monitoring/gui-tools.md) |


## Developer Tools

| Topic | Reference |
|-------|-----------|
| glide-mq (Valkey-native queues), Spring Data Valkey, Django, Rails/Sidekiq, BullMQ, Celery | [frameworks](reference/tools/frameworks.md) |
| Docker images, Compose patterns, valkey-bundle, production hardening | [docker](reference/tools/docker.md) |
| Operators (official + Hyperspike), StatefulSets, sidecars, service mesh | [kubernetes](reference/tools/kubernetes.md) |
| GitHub Actions, GitLab CI, service containers, test data setup | [ci-cd](reference/tools/ci-cd.md) |
| Terraform (AWS/Azure/Exoscale/Yandex), Helm charts | [iac](reference/tools/iac.md) |
| Testcontainers (Go, Node.js, Rust, Elixir), Spring @DataValkeyTest | [testing](reference/tools/testing.md) |
| valkey-cli, valkey-benchmark, valkey-perf-benchmark | [cli-benchmarking](reference/tools/cli-benchmarking.md) |
| Redis to Valkey migration, RDB/replication/endpoint swap, client matrix | [migration](reference/tools/migration.md) |
| Supply chain verification, OpenSSF Scorecard, CVE process, valkey-ldap | [security](reference/tools/security.md) |
| Vector store for RAG, semantic caching, AI agent memory, ML features | [ai-ml](reference/tools/ai-ml.md) |


## Community

| Topic | Reference |
|-------|-----------|
| Discord, governance, TSC, RFC process, contributing, Keyspace conference | [community](reference/community.md) |
