# Architecture

Use when understanding valkey-search internals, index types, shard design, cluster coordination, or the data model.

Source: `src/`, `src/indexes/`, `src/coordinator/`, `vmsdk/`

---

## Module Overview

valkey-search is a C++20 Valkey module (`libsearch.so`) built with CMake/Ninja. It loads via `ValkeyModule_OnLoad` in `src/module_loader.cc`, which initializes `KeyspaceEventManager`, `ValkeySearch` singleton, thread pools (reader, writer, utility), and optionally a gRPC coordinator for cluster mode.

Namespace: `valkey_search`. All code under `src/`.

## Core Data Model

### IndexSchema (`src/index_schema.h`)

The central object. One IndexSchema per `FT.CREATE` index. Manages:

- **Attributes** - map of field name to `Attribute` objects, each holding an `IndexBase`
- **Keyspace subscriptions** - subscribes to key prefixes, processes mutations via `KeyspaceEventManager`
- **Backfill** - scans existing keys on index creation, processes in batches on server cron
- **Mutation queue** - async mutation processing with `TimeSlicedMRMWMutex` (multiple-reader, multiple-writer)
- **RDB persistence** - save/load via protobuf serialization (`index_schema.proto`)

Key lifecycle: `Create()` -> `Init()` -> `PerformBackfill()` -> steady state (keyspace events)

### SchemaManager (`src/schema_manager.h`)

Singleton registry of all IndexSchema objects. Maps `(db_num, name)` to `shared_ptr<IndexSchema>`. Handles `FT._LIST`, FlushDB, SwapDB, loading/shutdown events.

### AttributeDataType (`src/attribute_data_type.h`)

Abstracts Hash vs JSON data sources. Fetches field values from keys, handles both `HASH` and `JSON` (via `JSON.GET` module interop).

## Index Types

All indexes inherit from `IndexBase` (`src/indexes/index_base.h`):

```
IndexBase (abstract)
  +-- VectorBase -> VectorHNSW<T>, VectorFlat<T>
  +-- Numeric
  +-- Tag
  +-- Text (via TextIndexSchema)
```

`IndexerType` enum: `kHNSW`, `kFlat`, `kNumeric`, `kTag`, `kText`, `kVector`, `kNone`

### Vector HNSW (`src/indexes/vector_hnsw.h`)

- Template on data type `T` (FLOAT32)
- Wraps `hnswlib::HierarchicalNSW<T>` from `third_party/hnswlib/`
- Parameters: M (connectivity), ef_construction, ef_runtime, dimensions
- Distance metrics: L2, IP, COSINE (COSINE normalizes vectors on insert)
- Auto-resizes when capacity reached (`ResizeIfFull`)
- Thread safety: `resize_mutex_` for structural changes, `tracked_vectors_mutex_` for vector tracking
- Supports `BaseFilterFunctor` for inline filtering during search

### Vector FLAT (`src/indexes/vector_flat.h`)

- Template on data type `T` (FLOAT32)
- Wraps `hnswlib::BruteforceSearch<T>` - exhaustive linear scan
- Parameters: block_size (allocation granularity), dimensions
- Same distance metrics as HNSW
- Simpler but O(n) search - suitable for small datasets or exact results

### Numeric Index (`src/indexes/numeric.h`)

- `BTreeNumeric<InternedStringPtr>` - Abseil btree_map keyed by double
- Augmented with `SegmentTree` for O(log n) range count queries
- Supports range queries with inclusive/exclusive bounds
- Used for pre-filtering and post-filtering numeric predicates

### Tag Index (`src/indexes/tag.h`)

- `PatriciaTree<InternedStringPtr>` (compressed trie)
- Configurable separator (default `,`) and case sensitivity
- Stores raw tag string per key plus parsed tag set
- Supports union of tag values in queries (`{tag1 | tag2}`)

### Text Index (`src/indexes/text/text_index.h`)

- Full inverted index with prefix tree (Rax) and optional suffix tree
- Per-key text indexes for post-filtering
- Supports: term, prefix, suffix, infix, fuzzy (Levenshtein), exact match
- Stemming via Snowball stemmer with configurable min stem size
- Position tracking for proximity/phrase queries (SLOP, INORDER)
- `TextIndexSchema` manages the shared text index across all TEXT attributes in a schema

## String Interning (`src/utils/string_interning.h`)

Keys and vectors are interned - stored once and referenced by pointer. `InternedStringPtr` is used throughout for memory efficiency and fast equality checks.

## Cluster Coordination

### Coordinator (`src/coordinator/`)

In cluster mode, valkey-search runs a gRPC sidecar for cross-shard communication:

- **Server** (`server.h`) - receives `SearchIndexPartition`, `InfoIndexPartition`, `GetGlobalMetadata` RPCs
- **Client** (`client.h`) - sends fan-out requests to other shards
- **MetadataManager** (`metadata_manager.h`) - global metadata consistency via cluster bus messages and gRPC reconciliation

### Fan-out Search (`src/query/fanout.h`)

Distributed search: coordinator node fans out `SearchIndexPartitionRequest` to all shards via gRPC, merges `SearchIndexPartitionResponse` results. Consistency ensured via `IndexFingerprintVersion` and `slot_fingerprint`.

### Metadata Versioning (`src/version.h`)

Metadata uses protobuf with a version overlay. Each IndexSchema computes a minimum compatible version. Versions: kVersion1 (1.0), kVersion2 (1.1 - cluster DB support), kVersion3 (1.2 - full text). Messages with higher minimum version than the receiver are dropped.

## Thread Model

Three thread pools managed by `ValkeySearch`:

| Pool | Purpose |
|------|---------|
| `reader_thread_pool_` | Background vector search, query execution |
| `writer_thread_pool_` | Index mutations from keyspace events |
| `utility_thread_pool_` | Low-priority cleanup, search result cleanup |

Main thread handles: command parsing, backfill scheduling, content resolution, reply sending. `TimeSlicedMRMWMutex` separates read (search) and write (mutation) phases within each IndexSchema.

## RDB Persistence (`src/rdb_serialization.h`)

Index data saved as protobuf-serialized `RDBSection` chunks in Valkey's aux data slot. Vector indexes save their full state (HNSW graph, FLAT data). Tag/Numeric indexes rebuild from keyspace on load. Chunked I/O via `RDBChunkOutputStream`/`RDBChunkInputStream` for large indexes.

## Key Dependencies

| Dependency | Purpose |
|------------|---------|
| Abseil (absl) | Containers, synchronization, status, strings |
| gRPC + Protobuf | Cluster coordinator communication |
| hnswlib (third_party) | HNSW and brute-force vector algorithms |
| ICU (third_party) | Unicode normalization for text indexing |
| Highway Hash | Metadata fingerprinting |
| vmsdk | Valkey Module SDK wrapper (thread pools, cluster map, blocked clients) |
