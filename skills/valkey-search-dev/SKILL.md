---
name: valkey-search-dev
description: "Use when contributing to valkey-io/valkey-search - C++ internals, HNSW/FLAT vector indexes, full-text/numeric/tag indexes, query engine, cluster coordinator, build. Not for FT.SEARCH in apps (valkey-modules) or custom modules (valkey-module-dev)."
version: 1.0.0
argument-hint: "[subsystem or source file]"
---

# Valkey Search Module - Contributor Reference

## Routing

- HNSW graph, ef_construction, ef_runtime, M parameter, ANN search -> Indexes (hnsw)
- FLAT index, brute-force, exact KNN, block-size growth -> Indexes (flat)
- Numeric range queries, BTreeNumeric, SegmentTree, EntriesFetcher -> Indexes (numeric)
- Tag filtering, PatriciaTree, separator, prefix wildcard, case sensitivity -> Indexes (tag)
- Full-text search, Rax trees, postings, stemming, proximity, phrase, fuzzy -> Indexes (text)
- Module loading, ValkeySearch singleton, VMSDK, startup sequence -> Architecture (module-overview)
- IndexSchema class, attributes, keyspace mutations, backfill, sequence numbers -> Architecture (index-schema)
- SchemaManager, index CRUD, staging, FlushDB/SwapDB, RDB load -> Architecture (schema-manager)
- Thread pools, TimeSlicedMRMWMutex, fork suspension, concurrency -> Architecture (thread-model)
- Filter expressions, predicate AST, QueryOperations bitmask, safety limits -> Query (parsing)
- Prefilter vs inline filtering, async dispatch, content resolution -> Query (execution)
- FT.SEARCH handler, RETURN/LIMIT/SORTBY, response serialization -> Query (ft-search)
- FT.AGGREGATE pipeline, GROUPBY/REDUCE, APPLY, expression engine -> Query (ft-aggregate)
- gRPC coordinator, cluster topology, metadata sync, fingerprinting -> Cluster (coordinator)
- RDB protobuf format, SafeRDB, FT.INTERNAL_UPDATE, replication staging -> Cluster (replication)
- FT.INFO fanout, FT._DEBUG subcommands, metrics counters, latency samplers -> Cluster (metrics)
- Building from source, CMake, Ninja, build.sh, dependencies -> Build (build)
- Unit tests, integration tests, pytest, GoogleTest, stability tests -> Build (testing)
- CI workflows, Docker CI, pre-built debs, debugging CI failures -> Build (ci-pipeline)
- Directory layout, IndexBase hierarchy, adding features, VMSDK -> Build (code-structure)
- Query engine overview, hybrid search, pre-filter architecture -> Query (execution)
- Cluster-mode search, shard fanout, coordinator port -> Cluster (coordinator)
- Adding new index types, RDB callbacks, command registration -> Build (code-structure)
- Performance, contention checking, writer suspension, cron jobs -> Architecture (thread-model)
- Vector similarity, VectorBase, embedding storage, distance metrics -> Indexes (hnsw)
- Schema mutations, replication staging protocol, chunk streaming -> Cluster (replication)
- Observability, adding metrics, latency sampling -> Cluster (metrics)
- Expression engine, Record types, RecordSet, reducers -> Query (ft-aggregate)
- Index architecture overview, shard design -> Architecture (module-overview)
- Build with sanitizers, ASAN, TSAN, Valgrind -> Build (build)

## Quick Start

    # Build
    ./build.sh --configure

    # Run all tests
    ./build.sh --run-tests

    # Run a single test suite
    ./build.sh --run-tests=vector_test

    # Load the module
    valkey-server --loadmodule .build-release/libsearch.so

    # Build with sanitizers
    ./build.sh --configure --asan
    ./build.sh --configure --tsan

## Critical Rules

1. **C++17 codebase** - uses std::variant, std::optional, structured bindings throughout
2. **VMSDK abstraction** - never call ValkeyModule_* directly; use the VMSDK wrapper layer
3. **TimeSlicedMRMWMutex** - all index mutations must hold the correct lock; background threads yield to fork
4. **Protobuf RDB format** - index metadata serializes via protobuf, not raw binary; see SafeRDB for backward compat
5. **Tests are non-negotiable** - unit tests (GoogleTest) for internals, pytest integration tests for commands
6. **gRPC coordinator** - cluster mode uses gRPC for metadata sync; never bypass the coordinator protocol

## Architecture

| Topic | Reference |
|-------|-----------|
| Module loading, ValkeySearch singleton, VMSDK, thread pools, config | [module-overview](reference/architecture-module-overview.md) |
| IndexSchema class, attribute map, keyspace mutations, backfill | [index-schema](reference/architecture-index-schema.md) |
| SchemaManager singleton, index CRUD, replication staging, RDB | [schema-manager](reference/architecture-schema-manager.md) |
| Thread pools, TimeSlicedMRMWMutex, fork suspension, concurrency | [thread-model](reference/architecture-thread-model.md) |

## Index Types

| Topic | Reference |
|-------|-----------|
| HNSW graph index, VectorHNSW, hnswlib, ef/M params, inline filtering | [hnsw](reference/indexes-hnsw.md) |
| FLAT brute-force index, VectorFlat, block-size growth, exact KNN | [flat](reference/indexes-flat.md) |
| Numeric index, BTreeNumeric, SegmentTree overlay, range queries | [numeric](reference/indexes-numeric.md) |
| Tag index, PatriciaTree storage, separator, prefix wildcard matching | [tag](reference/indexes-tag.md) |
| Full-text search, Rax prefix/suffix trees, postings, stemming, fuzzy | [text](reference/indexes-text.md) |

## Query Engine

| Topic | Reference |
|-------|-----------|
| Filter expression parser, predicate AST, QueryOperations, safety limits | [parsing](reference/query-parsing.md) |
| Search execution, prefilter vs inline, async dispatch, content resolution | [execution](reference/query-execution.md) |
| FT.SEARCH handler, parameter parsing, RETURN/LIMIT/SORTBY, response format | [ft-search](reference/query-ft-search.md) |
| FT.AGGREGATE pipeline, GROUPBY/REDUCE, APPLY, expression engine, Records | [ft-aggregate](reference/query-ft-aggregate.md) |

## Cluster and Replication

| Topic | Reference |
|-------|-----------|
| gRPC coordinator, cluster topology, MetadataManager, reconciliation | [coordinator](reference/cluster-coordinator.md) |
| RDB protobuf format, SafeRDB, FT.INTERNAL_UPDATE, replication staging | [replication](reference/cluster-replication.md) |
| FT.INFO fanout, FT._DEBUG subcommands, Metrics singleton, latency samplers | [metrics](reference/cluster-metrics.md) |

## Build and Contributing

| Topic | Reference |
|-------|-----------|
| CMake build system, Ninja, dependencies, build.sh options, sanitizers | [build](reference/contributing-build.md) |
| Unit tests (GoogleTest), integration tests (pytest), stability tests | [testing](reference/contributing-testing.md) |
| CI workflows, Docker-based CI, pre-built debs, debugging CI failures | [ci-pipeline](reference/contributing-ci-pipeline.md) |
| Directory layout, IndexBase hierarchy, adding features, VMSDK layer | [code-structure](reference/contributing-code-structure.md) |
