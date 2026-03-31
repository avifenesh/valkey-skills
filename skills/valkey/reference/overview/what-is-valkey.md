# What Is Valkey

Use when you need to understand what Valkey is, how it relates to Redis, its licensing, governance, and what differentiates it from Redis 8+.

## Contents

- Overview (line 19)
- Key Facts (line 27)
- Licensing (line 40)
- What Valkey Brings (line 48)
- What Redis 8+ Brings (line 73)
- Choosing Between Them (line 88)
- Version History (line 102)
- Community and Ecosystem (line 114)
- See Also (line 124)

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
| Major versions | 8.x (LTS), 9.x (latest) |
| Protocol | RESP2 / RESP3 (fully compatible) |
| Default port | 6379 (same as Redis) |

---

## Licensing

Valkey is BSD 3-clause - no usage restrictions. You can embed it, fork it, resell it, and modify it without permission.

Redis 8+ uses RSALv2/SSPL, which restricts offering Redis as a managed service or embedding it in competing products. It does not restrict end-user application development.

---

## What Valkey Brings

### Features developed since the fork

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

### Performance work since the fork

Valkey 8.0 reached 1.2M requests per second on a single node in project benchmarks via enhanced I/O multithreading. Valkey 9.0 cluster benchmarks reached 1 billion aggregate RPS across 2,000 nodes. These come from architectural changes in I/O threading, pipeline prefetch, zero-copy responses, and SIMD optimizations. Workload and hardware details are in the linked performance summary.

### Governance

Linux Foundation project with open governance, community-driven development, and contributions from AWS, Google, Oracle, Ericsson, and others.

---

## What Redis 8+ Brings

Redis 8 developed its own feature set after the fork:

| Feature | Description |
|---------|-------------|
| Redis Query Engine | Full-text search and secondary indexing |
| Vector search | Similarity search for embeddings |
| Time series | Built-in time series data type |
| Probabilistic data structures | Extended bloom filters, count-min sketch, top-k |

Valkey covers some of these through modules (valkey-search for full-text and vector search, valkey-bloom for bloom filters, valkey-json for JSON). For time series and other gaps, see the valkey-ecosystem skill's module gaps reference.

---

## Choosing Between Them

| Consideration | Valkey | Redis 8+ |
|---------------|--------|----------|
| License | BSD 3-clause (unrestricted) | RSALv2/SSPL (managed service restrictions) |
| Governance | Linux Foundation, community-driven | Redis Ltd |
| Upgrade path from Redis OSS 7.2 | Direct compatible upgrade | License change for existing users |
| Conditional SET/DELETE, hash field TTL | Available | Not available |
| Built-in time series | Via external tools | Built-in |
| Full-text search | Via valkey-search module | Built-in |
| Vector search | Via valkey-search module | Built-in |

---

## Version History

| Version | Release | Highlights |
|---------|---------|------------|
| 7.2.x | Inherited | Baseline fork from Redis 7.2.4. Full Redis OSS compatibility. |
| 8.0 | 2024 | I/O multithreading overhaul (3x throughput), dual-channel replication, command batching. |
| 8.1 | 2025 | SET IFEQ, new hashtable (20-30 bytes/key savings), COMMANDLOG, TLS I/O offload, iterator prefetch. |
| 9.0 | 2025 | DELIFEQ, hash field TTL (11 commands), numbered databases in cluster, atomic slot migration, polygon geo queries. Performance: 1B RPS across 2,000 nodes, pipeline memory prefetch (40% higher throughput), zero-copy responses (20% gain), MPTCP (25% latency reduction), SIMD for BITCOUNT/HyperLogLog (200% gain). Un-deprecated 25 commands. |
| 9.1 | 2025 | HGETDEL (atomic get-and-delete for hash fields). |

---

## Community and Ecosystem

- **GitHub**: [github.com/valkey-io/valkey](https://github.com/valkey-io/valkey)
- **Official client**: Valkey GLIDE (Rust core, bindings for Java, Python, Node.js, Go, C#, PHP, Ruby)
- **Cloud providers**: AWS ElastiCache and MemoryDB support Valkey, as do other providers
- **Module compatibility**: Redis modules load in Valkey via the compatible module API
- **Existing tooling**: redis-benchmark, redis-cli patterns, RDB tools, and monitoring exporters work with Valkey

---

## See Also

- [Compatibility and Migration](compatibility.md) - detailed migration guide from Redis
- [Performance Summary](../valkey-features/performance-summary.md) - version-by-version throughput and latency gains
- [Conditional Operations](../valkey-features/conditional-ops.md) - SET IFEQ and DELIFEQ
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - per-field TTL on hash entries
- [Cluster Enhancements](../valkey-features/cluster-enhancements.md) - numbered databases and atomic slot migration
- [Polygon Geospatial Queries](../valkey-features/geospatial.md) - GEOSEARCH BYPOLYGON
- [String Commands](../basics/data-types.md) - SET IFEQ syntax and compare-and-swap patterns
- [Hash Commands](../basics/data-types.md) - HEXPIRE, HSETEX, HGETEX, HGETDEL command details
- [Specialized Data Types](../basics/data-types.md) - GEOSEARCH BYPOLYGON and SIMD-optimized HyperLogLog/bitmap commands
- Module Commands (see valkey-modules skill) - Bloom, JSON, and Search modules via the Valkey module API
- Clients Overview (see valkey-glide skill) - GLIDE and existing Redis client compatibility
- For operational deployment: see valkey-ops skill (deployment, configuration, monitoring)
