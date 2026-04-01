# valkey-search - Vector and Full-Text Search

Use when implementing vector similarity search, full-text search, hybrid queries combining text/tag/numeric/vector filters, aggregations, or understanding the differences between valkey-search and RediSearch.

## Contents

- Overview (line 23)
- Full-Text Search (1.2.0+) (line 44)
- Tag and Numeric Search (1.2.0+) (line 59)
- FT.AGGREGATE (1.1.0+) (line 68)
- Vector Search Algorithms (line 81)
- Performance (line 112)
- Supported Data Types (line 119)
- Index Creation (line 123)
- Query Syntax (line 169)
- Client Integration via GLIDE (line 247)
- Feature Comparison: valkey-search vs RediSearch (line 259)
- Commands (line 278)
- Use Cases (line 289)

---

## Overview

valkey-search is a search module for Valkey. Originally contributed by Google Cloud as a vector-only engine, it has evolved into a full-featured search solution. Version 1.2.0 added full-text search, tag search, numeric range queries, and server-side aggregations - making it a combined search engine comparable to RediSearch.

| Property | Value |
|----------|-------|
| Status | GA |
| License | BSD |
| Contributor | Google Cloud |
| Redis equivalent | RediSearch |
| Requires | Valkey 9.0.1+ |
| Included in | valkey-bundle container image |

### Release History

| Version | Date | Highlights |
|---------|------|------------|
| 1.0.0 GA | 2025-05-28 | Vector search GA |
| 1.1.0 | 2025-12-24 | FT.AGGREGATE, non-vector indexes, cluster consistency |
| 1.2.0 GA | 2026-03-17 | Full-text search, tag search, numeric ranges, hybrid queries |

## Full-Text Search (1.2.0+)

valkey-search 1.2.0 supports keyword-based full-text search with these query types:

| Query Type | Description | Example |
|------------|-------------|---------|
| Keyword | Single term matching | `@title:database` |
| Phrase | Exact phrase matching | `@title:"in-memory database"` |
| Prefix | Starts-with matching | `@title:data*` |
| Suffix | Ends-with matching | `@title:*base` |
| Wildcard | Pattern matching | `@title:data*se` |
| Fuzzy | Typo-tolerant matching | `@title:%%databse%%` |

Full-text search operates on TEXT fields in the index schema. Combined with TAG fields (exact-match on categories, IDs, status flags) and NUMERIC fields (range queries with microsecond latency), it enables rich hybrid queries without external search services.

## Tag and Numeric Search (1.2.0+)

| Field Type | Description | Example |
|------------|-------------|---------|
| TAG | Exact-match filtering on categorical data | `@status:{active}` |
| NUMERIC | Greater than, less than, between ranges | `@price:[10 100]` |

These field types existed for vector pre-filtering since 1.0, but 1.2.0 enables them as standalone query dimensions - no vector component required.

## FT.AGGREGATE (1.1.0+)

Server-side aggregation pipeline for analytics queries:

| Clause | Description |
|--------|-------------|
| GROUPBY | Group results by one or more fields |
| REDUCE | Aggregate functions: COUNT, SUM, AVG |
| APPLY | Computed expressions on fields |
| FILTER | Post-aggregation filtering |
| SORTBY | Sort aggregation results |
| LIMIT | Pagination of aggregation output |

## Vector Search Algorithms

### KNN (Flat / Brute Force)

Exact nearest-neighbor search using linear scan. Guarantees true nearest neighbors but scales linearly with dataset size.

| Property | Value |
|----------|-------|
| Accuracy | 100% recall (exact) |
| Speed | O(n) per query |
| Best for | Small datasets, accuracy-critical workloads |

### HNSW (Hierarchical Navigable Small World)

Approximate nearest-neighbor search using a graph-based index. Trades a small amount of recall for significantly faster queries on large datasets.

| Property | Value |
|----------|-------|
| Accuracy | 99%+ recall (tunable) |
| Speed | O(log n) per query |
| Latency | Single-digit milliseconds on billions of vectors |
| Best for | Large datasets, latency-sensitive workloads |

HNSW parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `M` | 16 | Maximum number of edges per node (higher = better recall, more memory) |
| `EF_CONSTRUCTION` | 200 | Search width during index building (higher = better recall, slower build) |
| `EF_RUNTIME` | 10 | Search width at query time (higher = better recall, slower query) |

## Performance

- Lock-free read path for concurrent queries
- SIMD vector processing and CPU cache efficiency
- Multi-threaded: linear scaling with CPU cores for both query and ingestion
- Full cluster mode support with distributed indexes and fan-out query coordination

## Supported Data Types

Indexes fields in **Hash** (vector as binary blob) and **JSON** (vector as JSON array, via valkey-json).

## Index Creation

```
FT.CREATE idx
  ON HASH PREFIX 1 doc:
  SCHEMA
    title TEXT
    body TEXT
    embedding VECTOR HNSW 6
      TYPE FLOAT32
      DIM 384
      DISTANCE_METRIC COSINE
    category TAG
    price NUMERIC
```

### Field Types

| Field Type | Description | Use Case |
|------------|-------------|----------|
| TEXT | Full-text searchable field | Title, description, body |
| VECTOR | Vector embedding for similarity search | Semantic search dimension |
| NUMERIC | Numeric value for range filtering | Price, timestamp, score |
| TAG | Categorical label for exact match filtering | Category, status, type |

### Index Options (1.2.0+)

| Option | Description |
|--------|-------------|
| SKIPINITIALSCAN | Skip backfill on FT.CREATE - useful when populating data after index creation |
| SORTBY on FT.SEARCH | Sort results by any indexed field |
| Single Slot Query | Cluster mode optimization for queries targeting a single slot |

### Distance Metrics (Vector Fields)

| Metric | Description | Common Use |
|--------|-------------|------------|
| `COSINE` | Cosine similarity (1 - cos_sim) | Text embeddings, normalized vectors |
| `L2` | Euclidean distance | Spatial data, image features |
| `IP` | Inner product (negative) | Pre-normalized vectors, dot-product models |

### Limits (1.2.0)

- Default: 1,000 indexes per instance, 1,000 fields per index
- Maximum: 10,000 fields per index

## Query Syntax

### Full-Text Search

```
# Keyword search
FT.SEARCH idx "@title:database"

# Phrase search
FT.SEARCH idx "@title:\"in-memory database\""

# Prefix search
FT.SEARCH idx "@title:val*"

# Fuzzy search (typo-tolerant)
FT.SEARCH idx "@title:%%valky%%"
```

### Tag and Numeric Queries

```
# Tag filter
FT.SEARCH idx "@category:{electronics}"

# Numeric range
FT.SEARCH idx "@price:[10 100]"

# Combined
FT.SEARCH idx "@category:{electronics} @price:[10 100]"
```

### Pure Vector Search (KNN)

```
FT.SEARCH idx "*=>[KNN 10 @embedding $query_vec]"
  PARAMS 2 query_vec <binary_vector>
```

Returns the 10 nearest neighbors by vector distance.

### Hybrid Queries (Text + Vector + Filters)

Combine any search dimensions in a single query. Filters narrow the candidate set before or during vector comparison.

```
# Full-text + vector
FT.SEARCH idx "(@title:database)=>[KNN 10 @embedding $query_vec]"
  PARAMS 2 query_vec <binary_vector>

# Tag + numeric + vector
FT.SEARCH idx "(@category:{electronics} @price:[10 100])=>[KNN 5 @embedding $query_vec]"
  PARAMS 2 query_vec <binary_vector>

# Full-text + tag + numeric (no vector)
FT.SEARCH idx "@title:database @category:{nosql} @price:[0 50]"
```

### Aggregation

```
FT.AGGREGATE idx "@category:{electronics}"
  GROUPBY 1 @brand
  REDUCE COUNT 0 AS count
  REDUCE AVG 1 @price AS avg_price
  SORTBY 2 @count DESC
  LIMIT 0 10
```

### Query Options

| Option | Description |
|--------|-------------|
| `PARAMS n key value [key value ...]` | Named parameters (vectors passed as binary) |
| `RETURN n field [field ...]` | Limit returned fields |
| `SORTBY field [ASC\|DESC]` | Sort results by field (1.2.0+) |
| `LIMIT offset count` | Pagination (default: first 10 results) |
| `TIMEOUT ms` | Query timeout in milliseconds |

## Client Integration via GLIDE

GLIDE provides a dedicated API for search commands:

| Language | Class | Import |
|----------|-------|--------|
| Node.js | `GlideFt` | `@valkey/valkey-glide` |
| Java | `FT` | `glide.api.commands.servermodules.FT` |
| Python | `ft` | `glide.ft` |

See the **valkey-glide** skill for complete GlideFt API reference and code examples across Java, Node.js, and Python.

## Feature Comparison: valkey-search vs RediSearch

| Feature | valkey-search 1.2.0 | RediSearch |
|---------|---------------------|------------|
| Vector similarity search | Yes | Yes |
| Hybrid vector + filter queries | Yes | Yes |
| Full-text search | Yes (1.2.0+) | Yes |
| Fuzzy / typo-tolerant search | Yes (1.2.0+) | Yes |
| Tag search | Yes (1.2.0+) | Yes |
| Numeric range queries | Yes (1.2.0+) | Yes |
| FT.AGGREGATE | Yes (1.1.0+) | Yes |
| Stemming | Yes | Yes |
| Phonetic matching | **Not yet** | Yes |
| Auto-complete / suggestions | **Not yet** | Yes |
| FT.CURSOR | **Not yet** | Yes |
| INFIELDS / INKEYS parameters | **Not yet** | Yes |

FT.CURSOR, FT.EXPLAINCLI, and INFIELDS/INKEYS are open feature requests for future releases.

## Commands

| Command | Description |
|---------|-------------|
| FT.CREATE | Create an index with schema definition |
| FT.DROPINDEX | Delete an index |
| FT.INFO | Get index metadata and statistics |
| FT._LIST | List all indexes |
| FT.SEARCH | Search an index (text, tag, numeric, vector, or hybrid) |
| FT.AGGREGATE | Run aggregation pipelines over indexed data |

## Use Cases

| Use Case | How |
|----------|-----|
| Semantic search / RAG | Store document embeddings, query with user question embedding |
| Full-text search | Index TEXT fields, query with keywords, phrases, or fuzzy matching |
| Recommendation engine | Store item embeddings, find similar items by vector distance |
| Catalog filtering | Combine tag, numeric, and text filters for product/content search |
| Analytics | FT.AGGREGATE with GROUPBY and REDUCE for real-time aggregations |
| Hybrid search | Combine any of text, tag, numeric, and vector in a single query |
