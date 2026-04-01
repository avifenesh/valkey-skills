# Search Execution Flow

Use when understanding how queries execute, the prefilter vs inline filtering decision, async dispatch, content resolution, or contention checking.

Source: `src/query/search.h`, `src/query/search.cc`, `src/query/planner.h`, `src/query/planner.cc`, `src/query/content_resolution.h`

## Contents

- Execution Overview (line 24)
- Entry Points (line 30)
- Non-Vector Query Flow (line 47)
- Vector Query Flow (line 59)
- Prefilter vs Inline Decision (line 79)
- Prefilter Path (line 100)
- Inline Filter Path (line 113)
- EvaluateFilterAsPrimary (line 124)
- Async Dispatch and Threading (line 138)
- Content Resolution on Main Thread (line 163)
- ContentProcessing Modes (line 177)
- Contention Checking (line 189)
- Result Trimming and Serialization (line 200)

## Execution Overview

Search execution starts on the main thread (command handler), dispatches to a reader thread pool for the actual search, and may return to the main thread for content resolution. Index data can be read on background threads, but fetching document content from Valkey's keyspace requires the main thread.

The `SearchParameters` struct (in `search.h`) carries all state through the pipeline: parsed filter, index schema reference, limit/offset, timeout, cancellation token, and the eventual `SearchResult`.

## Entry Points

Two entry points in `search.h`:

```cpp
// Synchronous - runs search and populates parameters.search_result
absl::Status Search(SearchParameters& parameters, SearchMode search_mode);

// Async - schedules search on thread pool, calls QueryComplete* when done
absl::Status SearchAsync(unique_ptr<SearchParameters> parameters,
                         ThreadPool* thread_pool, SearchMode search_mode);
```

`SearchAsync` is the normal path for FT.SEARCH and FT.AGGREGATE commands. The `QueryCommand::Execute` method blocks the client, creates a cancellation token with timeout, and calls `SearchAsync`. `SearchMode` distinguishes `kLocal` (direct query) from `kRemote` (coordinator-dispatched shard query, which checks OOM).

Both paths call `DoSearch()` internally, which acquires a `ReaderMutexLock` on the index schema's time-sliced mutex. This lock allows concurrent reads but coordinates with write mutations.

## Non-Vector Query Flow

When `parameters.IsNonVectorQuery()` is true (no vector attribute alias), `DoSearch()` calls `SearchNonVectorQuery()`:

1. **Build entry fetchers** - `EvaluateFilterAsPrimary()` walks the predicate tree and creates `EntriesFetcherBase` objects from each leaf predicate's index (tag, numeric, or text)
2. **Check if prefilter evaluation needed** - `IsUnsolvedQuery()` returns true when the query combines AND with numeric/tag predicates or uses negation
3. **Simple path** (no prefilter needed) - iterate fetchers directly, collect matching keys into a `Neighbor` vector, deduplicate if needed (OR/tag/negation)
4. **Complex path** (prefilter needed) - call `EvaluatePrefilteredKeys()` which iterates fetcher results and evaluates the full predicate tree against each key using `PrefilterEvaluator`
5. **Fetch limit** - `max-nonvector-search-results-fetched` config (default 100000) caps how many keys are accumulated. When exceeded, iteration stops early and the `nonvector_results_fetched_limited_count` metric increments

Results are `Neighbor` structs with `distance = 0.0f` (no vector score). The `MaybeAddIndexedContent()` step attempts to populate attribute content from index data directly (tag values, numeric values, vector blobs) to avoid main-thread content fetches where possible.

## Vector Query Flow

When the query includes a vector attribute (KNN clause), `DoSearch()` follows this path:

1. **Look up vector index** - resolves `attribute_alias` to an `indexes::VectorBase*` (either `VectorHNSW<float>` or `VectorFlat<float>`)
2. **No filter** - if `root_predicate` is null (bare `*` or no filter expression), call `PerformVectorSearch()` directly with no filter functor
3. **With filter** - build entry fetchers via `EvaluateFilterAsPrimary()`, then consult the query planner

The planner decides between two strategies:

- **Prefilter** - reduce the candidate set first, then do exact nearest-neighbor on the reduced set
- **Inline** - run the full vector search (HNSW graph walk or flat scan) with a filter callback that evaluates each candidate

`PerformVectorSearch()` handles both HNSW and FLAT index types:

- **HNSW** - calls `VectorHNSW::Search()` with the query vector, K, cancellation token, optional inline filter, and optional `ef_runtime` override
- **FLAT** - calls `VectorFlat::Search()` with query vector, K, cancellation token, optional inline filter

Both return `StatusOr<vector<Neighbor>>` with neighbors sorted by distance.

## Prefilter vs Inline Decision

`UsePreFiltering()` in `planner.cc` makes the decision based on heuristics:

```cpp
bool UsePreFiltering(size_t estimated_num_of_keys,
                     indexes::VectorBase* vector_index);
```

**FLAT index** - always prefilter. Rationale: flat search is O(N * log(K)). With prefiltering the reduced space is O(n * log(K)) where n << N, so prefiltering is always beneficial.

**HNSW index** - prefilter when the estimated filtered key count is below a threshold ratio of the total index size:

```cpp
estimated_num_of_keys <= GetPrefilteringThresholdRatio() * N
```

Where `N = vector_index->GetTrackedKeyCount()` (actual vectors in the index, not capacity). The threshold ratio is configurable via `prefiltering-threshold-ratio`. When the filter is very selective (few candidates), prefiltering avoids traversing the HNSW graph. When the filter is broad, inline filtering lets the HNSW graph guide the search.

Metrics track which path was taken: `query_prefiltering_requests_cnt` vs `query_inline_filtering_requests_cnt`.

## Prefilter Path

When prefiltering is chosen for vector queries:

1. `CalcBestMatchingPrefilteredKeys()` iterates all entry fetchers
2. For each candidate key from the fetchers, `PrefilterEvaluator` evaluates the full predicate tree
3. Matching keys are scored against the query vector via `vector_index->AddPrefilteredKey()`, which maintains a max-heap of K best (key, distance) pairs
4. The heap result is converted to `vector<Neighbor>` via `vector_index->CreateReply()`

This path does exact nearest-neighbor search on the filtered subset - no HNSW approximation. For large filtered sets this can be expensive, which is why the planner only chooses it when the estimated set is small relative to the total.

Deduplication during prefilter evaluation uses a `flat_hash_set<const char*>` of interned string pointers. The `NeedsDeduplication()` helper checks if OR, tag, or non-text negation operations are present.

## Inline Filter Path

When inline filtering is chosen:

1. `PerformVectorSearch()` creates an `InlineVectorFilter` functor
2. The functor implements `hnswlib::BaseFilterFunctor::operator()(labeltype id)`
3. For each candidate during the HNSW graph walk, it resolves the key via `vector_index->GetKeyDuringSearch(id)`, looks up the per-key text index if needed, and creates a `PrefilterEvaluator` to evaluate the full predicate tree
4. Candidates failing the filter are skipped by the HNSW algorithm

The `lock.SetMayProlong()` call before inline search warns the time-sliced mutex that this operation may take longer than usual, adjusting contention behavior.

## EvaluateFilterAsPrimary

This function walks the predicate tree to build `EntriesFetcherBase` queues - the "primary" scan path that determines which keys to examine:

**Composed AND** - first tries to build a combined `TextIterator` via `BuildTextIterator()`. If successful, wraps it in a `TextIteratorFetcher`. Otherwise, recursively evaluates each child and picks the one with the smallest estimated size (smallest index = fastest scan).

**Composed OR** - recursively evaluates all children and concatenates their fetcher queues. Total estimated size is the sum of children.

**Tag/Numeric leaf** - calls `index->Search(predicate, negate)` to get a fetcher from the inverted index.

**Text leaf** - creates an `indexes::Text::EntriesFetcher` with estimated size and field mask.

**Negate** - recurses with the `negate` flag flipped. Special case: text + negate queries use a `UniversalSetFetcher` that iterates all keys in the schema, since negated text cannot be efficiently fetched from postings lists.

## Async Dispatch and Threading

`SearchAsync` schedules work on the reader thread pool at high priority:

```
Main Thread                    Reader Thread Pool
  |                                |
  +-- SearchAsync() ------------> Schedule(lambda)
  |   (blocks client)              |
  |                                +-- Search()
  |                                |   +-- DoSearch() [holds ReaderMutexLock]
  |                                |   +-- MaybeAddIndexedContent()
  |                                |
  |                                +-- Check ContentProcessing
  |                                |   kNoContent -> QueryCompleteBackground()
  |                                |   kContentRequired -> RunByMain(ResolveContent)
  |                                |
  +-- ResolveContent() <---------- RunByMain callback
  |   +-- ProcessNeighborsForReply()
  |   +-- QueryCompleteMainThread()
  |   +-- Unblock client
```

The `cancel::Token` is checked periodically during search to enforce the timeout. Cancellation is cooperative - long-running operations (HNSW walk, fetcher iteration) check the token.

## Content Resolution on Main Thread

After background search completes, if content is needed (document attributes to return to the client), execution returns to the main thread via `ResolveContent()`:

`ProcessNeighborsForReply()` (in `response_generator.h`) fetches document content from Valkey's keyspace for each neighbor. This requires the main thread because Valkey key access is single-threaded. The function:

1. Iterates neighbors
2. For each neighbor, fetches the hash/JSON document from Valkey
3. Populates `attribute_contents` on each `Neighbor` struct
4. Removes neighbors whose keys no longer exist (deleted between search and content fetch)
5. Validates against contention with in-flight mutations

Neighbors that already have `attribute_contents` populated (from `MaybeAddIndexedContent()` on the background thread) are skipped.

## ContentProcessing Modes

`SearchParameters::GetContentProcessing()` determines what happens after the background search:

| Mode | When | Completion |
|------|------|------------|
| `kNoContent` | NOCONTENT flag, or all content sourced from indexes | `QueryCompleteBackground()` - stays on reader thread |
| `kContentRequired` | Need keyspace access but no contention risk | `QueryCompleteMainThread()` via `RunByMain` |
| `kContentionCheckRequired` | Need keyspace access and mutations may be in flight | `ResolveContent()` via `RunByMain` with sequence number checks |

The `kContentAvailable` mode is reserved for future use where all needed content can be sourced directly from indexes without main-thread access.

## Contention Checking

Between the background search and main-thread content fetch, mutations may have modified or deleted documents. The contention checking mechanism uses sequence numbers:

1. `PopulateIndexMutationSequenceNumbers()` records the current mutation sequence number for each neighbor's key during the search phase
2. On the main thread, `ResolveContent()` checks if any key's sequence number has advanced
3. If contention is detected, the content fetch may need to re-validate results
4. `content_resolution_blocked_` tracks how many times a query was blocked during this process

The final response reflects a consistent snapshot - if a document was modified after the search but before content fetch, the system detects and handles it.

## Result Trimming and Serialization

`SearchResult` handles result trimming in the background thread when possible:

- `TrimResults()` applies LIMIT offset/count with a configurable buffer multiplier (`search-result-buffer-multiplier`)
- In standalone mode, trimming from the front (offset) happens immediately
- In cluster mode, shard results keep the full set for the coordinator to merge; the coordinator trims after merging
- `GetSerializationRange()` computes the final `[start_index, end_index)` range for response serialization

`ShouldReturnNoResults()` short-circuits when `limit.number == 0` or vector queries with `limit.first_index >= k`.

Default timeout is 50 seconds (`kTimeoutMS`), maximum 60 seconds (`kMaxTimeoutMs`). Default LIMIT is offset 0, count 10.
