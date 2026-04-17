---
name: valkey-search-dev
description: "Use when contributing to valkey-io/valkey-search source - C++20 module internals, HNSW/FLAT/numeric/tag/text indexes, query engine, cluster coordinator, VMSDK, build. Not for FT.SEARCH in apps (valkey) or Valkey server internals (valkey-dev)."
version: 2.0.0
argument-hint: "[subsystem or source file]"
---

# valkey-search contributor reference

Targets valkey-search 1.2.0. Module registers as `"search"`; minimum Valkey server 9.0.1. C++20, ships as `libsearch.{so,dylib}`.

## Not this skill

- Apps using FT.SEARCH / FT.AGGREGATE -> `valkey`.
- Valkey server internals -> `valkey-dev`.

## Route by work area

| Working on... | File |
|---------------|------|
| Module loading, `ValkeySearch` singleton, thread pools, VMSDK overview, command table, configs, INFO sections | `reference/architecture-module-overview.md` |
| `IndexSchema` per-index state, attribute map, keyspace notifications, mutation pipeline, sequence numbers, backfill, `TimeSlicedMRMWMutex` quotas | `reference/architecture-index-schema.md` |
| `SchemaManager` registry, CRUD, replication staging, FlushDB / SwapDB, RDB save/load, fingerprinting | `reference/architecture-schema-manager.md` |
| Thread contexts, pool suspension across fork, writer resume policy, `TimeSlicedMRMWMutex`, `MainThreadAccessGuard`, thread-safety annotations | `reference/architecture-thread-model.md` |
| HNSW graph index, `VectorHNSW`, hnswlib, M / ef_construction / ef_runtime, resize, inline filter, `PrefilterEvaluator`, mark-delete + re-add | `reference/indexes-hnsw.md` |
| FLAT brute-force index, `VectorFlat`, in-place modify, physical remove, block-size growth | `reference/indexes-flat.md` |
| Numeric index, BTree + SegmentTree, range queries, negated ranges, tracked vs untracked | `reference/indexes-numeric.md` |
| Tag index, `PatriciaTree`, separator / case sensitivity, wildcard prefix, negated queries | `reference/indexes-tag.md` |
| Full-text, `TextIndexSchema` vs `Text`, Rax prefix / optional suffix / stem trees, postings, proximity / phrase, lexer, fuzzy, per-word bucket locks | `reference/indexes-text.md` |
| `FilterParser`, predicate AST, `TextPredicate` variants, `ComposedPredicate`, `Evaluator`, `QueryOperations` bitmask, safety limits | `reference/query-parsing.md` |
| Search execution, prefilter vs inline (planner), async dispatch, content resolution, contention check, result trimming | `reference/query-execution.md` |
| FT.SEARCH handler, parameter table, PARAMS substitution, response shape, SORTBY | `reference/query-ft-search.md` |
| FT.AGGREGATE pipeline, GROUPBY / REDUCE / APPLY / SORTBY / LIMIT / FILTER, reducers, expression engine, `Record` / `RecordSet` | `reference/query-ft-aggregate.md` |
| gRPC coordinator, service RPCs, port offset, client pool, `MetadataManager`, HighwayHash fingerprinting, cluster-bus broadcast, reconciliation, suspension guard | `reference/cluster-coordinator.md` |
| RDB protobuf format, `SafeRDB`, iterator discipline, chunk streams for vectors, module type registration, `FT.INTERNAL_UPDATE`, replication staging | `reference/cluster-replication.md` |
| `Metrics` singleton, counter groups, latency samplers, RDB restore progress, FT.INFO scopes + fanout, FT._DEBUG subcommands, pausepoints | `reference/cluster-metrics.md` |
| CMake + `build.sh`, submodules, third-party, VMSDK layer, sanitizer builds, platform notes, troubleshooting | `reference/contributing-build.md` |
| Unit tests (7 GoogleTest binaries), Python integration, stability / memtier, test infra, adding tests | `reference/contributing-testing.md` |
| CI workflows (11), Docker build, pre-built `.deb` deps, clang-format gate, artifact upload, local CI repro | `reference/contributing-ci-pipeline.md` |
| Directory layout, `IndexBase` interface, how to add an index type, command registration, VMSDK abstractions, key singletons, proto files | `reference/contributing-code-structure.md` |

## Critical rules

1. **C++20 only** - GCC 12+ or Clang 16+.
2. **Never call `ValkeyModule_*` directly.** Use the VMSDK wrapper layer.
3. **`TimeSlicedMRMWMutex` for index-data access.** Reader/writer phases with 10:1 quota (10 ms read, 1 ms write). Writers yield to readers.
4. **Fork discipline**: writer pool is suspended across fork (COW dirty-page control). Reader + utility resume immediately; writer resumes on `SUBEVENT_FORK_CHILD_DIED` or `max-worker-suspension-secs` timeout (default 60 s).
5. **Protobuf RDB format.** Index metadata is proto-serialized; vectors stream as supplemental chunks via `RDBChunkInputStream` / `RDBChunkOutputStream` with `SafeRDB`.
6. **gRPC coordinator for cluster fanout.** Port = `valkey_port + 20294` (special-cased for 6378 TLS). Never bypass the coordinator protocol.
7. **`MainThreadAccessGuard<T>`** - wraps data that must only touch the main thread (`db_key_info_`, `backfill_job_`, `staged_db_to_index_schemas_`, etc.). Debug-asserts on misuse.

## Grep hazards

- **Module name is `"search"`, data type (dummy for aux RDB) is `"Vk-Search"`** (9 chars, Valkey max). `MODULE_RELEASE_STAGE` rotates `"dev"` -> `"rcN"` -> `"ga"` at release.
- **`kCoordinatorPortOffset = 20294`** - default port 6379 yields 26673 ("COORD" on phone keypad). TLS port 6378 adds an extra +1 to avoid collision.
- **Writer pool is suspended during fork, not reader/utility.** Don't reverse this. Copy-on-write dirty pages for vector mutations are the reason.
- **`TextIndexSchema` (shared) vs `Text` (per-field)**. Full-text is inherently cross-field: one Rax tree indexes words from all text fields; field masks distinguish which fields. Max 64 text fields (`kMaxTextFieldsCount`), mask is `uint64_t`.
- **`BTreeNumeric` + `SegmentTree` are kept in sync on every mutation.** Both updated per Add/Remove. SegmentTree is O(log n) range counting overlay. Don't update one without the other.
- **Vec-defrag bug is in valkey-bloom, NOT here.** Don't transfer that grep pattern.
- **`RDBSectionIter` / `SupplementalContentIter` / `SupplementalContentChunkIter` are move-only with strict consumption assertions.** Unknown section types must drain supplementals or the destructor fires an assertion.
- **`FieldMask` struct is 16 bytes (enforced by `static_assert`).** `FieldMaskPredicate` is a `uint64_t` alias. These are distinct types.
- **`shouldEmbedStringObject` / `embed-string-threshold` don't apply here** - those are Valkey server internals, not this module.
- **`cancel::Token` is cooperative.** HNSW walks and fetcher iteration poll it; `CancelCondition` wraps it for `hnswlib::BaseCancellationFunctor`. `enable_partial_results=true` returns partial on cancel vs `CancelledError`.
- **FLAT does physical removal (`removePoint`); HNSW only tombstones (`markDelete`).** Consequence: HNSW modify = mark-delete + re-add with `allow_replace_deleted_`; FLAT modify = in-place `memcpy` on hnswlib internals.
- **`SearchIndexPartition` vs `InfoIndexPartition`** - both gRPC RPCs carry `IndexFingerprintVersion` for consistency. Don't confuse the response shapes.
- **`FT.INTERNAL_UPDATE`** is cluster-internal, not user-facing. `skip-corrupted-internal-update-entries` config controls AOF-load behavior on parse failure.
- **Stem tree expansion is gated by `stem_text_field_mask_`.** Only fields with stemming enabled get expanded variants.
- **`kHashKey` for HighwayHash is a fixed 4x64-bit constant** in both `MetadataManager` and `SchemaManager` fingerprinting (same key, different usage levels).
- **`FT._DEBUG` is gated by `vmsdk::config::IsDebugModeEnabled()`.** Off -> replies "ERR unknown command" (appears non-existent). On -> all args logged at WARNING.
- **Pausepoints**: `vmsdk::debug::PausePoint("label")`. Never on main thread or while holding locks - tests block/release background threads. Not replicated.

## Quick-start

```bash
./build.sh --configure                            # CMake + build (auto-detects)
./build.sh --run-tests                            # all unit tests
./build.sh --run-tests=vector_test                # one suite
./build.sh --run-integration-tests                # Python integration
./build.sh --configure --asan                     # AddressSanitizer
./build.sh --configure --tsan                     # ThreadSanitizer
./build.sh --format                               # clang-format
valkey-server --loadmodule .build-release/libsearch.so
```

Commands: FT.CREATE, FT.DROPINDEX, FT.INFO, FT._LIST, FT.SEARCH, FT.AGGREGATE, FT._DEBUG, FT.INTERNAL_UPDATE.

Core configs: `reader-threads`, `writer-threads`, `utility-threads`, `hnsw-block-size`, `max-indexes`, `backfill-batch-size`, `use-coordinator` (startup-only), `prefiltering-threshold-ratio`, `max-term-expansions`, `tag-min-prefix-length`, `max-worker-suspension-secs`.
