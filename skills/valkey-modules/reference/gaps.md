# Module Gaps - Valkey vs Redis Stack

Use when evaluating whether Valkey covers your module needs, understanding what is missing compared to Redis Stack or Redis 8, or finding alternatives for unsupported features.

## Contents

- Feature Comparison: Redis 8 vs Valkey 9 (line 16)
- Major Gaps (line 33)
- Minor Gaps (line 103)
- Where Valkey Has No Gap (or Leads) (line 118)
- Decision Guide (line 134)

---

## Feature Comparison: Redis 8 vs Valkey 9

| Feature | Redis 8 | Valkey 9 | Gap? |
|---------|---------|----------|------|
| JSON documents | Bundled in core | valkey-json module (GA) | No - feature parity |
| Bloom filters | Bundled in core | valkey-bloom module (GA) | No - feature parity |
| Vector similarity search | Bundled in core | valkey-search module (GA) | No - feature parity |
| Full-text search | Bundled in core | valkey-search 1.2.0+ (GA) | Mostly closed - minor gaps remain (phonetic, autocomplete) |
| Aggregation pipelines | Bundled in core | valkey-search FT.AGGREGATE (GA) | No - added in 1.1.0 |
| Time series | Bundled in core | **No official module** | **Yes** |
| Graph | EOL (was RedisGraph) | Not available | No - neither platform supports it |
| Cuckoo filters | Bundled in core | Not available | Yes - minor |
| Count-Min Sketch | Bundled in core | Not available | Yes - minor |
| Top-K | Bundled in core | Not available | Yes - minor |
| t-digest | Bundled in core | Not available | Yes - minor |
| LDAP authentication | Not available | valkey-ldap module (GA) | Redis gap - Valkey-only feature |

## Major Gaps

### Full-Text Search - RESOLVED

**Status**: Available since valkey-search 1.2.0. Requires Valkey 9.0.1+.

valkey-search 1.2.0 added full-text search with keyword, phrase, prefix, suffix, wildcard, and fuzzy (typo-tolerant) queries. It also supports tag search for categorical filtering, numeric range queries, and hybrid queries combining text, tag, numeric, and vector dimensions in a single request. FT.AGGREGATE (added in 1.1.0) provides server-side GROUPBY, REDUCE, APPLY, FILTER, and SORTBY.

This was previously the single largest functional gap between Valkey and Redis 8. It is now closed for most use cases.

**Remaining search gaps vs RediSearch**: Phonetic matching, auto-complete/suggestions, and FT.CURSOR are not yet available. Stemming is now supported (use NOSTEM on fields where stemming should be disabled).

**When you still need an external search service**: If your workload requires phonetic matching or auto-complete suggestions, pair Valkey with a dedicated search engine until these features land in valkey-search.

| Alternative | Type | Notes |
|-------------|------|-------|
| Elasticsearch / OpenSearch | External service | Full-featured; needed for phonetic matching and language analysis |
| Meilisearch | External service | Lightweight, typo-tolerant; good for smaller datasets |
| Typesense | External service | Fast, good developer experience |

### Time Series

**Status**: No official Valkey module.

There is no valkey-timeseries module. The community-maintained `redistimeseries.so` (built for Redis 7.2) works on Valkey 7.2, but it is not officially supported by the Valkey project and may break with future Valkey versions.

**Alternatives**:

| Alternative | Type | Notes |
|-------------|------|-------|
| Valkey Sorted Sets | Core feature | Store timestamps as scores, values as members. Works for simple time series with range queries (`ZRANGEBYSCORE`). No built-in downsampling or aggregation |
| `redistimeseries.so` | Community module | Built for Redis 7.2; works on Valkey 7.2. Not guaranteed to work on Valkey 8+ |
| TimescaleDB | External service | PostgreSQL extension; mature, full-featured time series |
| InfluxDB | External service | Purpose-built time series database |
| Prometheus | External service | Metrics-focused; good for monitoring use cases |
| QuestDB | External service | High-performance time series with SQL interface |

**Sorted Set pattern for simple time series**:

```
# Add a data point (timestamp as score, value as member)
ZADD sensor:temp:room1 1711756800 "22.5:1711756800"

# Query a time range
ZRANGEBYSCORE sensor:temp:room1 1711756800 1711843200

# Count points in a range
ZCOUNT sensor:temp:room1 1711756800 1711843200

# Remove old data (retention)
ZREMRANGEBYSCORE sensor:temp:room1 -inf 1711670400
```

This approach works for simple use cases but lacks automatic downsampling, aggregation functions (avg, min, max over windows), and compaction rules that a dedicated time series module provides.

### Graph

**Status**: Not available on either platform.

RedisGraph was end-of-lifed by Redis Inc. in 2023. There is no Valkey equivalent and no plans for one. Graph workloads have moved to dedicated graph databases.

**Alternatives**:

| Alternative | Type | Notes |
|-------------|------|-------|
| FalkorDB | External service | Fork of RedisGraph; actively maintained; compatible API |
| Memgraph | External service | High-performance in-memory graph database |
| Neo4j | External service | Mature, full-featured graph database |
| Apache AGE | PostgreSQL extension | Graph queries on PostgreSQL |

## Minor Gaps

### Probabilistic Data Structures Beyond Bloom

Redis 8 bundles several probabilistic data structures that Valkey does not have:

| Structure | Redis 8 | Valkey 9 | Workaround |
|-----------|---------|----------|------------|
| Cuckoo filter | `CF.*` commands | Not available | Use Bloom filter (similar purpose, different trade-offs) |
| Count-Min Sketch | `CMS.*` commands | Not available | Implement in application code or use HyperLogLog for cardinality |
| Top-K | `TOPK.*` commands | Not available | Use Sorted Sets with periodic pruning |
| t-digest | `TDIGEST.*` commands | Not available | Compute percentiles in application code |

These are niche data structures. Most applications do not need them, and reasonable workarounds exist using core Valkey features.

## Where Valkey Has No Gap (or Leads)

| Feature | Notes |
|---------|-------|
| JSON | valkey-json is a drop-in replacement for RedisJSON |
| Bloom filters | valkey-bloom is API-compatible with Redis Bloom BF.* commands |
| Vector search | valkey-search GA - vector similarity with HNSW and FLAT |
| Full-text search | valkey-search 1.2.0 - keyword, phrase, prefix, suffix, wildcard, fuzzy |
| Aggregation | valkey-search FT.AGGREGATE - GROUPBY, REDUCE, APPLY, FILTER, SORTBY |
| LDAP auth | valkey-ldap has no Redis equivalent - Valkey-only |
| Performance | Valkey 9 achieves up to 40% higher throughput than Valkey 8.1 |
| Cluster scale | Up to 2,000 nodes, 1B+ RPS |
| Hash field expiration | Native in Valkey 9, added to Redis 7.4 |
| Multi-DB clustering | Native in Valkey 9, not available in Redis |
| Atomic slot migration | Valkey 9 moves slots atomically, Redis does key-by-key |

## Decision Guide

| Your Need | Recommendation |
|-----------|---------------|
| JSON + Bloom + Vector + Full-text search | Valkey with modules covers this fully (valkey-search 1.2.0+) |
| Phonetic matching, auto-complete | Add Elasticsearch/OpenSearch alongside Valkey (not yet in valkey-search) |
| Time series with downsampling | Add TimescaleDB/InfluxDB; or use Sorted Sets for simple cases |
| Graph queries | Use FalkorDB, Neo4j, or Memgraph as a separate service |
| Cuckoo/CMS/TopK/t-digest | Evaluate if you truly need these; workarounds exist |
| Cost-sensitive, Redis-compatible | Valkey uses the BSD license. AWS ElastiCache pricing differs between Valkey and Redis engines - check current AWS pricing |

