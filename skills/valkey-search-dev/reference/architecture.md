# valkey-search Architecture

Use when understanding valkey-search internals, index types, shard design, cluster coordination, or the data model.

Source: `src/`, `src/indexes/`, `src/coordinator/`, `src/query/`, `vmsdk/`

## Contents

- Module Overview (line 20)
- Core Data Model (line 26)
- Index Types (line 48)
- String Interning (`src/utils/string_interning.h`) (line 106)
- Vector Externalization (`src/vector_externalizer.h`) (line 110)
- Metrics (`src/metrics.h`) (line 114)
- Cluster Coordination (line 118)
- Thread Model (line 156)
- RDB Persistence (`src/rdb_serialization.h`) (line 168)
- Key Dependencies (line 172)

## Module Overview

valkey-search is a C++20 Valkey module (`libsearch.so`) built with CMake/Ninja. The vmsdk framework generates the `ValkeyModule_OnLoad` entry point (via macro in `vmsdk/src/module.h`), which delegates to `src/module_loader.cc`. This initializes `KeyspaceEventManager`, `ValkeySearch` singleton, thread pools (reader, writer, utility), and optionally a gRPC coordinator for cluster mode.

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
- Stemming via Snowball stemmer (`third_party/snowball/`) with configurable min stem size (default 4)
- Position tracking for proximity/phrase queries (SLOP, INORDER)
- `TextIndexSchema` manages the shared text index across all TEXT attributes in a schema
- `TextIterator` (`text/text_iterator.h`) - base interface for key+position iteration across text search results
- `InvasivePtr<T>` (`text/invasive_ptr.h`) - memory-efficient ref-counted smart pointer with inline refcount, used for posting list targets in the rax tree
- `RaxTargetMutexPool` (`text/rax_target_mutex_pool.h`) - sharded mutex pool for concurrent rax tree writes, hashes word to mutex index

## String Interning (`src/utils/string_interning.h`)

Keys and vectors are interned - stored once and referenced by pointer. `InternedStringPtr` is used throughout for memory efficiency and fast equality checks.

## Vector Externalization (`src/vector_externalizer.h`)

When COSINE distance is used, vectors are normalized on insert. `VectorExternalizer` denormalizes vectors on read so clients see original values. Uses an LRU cache (default 100 entries) to avoid repeated denormalization. Registers an externalize callback with the Valkey engine for Hash field interception.

## Metrics (`src/metrics.h`)

Singleton `Metrics` class tracks extensive telemetry via atomic counters and `LatencySampler` (HdrHistogram-backed, from `third_party/hdrhistogram_c/`). Categories: query stats (vector, non-vector, text, hybrid, pre-filter vs inline), HNSW/FLAT operation exceptions, RDB load/save progress, coordinator gRPC latencies, ingestion rates, time-slice mutex stats, and full-text in-flight blocking. Exposed via `MODULE INFO`.

## Cluster Coordination

### Coordinator (`src/coordinator/`)

In cluster mode, valkey-search runs a gRPC sidecar for cross-shard communication:

- **Server** (`server.h`) - receives `SearchIndexPartition`, `InfoIndexPartition`, `GetGlobalMetadata` RPCs
- **Client** (`client.h`) - sends fan-out requests to other shards
- **ClientPool** (`client_pool.h`) - lazy-creates and caches gRPC `Client` instances by address
- **MetadataManager** (`metadata_manager.h`) - global metadata consistency via cluster bus messages and gRPC reconciliation
- **Util** (`util.h`) - gRPC/absl status conversion, coordinator port derivation

### Coordinator Port (`src/coordinator/util.h`)

The gRPC coordinator port is auto-derived: `valkey_port + 20294`. For default port 6379 this yields 26673 (COORD on a telephone keypad). Not configurable via CLI argument - derived automatically. The `use-coordinator` module config (default false, hidden, startup-only) enables the coordinator. When true AND in cluster mode, the gRPC server and MetadataManager are initialized.

### Fan-out Architecture (`src/query/`)

`FanoutOperationBase<Request, Response, TargetMode>` (`fanout_operation_base.h`) is the template base for all distributed operations. It blocks the client, fans out gRPC requests to targets, collects responses, retries on failure (10ms between rounds), and handles timeouts. Target modes: `kAll` (all nodes) or `kPrimary` (primary nodes only).

Concrete fan-out operations:

| Class | File | Purpose |
|-------|------|---------|
| `PerformSearchFanoutAsync` | `fanout.h` | Distributed FT.SEARCH - fan-out to all shards, merge results |
| `ClusterInfoFanoutOperation` | `cluster_info_fanout_operation.h` | FT.INFO across all nodes (kAll mode) |
| `PrimaryInfoFanoutOperation` | `primary_info_fanout_operation.h` | FT.INFO across primaries only (kPrimary mode) |

Error types tracked per-request: `INDEX_NAME_ERROR`, `INCONSISTENT_STATE_ERROR`, `COMMUNICATION_ERROR`. Consistency ensured via `IndexFingerprintVersion` and `slot_fingerprint`.

### Replication (`src/commands/ft_internal_update.cc`)

Index metadata replicates to replicas via the `FT.INTERNAL_UPDATE` command. When the primary creates/modifies an index, `MetadataManager::ReplicateFTInternalUpdate()` calls `ValkeyModule_Replicate()` to propagate protobuf-serialized `GlobalMetadataEntry` to replicas. On replicas, `CreateEntryOnReplica()` processes the update. Handles corrupted AOF entries with the `skip-corrupted-internal-update-entries` config.

### Metadata Versioning (`src/version.h`)

Metadata uses protobuf with a version overlay. Each IndexSchema dynamically computes a minimum compatible version based on feature usage. Versions: kRelease10 (1.0.0), kRelease11 (1.1.0 - cluster DB support), kRelease12 (1.2.0 - full text). Messages with higher minimum version than the receiver are dropped. This enables forward compatibility - 1.1 code writes kVersion1 objects when new features are unused.

## Thread Model

Three thread pools managed by `ValkeySearch`:

| Pool | Purpose |
|------|---------|
| `reader_thread_pool_` | Background vector search, query execution |
| `writer_thread_pool_` | Index mutations from keyspace events |
| `utility_thread_pool_` | Low-priority cleanup, search result cleanup |

Main thread handles: command parsing, backfill scheduling, content resolution, reply sending. `TimeSlicedMRMWMutex` separates read (search) and write (mutation) phases within each IndexSchema.

## RDB Persistence (`src/rdb_serialization.h`)

Index data saved as protobuf-serialized `RDBSection` chunks in Valkey's aux data slot (`rdb_section.proto`). Format: minimum semantic version + count of `RDBSection` protos, each followed by optional `SupplementalContent` sections for chunked data (vector index graphs, key-to-ID maps). Vector indexes save their full state (HNSW graph, FLAT data). Tag/Numeric indexes rebuild from keyspace on load. Chunked I/O via `RDBChunkOutputStream`/`RDBChunkInputStream` for large indexes. V2 format adds mutation queue persistence (`RdbWriteV2`/`RdbReadV2` configs).

## Key Dependencies

| Dependency | Purpose |
|------------|---------|
| Abseil (absl) | Containers, synchronization, status, strings |
| gRPC + Protobuf | Cluster coordinator communication |
| hnswlib (third_party) | HNSW and brute-force vector algorithms |
| SimSIMD (third_party/simsimd) | SIMD-accelerated distance computations (L2, IP) via `third_party/hnswlib/simsimd.h` |
| ICU (third_party) | Unicode normalization for text indexing |
| Snowball (third_party/snowball) | English stemmer for full-text search |
| HdrHistogram_c (third_party) | Latency histogram sampling for metrics |
| highwayhash (submodules) | Metadata fingerprinting for coordinator consistency |
| vmsdk | Valkey Module SDK wrapper (thread pools, cluster map, blocked clients, config, info fields) |
