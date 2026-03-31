---
name: valkey-search-dev
description: "Contributing to valkey-io/valkey-search C++ module - index internals (HNSW, FLAT, numeric, tag, text), query engine, vector similarity, hybrid search, build system, tests, cluster coordinator, and PR review."
version: 1.0.0
argument-hint: "[area or task]"
---

# Valkey Search Module - Contributor Reference

C++ module providing vector similarity search (ANN/KNN), full-text search, and hybrid queries for Valkey. Does NOT cover user-facing FT.SEARCH usage or application patterns - see the `valkey-modules` skill for that.

## Routing

- Index types, HNSW, FLAT, numeric, tag, text, VectorBase, IndexBase, embedding, ANN, KNN, vector similarity -> Architecture
- Query parsing, filter expressions, predicates, hybrid search, pre-filter, FT.SEARCH internals, FT.AGGREGATE pipeline -> Query Engine
- Build from source, cmake, tests, CI, sanitizers, integration tests, ASAN, TSAN -> Build and Test
- Code structure, adding features, adding index types, coordinator, contributing, RDB, AOF, replication, RediSearch differences -> Contributing

## Reference

| Topic | Reference |
|-------|-----------|
| Index internals (HNSW, FLAT, Numeric, Tag, Text), shard design, cluster coordinator, embedding storage | [architecture](reference/architecture.md) |
| Query parsing, filter evaluation, hybrid queries, FT.AGGREGATE pipeline, pre-filter vs post-filter | [query-engine](reference/query-engine.md) |
| Building from source, running tests, CI workflows, sanitizers (ASAN/TSAN) | [build-and-test](reference/build-and-test.md) |
| Code structure, adding index types, adding query features, RDB/AOF, PR workflow | [contributing](reference/contributing.md) |

## Quick Reference

```bash
# Build
./build.sh --configure

# Run unit tests
./build.sh --run-tests

# Run single test
./build.sh --run-tests=vector_test

# Load the module
valkey-server --loadmodule .build-release/libsearch.so
```

Commands: `FT.CREATE`, `FT.SEARCH`, `FT.AGGREGATE`, `FT.INFO`, `FT.DROPINDEX`, `FT._LIST`, `FT._DEBUG`
