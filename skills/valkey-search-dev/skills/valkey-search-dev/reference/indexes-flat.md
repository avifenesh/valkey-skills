# FLAT brute-force vector index

Use when reasoning about exact KNN, in-place modify, or the FLAT alternative to HNSW.

Source: `src/indexes/vector_flat.{h,cc}`, `src/indexes/vector_base.h`.

## `VectorFlat<T>`

```cpp
template <typename T>
class VectorFlat : public VectorBase {
  std::unique_ptr<hnswlib::BruteforceSearch<T>> algo_;
  std::unique_ptr<hnswlib::SpaceInterface<T>>   space_;
  uint32_t block_size_;
  mutable absl::Mutex resize_mutex_;
  mutable absl::Mutex tracked_vectors_mutex_;
  absl::flat_hash_map<uint64_t, InternedStringPtr> tracked_vectors_;
};
template class VectorFlat<float>;
```

Only instantiated for `float`. Shares `VectorBase` with HNSW. Differs from HNSW's `deque<InternedStringPtr>` - FLAT uses a `flat_hash_map` keyed by internal ID (enables actual deletion; HNSW only tombstones).

Creation (`Create`): reads `dimension_count`, `distance_metric`, `flat_algorithm.block_size`, constructs `BruteforceSearch` with `initial_cap`.

## Resize

`AddRecordImpl` catches capacity exception, calls `ResizeIfFull()`:

1. R-lock: compare `algo_->cur_element_count_` vs `GetCapacity()`.
2. Full -> W-lock on `resize_mutex_` **and** `algo_->index_lock` (internal `std::mutex`).
3. Re-check, then `algo_->resizeIndex(GetCapacity() + block_size_)`.

Differences from HNSW resize:

- Two locks taken (class mutex + hnswlib internal).
- Block size = user-configured `block_size_` (FlatAlgorithm proto), **not** the global HNSW block size.
- Capacity via `algo_->data_->getCapacity()` / `GetCapacity()` (not `max_elements_`).
- No `allow_replace_deleted_` - FLAT has true deletion, no need.
- Resize logged via `VMSDK_LOG_EVERY_N_SEC` WARNING.

## KNN search

```cpp
absl::StatusOr<std::vector<Neighbor>> Search(
    absl::string_view query, uint64_t count,
    cancel::Token& cancellation_token,
    std::unique_ptr<hnswlib::BaseFilterFunctor> filter = nullptr);
```

Flow: `IsValidSizeVector()`, normalize if COSINE, R-lock on `resize_mutex_` held for entire search, `algo_->searchKnn(count capped at cur_element_count_)`, convert via `CreateReply()`.

Differences from HNSW:

- **No `ef_runtime`** - brute force has no beam width.
- **No `enable_partial_results`** - all-or-cancelled.
- `count` clamped to `min(count, cur_element_count_)`.
- R-lock held for the full search, not just validation.

`CancelCondition` is a structurally identical local class duplicated in `vector_flat.cc` (not shared with HNSW).

## Record lifecycle

- **Add**: parent flow same as HNSW. `algo_->addPoint()`, retry on overflow via `ResizeIfFull()`. Exception counter `flat_add_exceptions_cnt`.
- **Modify** (in-place, unlike HNSW's mark-delete + re-add):
  ```cpp
  R-lock resize_mutex_; std::unique_lock index_lock(algo_->index_lock);
  auto found = algo_->dict_external_to_internal.find(internal_id);
  memcpy((*algo_->data_)[found->second] + algo_->data_ptr_size_, &internal_id, sizeof(hnswlib::labeltype));
  *(char**)((*algo_->data_)[found->second]) = (char*)record.data();
  ```
  Writes directly to hnswlib internal data: updates label and interned-vector pointer.
- **Remove**: `algo_->removePoint()` - **physical removal** (unlike HNSW tombstones). FLAT storage does not grow unboundedly with modifications. Exception counter `flat_remove_exceptions_cnt`.

## Vector tracking

```cpp
TrackVector(id, ptr)   -> tracked_vectors_[id] = ptr;
UnTrackVector(id)      -> tracked_vectors_.erase(id);
IsVectorMatch(id, v)   -> it->second->Str() == v->Str();  // parent UpdateMetadata no-op shortcut
```

Under `tracked_vectors_mutex_`.

## Concurrency

- `resize_mutex_` - R-lock for search/add, W-lock for resize.
- `tracked_vectors_mutex_` - the tracked map.
- Modify additionally takes `algo_->index_lock` (stricter than HNSW modify which only needs the R-lock).
- Parent `VectorBase::key_to_metadata_mutex_` for the key-to-ID map.

Allocation overrides: same as HNSW - `memory_allocation_overrides.h` must be included before `bruteforce.h` / `hnswlib.h`.

## RDB

`SaveIndexImpl()` -> `algo_->SaveIndex(RDBChunkOutputStream)`. `LoadFromRDB()` constructs `BruteforceSearch`, `LoadIndex(RDBChunkInputStream)`.

No `ef_runtime` persistence (N/A). `block_size` persists in `FlatAlgorithm` proto. `RespondWithInfoImpl()` reports `data_type`, algorithm name, `block_size` for FT.INFO.

## FLAT vs HNSW

| Aspect | FLAT | HNSW |
|--------|------|------|
| Accuracy | exact KNN | approximate (tunable `ef_runtime`) |
| Complexity | O(n) | O(log n) typical |
| Deletion | physical (`removePoint`) | tombstone (`markDelete`) |
| Modify | in-place memory write | mark-delete + re-add |
| Tracked vectors | `flat_hash_map<uint64_t, InternedStringPtr>` | `deque<InternedStringPtr>` |
| Growth | `block_size` from FlatAlgorithm proto | global HNSW block size |
| Tuning | none (block_size is structural) | M, ef_construction, ef_runtime |
| Search args | count, filter | count, filter, ef_runtime, partial_results |
| `GetMaxInternalLabel` | not implemented (returns 0) | iterates `label_lookup_` |
