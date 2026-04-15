# FLAT Brute-Force Vector Index

Use when working on the exact nearest neighbor vector index, modifying brute-force search, or understanding the FLAT index alternative to HNSW.

Source: `src/indexes/vector_flat.h`, `src/indexes/vector_flat.cc`, `src/indexes/vector_base.h`

## Class Overview

`VectorFlat<T>` is the brute-force (exact) vector search index. It wraps `hnswlib::BruteforceSearch<T>` and shares the `VectorBase` parent class with `VectorHNSW<T>`. FLAT provides exact KNN results with no graph overhead - every vector is compared during search.

## VectorFlat Template

```cpp
template <typename T>
class VectorFlat : public VectorBase {
  std::unique_ptr<hnswlib::BruteforceSearch<T>> algo_;
  std::unique_ptr<hnswlib::SpaceInterface<T>> space_;
  uint32_t block_size_;
  mutable absl::Mutex resize_mutex_;
  mutable absl::Mutex tracked_vectors_mutex_;
  absl::flat_hash_map<uint64_t, InternedStringPtr> tracked_vectors_;
};
// Only instantiation:
template class VectorFlat<float>;
```

Unlike HNSW's deque-based `tracked_vectors_`, FLAT uses a `flat_hash_map<uint64_t, InternedStringPtr>` keyed by internal ID. This enables actual deletion of tracked vectors (HNSW only tombstones them).

Creation via `VectorFlat<T>::Create()`:

```cpp
auto index = std::shared_ptr<VectorFlat<T>>(new VectorFlat<T>(
    vector_index_proto.dimension_count(),
    vector_index_proto.distance_metric(),
    vector_index_proto.flat_algorithm().block_size(),
    attribute_identifier, attribute_data_type));
index->Init(vector_index_proto.dimension_count(),
            vector_index_proto.distance_metric(), index->space_);
index->algo_ = std::make_unique<hnswlib::BruteforceSearch<T>>(
    index->space_.get(), vector_index_proto.initial_cap());
```

The `block_size` is read from the `FlatAlgorithm` protobuf and stored as `block_size_`. The private constructor also stores `distance_metric` via the `VectorBase` parent.

## Block-Size Capacity Growth

Like HNSW, FLAT starts at `initial_cap` and grows dynamically. When `AddRecordImpl()` catches the hnswlib capacity exception, it calls `ResizeIfFull()`:

```cpp
absl::Status VectorFlat<T>::ResizeIfFull() {
  {
    absl::ReaderMutexLock lock(&resize_mutex_);
    if (algo_->cur_element_count_ < GetCapacity()) {
      return absl::OkStatus();
    }
  }
  absl::WriterMutexLock lock(&resize_mutex_);
  std::unique_lock<std::mutex> index_lock(algo_->index_lock);
  if (algo_->cur_element_count_ == GetCapacity()) {
    algo_->resizeIndex(GetCapacity() + block_size_);
  }
  return absl::OkStatus();
}
```

Key differences from HNSW resize:
- FLAT acquires both `resize_mutex_` (writer) and `algo_->index_lock` (hnswlib internal)
- Growth is by the user-configured `block_size_` (not the global HNSW block size)
- Capacity is read from `algo_->data_->getCapacity()` via `GetCapacity()` rather than `algo_->max_elements_`
- No `allow_replace_deleted_` optimization - FLAT has true deletion
- Resize is logged at WARNING level via `VMSDK_LOG_EVERY_N_SEC`

## KNN Search

```cpp
absl::StatusOr<std::vector<Neighbor>> Search(
    absl::string_view query, uint64_t count,
    cancel::Token& cancellation_token,
    std::unique_ptr<hnswlib::BaseFilterFunctor> filter = nullptr);
```

The search flow:
1. Validate query vector size via `IsValidSizeVector()`
2. Normalize query if COSINE metric is configured
3. Acquire reader lock on `resize_mutex_`
4. Call `algo_->searchKnn()` with count capped at `algo_->cur_element_count_`
5. Convert result via `CreateReply()`

Notable differences from HNSW search:
- **No `ef_runtime` parameter** - brute force has no beam width to tune
- **No `enable_partial_results`** - brute force either completes or is cancelled
- **Count is clamped** to `min(count, cur_element_count_)` - prevents searching for more results than exist
- The reader lock is held for the entire search, not just validation

The `CancelCondition` wrapper is a separate local class in `vector_flat.cc` (structurally identical to the one in `vector_hnsw.cc`) - it adapts `cancel::Token` to `hnswlib::BaseCancellationFunctor`.

## Record Lifecycle

**Add**: Same parent flow as HNSW. `AddRecordImpl()` calls `algo_->addPoint()`. On capacity overflow, retries after `ResizeIfFull()`. Exception counter: `flat_add_exceptions_cnt`.

**Modify**: Unlike HNSW's mark-delete-then-add pattern, FLAT does an in-place update:

```cpp
absl::Status VectorFlat<T>::ModifyRecordImpl(uint64_t internal_id,
                                             absl::string_view record) {
  absl::ReaderMutexLock lock(&resize_mutex_);
  std::unique_lock<std::mutex> index_lock(algo_->index_lock);
  auto found = algo_->dict_external_to_internal.find(internal_id);
  // Direct memory copy: update label and data pointer
  memcpy((*algo_->data_)[found->second] + algo_->data_ptr_size_,
         &internal_id, sizeof(hnswlib::labeltype));
  *(char**)((*algo_->data_)[found->second]) = (char*)record.data();
  return absl::OkStatus();
}
```

This writes directly to the hnswlib internal data array, updating both the label and the pointer to the interned vector data.

**Remove**: `RemoveRecordImpl()` calls `algo_->removePoint()` which physically removes the entry (unlike HNSW's tombstone approach). This means FLAT's storage does not grow unboundedly with modifications. Exception counter: `flat_remove_exceptions_cnt`.

## Vector Tracking

FLAT tracks vectors by internal ID in a `flat_hash_map`:

```cpp
void TrackVector(uint64_t internal_id, const InternedStringPtr& vector) {
  absl::MutexLock lock(&tracked_vectors_mutex_);
  tracked_vectors_[internal_id] = vector;
}

void UnTrackVector(uint64_t internal_id) {
  absl::MutexLock lock(&tracked_vectors_mutex_);
  tracked_vectors_.erase(internal_id);
}
```

`IsVectorMatch()` compares the interned string contents via `it->second->Str() == vector->Str()`, enabling the parent `UpdateMetadata()` to detect no-op modifications and skip unnecessary work.

## Concurrency Model

Two mutexes protect FLAT state:

- `resize_mutex_` (absl::Mutex) - reader/writer lock protecting `algo_`. Search and add take reader locks. Resize takes writer lock.
- `tracked_vectors_mutex_` - protects the tracked vectors map.

Modify additionally acquires `algo_->index_lock` (an internal `std::mutex`) to protect the in-place data update. This is stricter than HNSW's modify which only needs the resize reader lock.

The parent `VectorBase::key_to_metadata_mutex_` protects the key-to-ID mapping as with HNSW.

Memory allocation overrides: Same as HNSW - `memory_allocation_overrides.h` must be included before `bruteforce.h` and `hnswlib.h` to route hnswlib allocations through Valkey's allocator.

## RDB Persistence

`SaveIndexImpl()` delegates to `algo_->SaveIndex()` with `RDBChunkOutputStream`. `LoadFromRDB()` constructs a new `BruteforceSearch` and calls `LoadIndex()`.

Unlike HNSW, FLAT does not persist `ef_runtime` (there is none). The `block_size` is stored in the `FlatAlgorithm` protobuf message and restored on load. `RespondWithInfoImpl()` reports `data_type`, `algorithm name`, and `block_size` for `FT.INFO`.

## FLAT vs HNSW Comparison

| Aspect | FLAT | HNSW |
|--------|------|------|
| Search accuracy | Exact KNN | Approximate (tunable via ef_runtime) |
| Search complexity | O(n) | O(log n) typical |
| Deletion | Physical removal (`removePoint`) | Tombstone only (`markDelete`) |
| Modify strategy | In-place memory update | Mark-delete + re-add |
| Tracked vectors storage | `flat_hash_map<uint64_t, InternedStringPtr>` | `deque<InternedStringPtr>` |
| Capacity growth | `block_size` from FlatAlgorithm proto | Global HNSW block size |
| Tuning parameters | None (block_size is structural) | M, ef_construction, ef_runtime |
| Search parameters | count, filter | count, filter, ef_runtime, partial results |
| `GetMaxInternalLabel` | Not implemented (returns 0) | Iterates `label_lookup_` |
