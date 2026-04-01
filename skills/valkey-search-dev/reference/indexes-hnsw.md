# HNSW Vector Index

Use when working on the approximate nearest neighbor (ANN) vector index, tuning HNSW graph parameters, modifying search or insert behavior, or understanding the hnswlib integration.

Source: `src/indexes/vector_hnsw.h`, `src/indexes/vector_hnsw.cc`, `src/indexes/vector_base.h`, `src/indexes/vector_base.cc`, `third_party/hnswlib/hnswalg.h`

## Contents

- [Class Hierarchy](#class-hierarchy)
- [VectorHNSW Template](#vectorhnsw-template)
- [HNSW Parameters](#hnsw-parameters)
- [Distance Metrics](#distance-metrics)
- [Dynamic Resize](#dynamic-resize)
- [Search with Inline Filtering](#search-with-inline-filtering)
- [PrefilterEvaluator](#prefilterevaluator)
- [Record Lifecycle](#record-lifecycle)
- [Concurrency Model](#concurrency-model)
- [RDB Persistence](#rdb-persistence)
- [Key Implementation Details](#key-implementation-details)

## Class Hierarchy

```
IndexBase (src/indexes/index_base.h)
  -> VectorBase (src/indexes/vector_base.h) + hnswlib::VectorTracker
       -> VectorHNSW<T> (src/indexes/vector_hnsw.h)
       -> VectorFlat<T>  (src/indexes/vector_flat.h)
```

## VectorHNSW Template

`VectorHNSW<T>` is a template class instantiated only for `float` (FLOAT32). It wraps `hnswlib::HierarchicalNSW<T>` from the vendored hnswlib library.

```cpp
template <typename T>
class VectorHNSW : public VectorBase {
  std::unique_ptr<hnswlib::HierarchicalNSW<T>> algo_;
  std::unique_ptr<hnswlib::SpaceInterface<T>> space_;
  mutable absl::Mutex resize_mutex_;
  mutable absl::Mutex tracked_vectors_mutex_;
  std::deque<InternedStringPtr> tracked_vectors_;
};
// Only instantiation:
template class VectorHNSW<float>;
```

Creation flows through `VectorHNSW<T>::Create()` which takes a `VectorIndex` proto, extracts `dimension_count`, `distance_metric`, and the HNSW-specific parameters (`m`, `ef_construction`, `ef_runtime`) from the `hnsw_algorithm` sub-proto. The `HierarchicalNSW` constructor receives `initial_cap` as the starting capacity. `allow_replace_deleted_` is set from `options::GetHNSWAllowReplaceDeleted()`.

## HNSW Parameters

Three parameters control the HNSW graph:

| Parameter | Accessor | Effect |
|-----------|----------|--------|
| `M` | `GetM()` | Max bi-directional links per node per layer. Higher M = better recall, more memory. |
| `ef_construction` | `GetEfConstruction()` | Search width during index build. Higher = better graph quality, slower insertion. |
| `ef_runtime` | `GetEfRuntime()` | Search width at query time. Higher = better recall, slower queries. Adjustable post-creation. |

These are stored in the `HierarchicalNSW` object itself (`algo_->M_`, `algo_->ef_construction_`, `algo_->ef_`). The values come from the `HNSWAlgorithm` protobuf message and are set during `Create()`:

```cpp
index->algo_ = std::make_unique<hnswlib::HierarchicalNSW<T>>(
    index->space_.get(), vector_index_proto.initial_cap(),
    hnsw_proto.m(), hnsw_proto.ef_construction());
index->algo_->setEf(hnsw_proto.ef_runtime());
```

`ef_runtime` can be overridden per-query - the `Search()` method accepts an `optional<size_t> ef_runtime` parameter.

## Distance Metrics

Three distance metrics are supported (defined in `kDistanceMetricByStr` in `vector_base.h`):

| Metric | hnswlib Space | Stored in `space_` | Notes |
|--------|---------------|--------------------|-------|
| `L2` | `hnswlib::L2Space` | L2 (Euclidean) distance | Default, no normalization |
| `IP` | `hnswlib::InnerProductSpace` | Inner product distance | No normalization |
| `COSINE` | `hnswlib::InnerProductSpace` | Same space as IP | Vectors normalized before storage; `normalize_ = true` |

The space is created in `VectorBase::Init()` via `CreateSpace<T>()` (a local function in `vector_base.cc`). COSINE is implemented as normalized inner product - vectors are normalized on insert and queries are normalized before search:

```cpp
// In VectorBase::Init()
if (distance_metric == DISTANCE_METRIC_COSINE) {
  normalize_ = true;
}

// In Search() - normalize query if needed
if (normalize_) {
  auto norm_record = NormalizeEmbedding(query, GetDataTypeSize());
  // search with normalized query...
}
```

`NormalizeEmbedding()` (free function in `vector_base.cc`) computes L2 magnitude and divides each component via `CopyAndNormalizeEmbedding`. It optionally returns the magnitude for later denormalization when reading stored vectors back.

## Dynamic Resize

The HNSW index starts at `initial_cap` capacity and grows dynamically. When `AddRecordImpl()` catches the hnswlib "exceeds limit" exception, it calls `ResizeIfFull()`:

```cpp
absl::Status VectorHNSW<T>::ResizeIfFull() {
  // Double-checked locking pattern:
  {
    absl::ReaderMutexLock lock(&resize_mutex_);
    if (algo_->getCurrentElementCount() < algo_->getMaxElements() ||
        (algo_->allow_replace_deleted_ && algo_->getDeletedCount() > 0)) {
      return absl::OkStatus();  // Space available
    }
  }
  // Exclusive lock for resize, re-check under writer lock
  absl::WriterMutexLock lock(&resize_mutex_);
  if (algo_->getCurrentElementCount() == algo_->getMaxElements() &&
      (!algo_->allow_replace_deleted_ || algo_->getDeletedCount() == 0)) {
    auto block_size = ValkeySearch::Instance().GetHNSWBlockSize();
    algo_->resizeIndex(algo_->getMaxElements() + block_size);
  }
}
```

Key points:
- Growth is by `block_size` (configurable via `ValkeySearch::GetHNSWBlockSize()`)
- hnswlib does not support shrinking - once expanded, capacity only grows
- `allow_replace_deleted_` is controlled by `options::GetHNSWAllowReplaceDeleted()` - when true, deleted slots can be reused before triggering resize
- Resize duration is logged at WARNING level via `vmsdk::StopWatch`

## Search with Inline Filtering

`VectorHNSW::Search()` is the main query entry point:

```cpp
absl::StatusOr<std::vector<Neighbor>> Search(
    absl::string_view query, uint64_t count,
    cancel::Token& cancellation_token,
    std::unique_ptr<hnswlib::BaseFilterFunctor> filter = nullptr,
    std::optional<size_t> ef_runtime = std::nullopt,
    bool enable_partial_results = false);
```

The search flow:
1. Validate query vector size matches `dimensions_ * GetDataTypeSize()`
2. If `normalize_` is set, normalize the query vector
3. Call `algo_->searchKnn()` with the optional `BaseFilterFunctor` and `CancelCondition`
4. Convert the priority queue result to a `vector<Neighbor>` via `CreateReply()`

The `BaseFilterFunctor` enables inline (post-filter) evaluation during HNSW graph traversal. When a filter is provided, hnswlib calls `filter->operator()(label)` for each candidate, skipping non-matching nodes during the beam search.

`CancelCondition` (local class in `vector_hnsw.cc`) adapts the `cancel::Token` to hnswlib's `BaseCancellationFunctor` interface, enabling timeout-based cancellation:

```cpp
class CancelCondition : public hnswlib::BaseCancellationFunctor {
  cancel::Token& token_;
  bool isCancelled() override { return token_->IsCancelled(); }
};
```

When `enable_partial_results` is false and cancellation fires, the search returns `CancelledError`. When true, partial results gathered before cancellation are returned.

## PrefilterEvaluator

`PrefilterEvaluator` (defined in `vector_base.h`) evaluates non-vector predicates (tag, numeric, text) against individual keys during pre-filtered vector search. It extends `query::Evaluator` and takes a `QueryOperations` bitmask at construction:

```cpp
class PrefilterEvaluator : public query::Evaluator {
  const text::TextIndex* text_index_;
  const InternedStringPtr* key_{nullptr};
  bool Evaluate(const query::Predicate& predicate, const InternedStringPtr& key);
  // Dispatches to per-type evaluation:
  query::EvaluationResult EvaluateTags(const query::TagPredicate&) override;
  query::EvaluationResult EvaluateNumeric(const query::NumericPredicate&) override;
  query::EvaluationResult EvaluateText(const query::TextPredicate&, bool) override;
};
```

Each method fetches the stored value for the current key from the respective index and evaluates the predicate. For example, `EvaluateTags()` calls `predicate.GetIndex()->GetValue(*key_, case_sensitive)` to retrieve the key's tags, then `predicate.Evaluate(tags, case_sensitive)`.

Pre-filtering works via `VectorBase::AddPrefilteredKey()` - instead of using hnswlib's graph search, it iterates candidate keys from scalar index results, computes distance for each via `ComputeDistanceFromRecord()`, and maintains a bounded priority queue of the top-k results.

## Record Lifecycle

**Add**: `VectorBase::AddRecord()` -> `InternVector()` (normalize if COSINE) -> `TrackKey()` assigns sequential `inc_id_` -> `AddRecordImpl()` -> `algo_->addPoint()`. On capacity overflow, retries after `ResizeIfFull()`. On failure, `UnTrackKey()` rolls back.

**Modify**: `VectorBase::ModifyRecord()` calls `UpdateMetadata()` which checks `IsVectorMatch()` and short-circuits if the vector is unchanged. Then `ModifyRecordImpl()` marks the old point deleted and adds a new point at the same label with `allow_replace_deleted_`:

```cpp
algo_->markDelete(internal_id);
algo_->addPoint((T*)record.data(), internal_id, algo_->allow_replace_deleted_);
```

The `updatePoint` API was considered but concerns about search accuracy led to the mark-delete-then-add approach.

**Remove**: `RemoveRecordImpl()` only calls `markDelete()` - vectors are never physically removed from the HNSW graph, only tombstoned. `UnTrackVector()` is a no-op for HNSW (unlike FLAT which erases from its map).

**Key tracking**: `VectorBase` maintains bidirectional maps between external keys and internal IDs (`key_by_internal_id_`, `tracked_metadata_by_key_`). `TrackedKeyMetadata` includes `internal_id` and `magnitude` (for COSINE denormalization; -1.0f when normalization is disabled).

## Concurrency Model

Two mutexes protect HNSW state:

- `resize_mutex_` (absl::Mutex) - reader/writer lock protecting `algo_`. Reads (search, add, remove, modify) take reader locks. Resize takes writer lock. This prevents search from seeing partially-resized state.
- `tracked_vectors_mutex_` - protects the `tracked_vectors_` deque used for vector identity tracking.

The parent `VectorBase` has `key_to_metadata_mutex_` protecting the key-to-ID maps.

hnswlib itself has internal locking (`label_lookup_lock`, per-element mutexes via `getLabelOpMutex()`). The `ABSL_NO_THREAD_SAFETY_ANALYSIS` annotations on some methods indicate they operate under hnswlib's internal locks rather than the class-level mutexes. The `hnswlib_helpers` namespace in `vector_hnsw.cc` provides `GetInternalId` (with lock) and `GetInternalIdLockFree`/`GetInternalIdDuringSearch` (without lock) wrappers.

Memory allocation: hnswlib code is compiled with `vmsdk/src/memory_allocation_overrides.h` which redirects `malloc`/`free` to Valkey's allocator. The include ordering is critical - the override header must come before hnswlib headers.

## RDB Persistence

`SaveIndexImpl()` delegates to `algo_->SaveIndex()` which writes the full hnswlib binary format via `RDBChunkOutputStream`. `LoadFromRDB()` constructs a new `HierarchicalNSW` and calls `LoadIndex()` from `RDBChunkInputStream`.

`ef_runtime` is not persisted in the hnswlib binary - it is restored from the protobuf `VectorIndex.hnsw_algorithm.ef_runtime` field after loading. `allow_replace_deleted_` is also re-applied from options after loading.

Tracked keys are saved/loaded separately via `VectorBase::SaveTrackedKeys()` / `LoadTrackedKeys()` using protobuf `TrackedKeyMetadata` messages containing key, internal_id, and magnitude. After loading, `inc_id_` is resumed from `GetMaxInternalLabel() + 1`.

## Key Implementation Details

- `GetMaxInternalLabel()` iterates `algo_->label_lookup_` under `label_lookup_lock` (includes tombstoned entries) to find the maximum label - used after RDB load to resume the `inc_id_` counter
- `GetLabelCount()` returns `label_lookup_.size()` under `label_lookup_lock` - includes both active and tombstoned entries
- `IsVectorMatch()` acquires both `resize_mutex_` and `getLabelOpMutex(internal_id)`, then compares stored vector data from `algo_->getDataByInternalId()` against the candidate - used by `UpdateMetadata()` to skip no-op modifications
- `ComputeDistanceFromRecordImpl()` uses `algo_->fstdistfunc_` to compute distance between a query and a stored vector - used for pre-filter scoring
- `RespondWithInfoImpl()` reports `data_type`, `algorithm name`, `m`, `ef_construction`, `ef_runtime` for `FT.INFO`
- Exception counters: `hnsw_create_exceptions_cnt`, `hnsw_add_exceptions_cnt`, `hnsw_modify_exceptions_cnt`, `hnsw_remove_exceptions_cnt`, `hnsw_search_exceptions_cnt` in `Metrics::GetStats()`
