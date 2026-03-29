# What Is Valkey

Use when you need to understand what Valkey is, how it relates to Redis, its licensing, governance, and what differentiates it from Redis 8+.

---

## Overview

Valkey is a high-performance, open-source, in-memory key-value data store. It was forked from Redis 7.2.4 in March 2024 after Redis switched from BSD to a source-available license (RSALv2/SSPL). Valkey is governed by the Linux Foundation and uses the permissive BSD 3-clause license.

The fork preserves full compatibility with Redis OSS through version 7.2 while adding its own features and performance improvements in subsequent releases.

---

## Key Facts

| Property | Value |
|----------|-------|
| License | BSD 3-clause (fully open source) |
| Governance | Linux Foundation |
| Forked from | Redis 7.2.4 (March 2024) |
| Latest versions | 8.1.x (stable), 9.0.x (latest) |
| Protocol | RESP2 / RESP3 (fully compatible) |
| Contributors | 346+ active contributors |
| Default port | 6379 (same as Redis) |

---

## What Valkey Has That Redis 8+ Does Not

### Open source license

Valkey is BSD 3-clause - no usage restrictions, no source-available caveats. You can embed it, fork it, resell it, and modify it without permission. Redis 8+ uses RSALv2/SSPL, which restricts competitive use.

### Valkey-only features (not in Redis)

| Feature | Version | Description |
|---------|---------|-------------|
| SET IFEQ | 8.1+ | Conditional update - set a value only if current value matches |
| DELIFEQ | 9.0+ | Conditional delete - delete only if value matches |
| Hash field expiration | 9.0+ | Per-field TTL on hash entries (11 new commands) |
| Numbered databases in cluster | 9.0+ | SELECT 0-15 works in cluster mode |
| Atomic slot migration | 9.0+ | Entire slots migrate atomically, not key by key |
| Polygon geospatial queries | 9.0+ | GEOSEARCH BYPOLYGON support |
| HGETDEL | 9.1+ | Get hash field values and delete them atomically |
| COMMANDLOG | 8.1+ | Extended slow log tracking large requests and replies |

### Performance leadership

Valkey 8.0 tripled throughput to 1.2M requests per second via enhanced I/O multithreading. Valkey 9.0 reaches 1 billion RPS across 2,000 cluster nodes. These gains come from architectural improvements in I/O threading, pipeline prefetch, zero-copy responses, and SIMD optimizations.

---

## What Redis 8+ Has That Valkey Does Not

Redis 8 added proprietary features that are not available in Valkey:

| Feature | Description |
|---------|-------------|
| Redis Query Engine | Full-text search and secondary indexing |
| Vector search | Similarity search for embeddings |
| Time series | Built-in time series data type |
| Probabilistic data structures | Extended bloom filters, count-min sketch, top-k |

If you need these capabilities, your options are:

1. **Valkey modules** - the module API supports custom data types. Community modules may provide equivalents.
2. **External tools** - pair Valkey with dedicated search (Meilisearch, Typesense), vector (pgvector, Qdrant), or time series (TimescaleDB) systems.
3. **Lua scripting** - some lightweight use cases can be handled with Valkey Functions.

---

## When to Choose Valkey

- You need an open-source license with no restrictions
- You are running Redis OSS 7.2 or earlier and want a supported upgrade path
- You want features like conditional SET/DELETE, hash field TTL, or cluster database selection
- You need the performance improvements in 8.x and 9.x
- You want Linux Foundation governance and community-driven development

## When Redis 8+ Might Be Better

- You need built-in vector search or full-text search
- You rely on Redis Stack modules (RedisSearch, RedisJSON, RedisTimeSeries) and cannot find Valkey equivalents
- Your organization has a Redis Enterprise agreement that covers these features

---

## Version History

| Version | Release | Highlights |
|---------|---------|------------|
| 7.2.x | Inherited | Baseline fork from Redis 7.2.4. Full Redis OSS compatibility. |
| 8.0 | 2024 | I/O multithreading overhaul (3x throughput), dual-channel replication, command batching. |
| 8.1 | 2025 | SET IFEQ, new hashtable (20-30 bytes/key savings), COMMANDLOG, TLS I/O offload, iterator prefetch. |
| 9.0 | 2025 | DELIFEQ, hash field TTL (11 commands), HGETDEL (9.1), numbered databases in cluster, atomic slot migration, polygon geo queries. Performance: 1B RPS across 2,000 nodes, pipeline memory prefetch (40% higher throughput), zero-copy responses (20% gain), MPTCP (25% latency reduction), SIMD for BITCOUNT/HyperLogLog (200% gain). Un-deprecated 25 commands. |

---

## Community and Ecosystem

- **GitHub**: [github.com/valkey-io/valkey](https://github.com/valkey-io/valkey)
- **Official client**: Valkey GLIDE (Rust core, bindings for Java, Python, Node.js, Go, C#, PHP)
- **Cloud providers**: AWS ElastiCache and MemoryDB support Valkey, as do other providers
- **Module compatibility**: Redis modules load in Valkey via the compatible module API
- **Existing tooling**: redis-benchmark, redis-cli patterns, RDB tools, and monitoring exporters work with Valkey

---

## See Also

- [Compatibility and Migration](compatibility.md) - detailed migration guide
- [Performance Summary](../valkey-features/performance-summary.md) - version-by-version improvements
- [Conditional Operations](../valkey-features/conditional-ops.md) - SET IFEQ, DELIFEQ, and more
- [Clients Overview](../clients/overview.md) - GLIDE and existing Redis client compatibility
- For operational deployment: see valkey-ops skill (deployment, configuration, monitoring)
