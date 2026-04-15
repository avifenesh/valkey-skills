# What Is Valkey

Use when you need to understand what Valkey is, licensing, and what features differentiate it from Redis 8+.

Valkey forked from Redis 7.2.4 in March 2024 after Redis switched to RSALv2/SSPL. BSD 3-clause, governed by the Linux Foundation. Full wire/protocol compatibility with Redis OSS 7.2.

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

I/O multithreading (8.0), pipeline memory prefetch, zero-copy responses, MPTCP, SIMD for BITCOUNT/HyperLogLog (9.0). See `valkey-features-performance-summary.md` for version-by-version details.

---

## Features only in Redis 8+

Built-in full-text search, vector search, time series, extended probabilistic structures. Valkey covers search/vector via valkey-search, bloom via valkey-bloom, JSON via valkey-json. Time series has no Valkey equivalent today.

---

## Version History

| Version | Release | Highlights |
|---------|---------|------------|
| 7.2.x | Inherited | Baseline fork from Redis 7.2.4. Full Redis OSS compatibility. |
| 8.0 | 2024 | I/O multithreading overhaul (3x throughput), dual-channel replication, command batching. |
| 8.1 | 2025 | SET IFEQ, new hashtable (20-30 bytes/key savings), COMMANDLOG, TLS I/O offload, iterator prefetch. |
| 9.0 | 2025 | DELIFEQ, hash field TTL (11 commands), numbered databases in cluster, atomic slot migration, polygon geo queries. Performance: 1B RPS across 2,000 nodes, pipeline memory prefetch (40% higher throughput), zero-copy responses (20% gain), MPTCP (25% latency reduction), SIMD for BITCOUNT/HyperLogLog (200% gain). Un-deprecated 25 commands. |
| 9.1 | 2025 | HGETDEL (atomic get-and-delete for hash fields). |


