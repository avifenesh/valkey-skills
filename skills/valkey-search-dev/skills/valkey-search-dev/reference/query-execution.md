# Search execution

Use when reasoning about how queries execute, prefilter vs inline filtering, async dispatch, content resolution, or contention checking.

Source: `src/query/search.{h,cc}`, `src/query/planner.{h,cc}`, `src/query/content_resolution.h`.

## Thread split

Index data reads fine on background threads. **Document content fetch requires the main thread** (Valkey keyspace is single-threaded).

`SearchParameters` carries state through the pipeline: parsed filter, index schema, limit/offset, timeout, cancellation token, eventual `SearchResult`.

## Entry points

```cpp
absl::Status Search(SearchParameters&, SearchMode);
absl::Status SearchAsync(unique_ptr<SearchParameters>, ThreadPool*, SearchMode);
```

`SearchAsync` is normal for FT.SEARCH / FT.AGGREGATE. `QueryCommand::Execute` blocks the client, builds a cancel token with timeout, calls `SearchAsync`. `SearchMode`: `kLocal` (direct) vs `kRemote` (coordinator-dispatched shard query - checks OOM).

Both call `DoSearch()`, which takes `ReaderMutexLock` on the index's time-sliced mutex.

## Non-vector flow (`SearchNonVectorQuery`)

1. `EvaluateFilterAsPrimary()` walks predicate tree, builds `EntriesFetcherBase` objects from each leaf's index.
2. `IsUnsolvedQuery()` - true when AND combines numeric/tag OR when negation is present.
3. **Simple path** (no prefilter needed): iterate fetchers directly, collect matching keys as `Neighbor`s (distance 0), dedupe if OR/tag/negation.
4. **Complex path**: `EvaluatePrefilteredKeys()` iterates and evaluates the full predicate against each key via `PrefilterEvaluator`.
5. `max-nonvector-search-results-fetched` (default 100000) caps collected keys; overflow bumps `nonvector_results_fetched_limited_count`.

`MaybeAddIndexedContent()` populates attributes from index data where possible (tag values, numeric values, vector blobs) to skip main-thread fetches.

## Vector flow

1. Resolve vector attribute -> `indexes::VectorBase*` (`VectorHNSW<float>` or `VectorFlat<float>`).
2. No filter (bare `*`) -> `PerformVectorSearch()` without filter.
3. With filter -> `EvaluateFilterAsPrimary()` + consult planner for prefilter vs inline.

`PerformVectorSearch()` dispatches:

- HNSW: `VectorHNSW::Search(query_vec, K, cancel, filter?, ef_runtime?)`.
- FLAT: `VectorFlat::Search(query_vec, K, cancel, filter?)`.

Returns `StatusOr<vector<Neighbor>>`, distance-sorted.

## Prefilter vs inline (`planner.cc::UsePreFiltering`)

- **FLAT**: always prefilter. Flat is O(N * log K); prefilter reduces to O(n * log K) where n << N - always a win.
- **HNSW**: prefilter when `estimated_num_of_keys <= GetPrefilteringThresholdRatio() * vector_index->GetTrackedKeyCount()`.

Threshold is `prefiltering-threshold-ratio` config. Very selective filter -> prefilter avoids graph walk. Broad filter -> inline lets HNSW guide.

Metrics: `query_prefiltering_requests_cnt` vs `query_inline_filtering_requests_cnt`.

## Prefilter path

1. `CalcBestMatchingPrefilteredKeys()` iterates entry fetchers.
2. Per candidate: `PrefilterEvaluator` evaluates full predicate tree.
3. Matching keys: `vector_index->AddPrefilteredKey()` - max-heap of K best `(key, distance)`.
4. Heap -> `vector<Neighbor>` via `vector_index->CreateReply()`.

**Exact** nearest-neighbor on the filtered subset (no HNSW approximation). Expensive on large filtered sets - hence the planner threshold.

Dedup uses `flat_hash_set<const char*>` on interned pointers. `NeedsDeduplication()` = OR/tag/non-text-negation.

## Inline path

1. `PerformVectorSearch()` creates `InlineVectorFilter` functor.
2. Functor implements `hnswlib::BaseFilterFunctor::operator()(labeltype id)`.
3. Per candidate during HNSW walk: `vector_index->GetKeyDuringSearch(id)`, per-key text index lookup if needed, `PrefilterEvaluator::Evaluate`.
4. Filter fails -> HNSW skips the candidate.

`lock.SetMayProlong()` before inline search warns the time-sliced mutex (longer than usual; adjusts contention behavior).

## `EvaluateFilterAsPrimary`

Builds the "primary" scan path.

- **Composed AND** - try a combined `TextIterator` via `BuildTextIterator()`; success wraps in `TextIteratorFetcher`. Else recurse and pick child with smallest estimated size (smallest index = fastest scan).
- **Composed OR** - recurse all children, concatenate fetcher queues. Size = sum.
- **Tag / numeric leaf** - `index->Search(predicate, negate)`.
- **Text leaf** - `indexes::Text::EntriesFetcher` with estimated size + field mask.
- **Negate** - recurse with flipped flag. Special: text + negate -> `UniversalSetFetcher` over all schema keys (can't be efficient from postings).

## Async dispatch

```
Main                                  Reader pool
 |                                     |
 SearchAsync --------------------> Schedule(lambda)
 |   (block client)                    |
 |                                     DoSearch  [ReaderMutexLock]
 |                                     MaybeAddIndexedContent
 |                                     |
 |                                     kNoContent    -> QueryCompleteBackground
 |                                     kContentReq   -> RunByMain(ResolveContent)
 |                                     |
 ResolveContent <----------------------  (RunByMain)
 |   ProcessNeighborsForReply
 |   QueryCompleteMainThread
 |   unblock client
```

`cancel::Token` checked periodically; cancellation cooperative (HNSW walk, fetcher iteration poll the token).

## Content resolution (main thread)

`ProcessNeighborsForReply()` (`response_generator.h`):

1. For each neighbor, fetch Hash/JSON from keyspace.
2. Populate `attribute_contents`.
3. Drop neighbors whose keys no longer exist (deleted mid-search).
4. Validate against in-flight mutations.

Neighbors already populated by `MaybeAddIndexedContent()` on the background thread are skipped.

## `ContentProcessing` modes

`SearchParameters::GetContentProcessing()`:

| Mode | When | Completion |
|------|------|------------|
| `kNoContent` | NOCONTENT, or all content from indexes | `QueryCompleteBackground()` (stays on reader) |
| `kContentRequired` | keyspace needed, no contention | `QueryCompleteMainThread()` via `RunByMain` |
| `kContentionCheckRequired` | keyspace needed + mutations possibly in flight | `ResolveContent()` via `RunByMain` with seq checks |

`kContentAvailable` reserved - all content sourced from indexes, no main-thread hop.

## Contention check

Sequence-number based:

1. `PopulateIndexMutationSequenceNumbers()` records current seq per neighbor key during search.
2. Main thread `ResolveContent()` checks for advances.
3. Advanced -> re-validate content fetch.
4. `content_resolution_blocked_` counts block events.

Final response is a consistent snapshot - mid-path modifications are detected.

## Result trimming

`SearchResult` trims on the background thread when possible:

- `TrimResults()` applies LIMIT offset/count with `search-result-buffer-multiplier`.
- Standalone: trim-from-front (offset) immediately.
- Cluster: shards keep full set for coordinator merge; coordinator trims after merge.
- `GetSerializationRange()` -> final `[start, end)`.

`ShouldReturnNoResults()` short-circuits when `limit.number == 0` or vector with `limit.first_index >= k`.

Timeouts: default `kTimeoutMS = 50s`, max `kMaxTimeoutMs = 60s`. Default LIMIT: offset 0, count 10.
