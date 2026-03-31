---
name: valkey-search-dev
description: "Use when contributing to the valkey-search module codebase (valkey-io/valkey-search), understanding its C++ architecture, building from source, writing tests, working with index types (HNSW, FLAT, Numeric, Tag, Text), query parsing, filter evaluation, cluster coordination, or reviewing PRs."
version: 1.0.0
argument-hint: "[area or task]"
---

# Valkey Search Module - Contributor Reference

C++ module providing vector similarity search, full-text search, and hybrid queries for Valkey.

## Routing

- Index types, HNSW, FLAT, numeric, tag, text, VectorBase, IndexBase -> Architecture
- Query parsing, filter expressions, predicates, hybrid search, pre-filter, FT.SEARCH, FT.AGGREGATE -> Query Engine
- Build from source, cmake, tests, CI, sanitizers, integration tests -> Build and Test
- Code structure, adding features, adding index types, coordinator, contributing -> Contributing

## Reference

| Topic | Reference |
|-------|-----------|
| Index types (HNSW, FLAT, Numeric, Tag, Text), shard design, cluster coordination | [architecture](reference/architecture.md) |
| Query parsing, filter evaluation, hybrid queries, FT.AGGREGATE pipeline | [query-engine](reference/query-engine.md) |
| Building from source, running tests, CI workflows, sanitizers | [build-and-test](reference/build-and-test.md) |
| Code structure, adding index types, adding query features, PR workflow | [contributing](reference/contributing.md) |

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
