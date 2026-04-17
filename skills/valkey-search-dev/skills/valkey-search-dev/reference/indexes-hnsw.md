# HNSW vector index

Use when reasoning about ANN vector search, HNSW graph parameters, or hnswlib integration.

Source: `src/indexes/vector_hnsw.{h,cc}`, `src/indexes/vector_base.{h,cc}`, `third_party/hnswlib/hnswalg.h`.

## Class hierarchy

```
IndexBase
  -> VectorBase + hnswlib::VectorTracker
       -> VectorHNSW<T>  (src/indexes/vector_hnsw.h)
       -> VectorFlat<T>  (src/indexes/vector_flat.h)
```

## `VectorHNSW<T>`

Template instantiated only for `float` (FLOAT32). Wraps `hnswlib::HierarchicalNSW<T>`.

```cpp
template <typename T>
class VectorHNSW : public VectorBase {
  std::unique_ptr<hnswlib::HierarchicalNSW<T>> algo_;
  std::unique_ptr<hnswlib::SpaceInterface<T>>  space_;
  mutable absl::Mutex resize_mutex_;
  mutable absl::Mutex tracked_vectors_mutex_;
  std::deque<InternedStringPtr> tracked_vectors_;
};
template class VectorHNSW<float>;
```

`Create()` reads `dimension_count`, `distance_metric`, and `hnsw_algorithm.{m, ef_construction, ef_runtime}` from the `VectorIndex` proto. Passes `initial_cap` to the `HierarchicalNSW` constructor. `allow_replace_deleted_` is **hardcoded `false`** on 1.2.0 (source TODO: "Consider making `allow_replace_deleted_` configurable") - aligns with RediSearch behavior.

## HNSW parameters

| Parameter | Accessor | Effect |
|-----------|----------|--------|
| `M` | `GetM()` | max bi-directional links per node per layer; higher M = better recall, more memory |
| `ef_construction` | `GetEfConstruction()` | search width during build; higher = better graph quality, slower insert |
| `ef_runtime` | `GetEfRuntime()` | search width at query time; higher = better recall, slower query; adjustable post-creation |

Stored on `algo_` (`M_`, `ef_construction_`, `ef_`). Set at `Create()` time:

```cpp
index->algo_ = std::make_unique<hnswlib::HierarchicalNSW<T>>(
    index->space_.get(), proto.initial_cap(),
    hnsw_proto.m(), hnsw_proto.ef_construction());
index->algo_->setEf(hnsw_proto.ef_runtime());
```

`ef_runtime` is per-query overridable: `Search()` takes `optional<size_t> ef_runtime`.

## Distance metrics (`kDistanceMetricByStr`)

| Metric | hnswlib space | Notes |
|--------|---------------|-------|
| `L2` | `L2Space` | Euclidean, no normalization |
| `IP` | `InnerProductSpace` | no normalization |
| `COSINE` | `InnerProductSpace` | vectors normalized on insert; `normalize_ = true`; query normalized before search |

Space created in `VectorBase::Init()` via local `CreateSpace<T>()`. `NormalizeEmbedding()` (free in `vector_base.cc`) computes L2 magnitude and divides via `CopyAndNormalizeEmbedding`, optionally returning the magnitude for later denormalization when reading stored vectors.

## Dynamic resize

HNSW starts at `initial_cap`, grows on capacity overflow. `AddRecordImpl()` catches the "exceeds limit" exception and calls `ResizeIfFull()`:

Double-checked locking: read-lock check -> write-lock re-check -> `algo_->resizeIndex(current + block_size)`. Block size from `ValkeySearch::Instance().GetHNSWBlockSize()`.

- **hnswlib does not shrink** - capacity only grows.
- `allow_replace_deleted_` (hardcoded `false` on 1.2.0) would reuse deleted slots before resize if enabled.
- Duration logged at WARNING via `vmsdk::StopWatch`.

## Search with inline filtering

```cpp
absl::StatusOr<std::vector<Neighbor>> Search(
    absl::string_view query, uint64_t count,
    cancel::Token& cancellation_token,
    std::unique_ptr<hnswlib::BaseFilterFunctor> filter = nullptr,
    std::optional<size_t> ef_runtime = std::nullopt,
    bool enable_partial_results = false);
```

Flow: validate size (`dimensions_ * data_type_size`), normalize query if `normalize_`, `algo_->searchKnn(filter, cancel_condition)`, convert result via `CreateReply()`.

`BaseFilterFunctor` enables inline (post-filter) evaluation: hnswlib calls `filter(label)` on each candidate during beam search, skipping non-matches.

`CancelCondition` (local class in `vector_hnsw.cc`) adapts `cancel::Token` to hnswlib's `BaseCancellationFunctor`. On cancellation: `CancelledError` when `enable_partial_results=false`, partial results when true.

## `PrefilterEvaluator` (`vector_base.h`)

Extends `query::Evaluator`. Evaluates non-vector predicates against individual keys during pre-filtered vector search:

```cpp
class PrefilterEvaluator : public query::Evaluator {
  const text::TextIndex* text_index_;
  const InternedStringPtr* key_{nullptr};
  bool Evaluate(const query::Predicate&, const InternedStringPtr& key);
  query::EvaluationResult EvaluateTags   (const query::TagPredicate&)      override;
  query::EvaluationResult EvaluateNumeric(const query::NumericPredicate&)  override;
  query::EvaluationResult EvaluateText   (const query::TextPredicate&, bool) override;
};
```

Per-method path fetches stored value from the relevant index (e.g. `predicate.GetIndex()->GetValue(*key_, case_sensitive)`), then evaluates.

Pre-filter flow: `VectorBase::AddPrefilteredKey()` iterates candidate keys from scalar-index results, calls `ComputeDistanceFromRecord()` per key, maintains bounded priority queue of top-k. Skips hnswlib graph search entirely.

## Record lifecycle

- **Add**: `VectorBase::AddRecord()` -> `InternVector()` (normalize if COSINE) -> `TrackKey()` assigns `inc_id_` -> `AddRecordImpl()` -> `algo_->addPoint()`. Overflow retries after `ResizeIfFull()`. Failure rolls back via `UnTrackKey()`.
- **Modify**: `ModifyRecord` -> `UpdateMetadata` -> `IsVectorMatch()` (no-op shortcut) -> `ModifyRecordImpl` marks old point deleted, re-adds at same label (passing `algo_->allow_replace_deleted_` which is hardcoded `false`):
  ```cpp
  algo_->markDelete(internal_id);
  algo_->addPoint(record.data(), internal_id, algo_->allow_replace_deleted_);
  ```
  (hnswlib has `updatePoint` but search-accuracy concerns drove the mark-delete + re-add approach.)
- **Remove**: `RemoveRecordImpl` only calls `markDelete()` - **tombstoned, never physically removed**. `UnTrackVector` is a no-op for HNSW (FLAT erases its map).
- **Key tracking** (`VectorBase`): bidirectional maps `key_by_internal_id_` / `tracked_metadata_by_key_`. `TrackedKeyMetadata` holds `internal_id` + `magnitude` (COSINE denormalization; `-1.0f` when not normalizing).

## Concurrency

| Mutex | Protects |
|-------|----------|
| `resize_mutex_` (absl) | `algo_`. R-lock for search/add/remove/modify. W-lock for resize. Prevents search from seeing partially-resized state. |
| `tracked_vectors_mutex_` | `tracked_vectors_` deque |
| parent `VectorBase::key_to_metadata_mutex_` | key-to-ID maps |

hnswlib has its own internal locks (`label_lookup_lock`, per-element mutex via `getLabelOpMutex()`). Methods annotated with `ABSL_NO_THREAD_SAFETY_ANALYSIS` operate under hnswlib's internal locks instead of class-level mutexes. `hnswlib_helpers` namespace provides `GetInternalId` (with lock) vs `GetInternalIdLockFree` / `GetInternalIdDuringSearch` wrappers.

**Memory allocation**: hnswlib compiled against `vmsdk/src/memory_allocation_overrides.h` which redirects `malloc`/`free` to Valkey's allocator. **Include order is critical** - override header must precede hnswlib headers.

## RDB persistence

- `SaveIndexImpl()` -> `algo_->SaveIndex(RDBChunkOutputStream)` - full hnswlib binary format.
- `LoadFromRDB()` -> construct `HierarchicalNSW`, `LoadIndex(RDBChunkInputStream)`.
- `ef_runtime` NOT in binary - restored from proto `VectorIndex.hnsw_algorithm.ef_runtime` post-load.
- `allow_replace_deleted_` re-hardcoded to `false` post-load (on 1.2.0; when made configurable this would read from options).
- Tracked keys via `VectorBase::SaveTrackedKeys()` / `LoadTrackedKeys()` using `TrackedKeyMetadata` protos (key, internal_id, magnitude).
- After load, `inc_id_` resumes from `GetMaxInternalLabel() + 1`.

## Implementation notes

- `GetMaxInternalLabel()` - iterates `algo_->label_lookup_` under `label_lookup_lock` (includes tombstones); used post-load to resume `inc_id_`.
- `GetLabelCount()` = `label_lookup_.size()` under the lock (active + tombstoned).
- `IsVectorMatch()` - takes both `resize_mutex_` and `getLabelOpMutex(internal_id)`, compares bytes via `algo_->getDataByInternalId()`; drives `UpdateMetadata` no-op shortcut.
- `ComputeDistanceFromRecordImpl()` uses `algo_->fstdistfunc_` for pre-filter scoring.
- `RespondWithInfoImpl()` reports `data_type`, algorithm name, `m`, `ef_construction`, `ef_runtime` for FT.INFO.
- Exception counters: `hnsw_{create,add,modify,remove,search}_exceptions_cnt` in `Metrics::GetStats()`.
