# Query Engine

Use when working on query parsing, filter evaluation, hybrid search, the FT.SEARCH or FT.AGGREGATE command implementation, or the predicate tree.

## Contents

- FT.SEARCH Pipeline (line 13)
- FT.AGGREGATE Pipeline (line 97)
- Filter Evaluation (line 129)
- FT._DEBUG TEXTINFO (`src/indexes/text/textinfocmd.cc`) (line 144)
- Cancellation (`src/utils/cancel.h`) (line 157)

## FT.SEARCH Pipeline

```
Command parse -> Filter parse -> Query planner -> Search execution -> Content resolution -> Reply
```

### 1. Command Parsing (`src/commands/ft_search_parser.h`)

`SearchCommand` inherits `QueryCommand` -> `SearchParameters`. Parses arguments: index name, query string, LIMIT, NOCONTENT, RETURN, PARAMS, DIALECT, TIMEOUT, SORTBY, LOCALONLY, ALLSHARDS, CONSISTENT, SLOP, INORDER, VERBATIM.

Key constants (in `src/query/search.h`): `kTimeoutMS` = 50000ms default, `kMaxTimeoutMs` = 60000ms, `kDialect` = 2.

### 2. Filter Parsing (`src/commands/filter_parser.h`)

`FilterParser` converts the query string into a predicate tree. Recursive descent parser with `ParseExpression()` as entry point.

**Predicate Types** (`src/query/predicate.h`):

| Type | Class | Syntax Example |
|------|-------|----------------|
| Tag | `TagPredicate` | `@field:{tag1 \| tag2}` |
| Numeric | `NumericPredicate` | `@field:[10 20]`, `@field:[(10 +inf]` |
| Text Term | `TermPredicate` | `hello`, `"exact phrase"` |
| Text Prefix | `PrefixPredicate` | `hel*` |
| Text Suffix | `SuffixPredicate` | `*llo` |
| Text Infix | `InfixPredicate` | `*ell*` |
| Text Fuzzy | `FuzzyPredicate` | `%%hello%%` (1-3 `%` = Levenshtein distance) |
| AND | `ComposedPredicate(kAnd, ...)` | Implicit between terms |
| OR | `ComposedPredicate(kOr, ...)` | `term1 \| term2` |
| Negate | `NegatePredicate` | `-@field:{tag}` |

`ComposedPredicate` is N-ary - holds a vector of children. Supports optional `slop` and `inorder` for proximity queries.

**QueryOperations** bitmask tracks what the filter contains: `kContainsOr`, `kContainsTag`, `kContainsNumeric`, `kContainsText`, `kContainsProximity`, `kContainsNegate`, etc. Used for optimization decisions.

**Configuration limits**: `GetQueryStringDepth()`, `GetQueryStringTermsCount()`, `GetFuzzyMaxDistance()`.

### 3. Vector Query Detection

If the query contains `=>` (kVectorFilterDelimiter), it is a hybrid vector+filter query. The left side is the filter, the right side is the KNN vector spec (`[KNN $k @field $BLOB]`). `SearchParameters::IsVectorQuery()` returns true when `attribute_alias` is non-empty.

### 4. Query Planning (`src/query/planner.h`)

`UsePreFiltering()` decides between:

- **Pre-filtering** - evaluate filter first, pass matching keys as filter functor to vector search. Better when filter is selective (few matches).
- **Inline filtering** - run vector search with inline filter check during graph traversal. Better when filter is broad.

Heuristic based on `estimated_num_of_keys` vs vector index size.

### 5. Search Execution (`src/query/search.h`)

`Search()` / `SearchAsync()` - synchronous or background execution.

**Vector search path** (`PerformVectorSearch`):
1. If pre-filtering: evaluate filter predicates, collect matching keys, compute distances via `CalcBestMatchingPrefilteredKeys`
2. If inline filtering: create `hnswlib::BaseFilterFunctor`, pass to `VectorHNSW::Search()` or `VectorFlat::Search()`
3. Create `SearchResult` with neighbors sorted by distance

**Non-vector search path** (`EvaluateFilterAsPrimary`):
1. Walk predicate tree, fetch matching entries from each index
2. Use `EntriesFetcher` iterators for streaming results
3. Support for negation via `UniversalSetFetcher`

**SearchMode**: `kLocal` (single node) or `kRemote` (from coordinator fan-out).

### 6. Content Resolution (`src/query/content_resolution.h`)

After search completes (possibly on background thread), `ResolveContent()` runs on main thread:
1. Contention check - compare mutation sequence numbers to detect in-flight changes
2. If contention found, query is parked in mutation queue and retried after mutation completes
3. Fetch attribute content from Valkey keys for RETURN fields
4. Send reply to client

**ContentProcessing** enum:
- `kNoContent` - NOCONTENT flag, skip fetch
- `kContentAvailable` - content from index (reserved)
- `kContentRequired` - must fetch from main thread
- `kContentionCheckRequired` - fetch + check for mutation contention

### 7. Distributed Search (`src/query/fanout.h`)

`PerformSearchFanoutAsync()` fans out to all shards via gRPC `SearchIndexPartition`. Results merged by coordinator. Consistency via `IndexFingerprintVersion` - if index schema differs across nodes, request fails with `kFailedPreconditionMsg`.

## FT.AGGREGATE Pipeline

```
Parse -> Search (reuses FT.SEARCH) -> Stage pipeline -> Reply
```

### Parsing (`src/commands/ft_aggregate_parser.h`)

`AggregateParameters` holds a vector of `Stage` objects. Stages execute sequentially on the `RecordSet`.

### Stage Types

| Stage | Class | Description |
|-------|-------|-------------|
| LIMIT | `Limit` | Offset + count trimming |
| APPLY | `Apply` | Compute expression, add as new field |
| FILTER | `Filter` | Keep records matching expression |
| GROUPBY | `GroupBy` | Group by fields with reducers |
| SORTBY | `SortBy` | Sort by fields with optional MAX |

### Reducers (in `GroupBy`)

Built-in reducers registered in `GroupBy::reducerTable` (`src/commands/ft_aggregate_exec.cc`). Each reducer implements `ReducerInstance::ProcessRecord()` and `GetResult()`.

Available reducers: `COUNT`, `MIN`, `MAX`, `SUM`, `AVG`, `STDDEV`, `COUNT_DISTINCT`.

### Expression Engine (`src/expr/expr.h`)

Generic expression compiler/evaluator. `Expression::Compile()` parses string into AST. `Expression::Evaluate()` runs against a `Record`. Supports attribute references (`@field`), arithmetic, string ops, and parameters (`$param`).

`Value` (`src/expr/value.h`) is the runtime type - supports string, number, and nil.

## Filter Evaluation

### Evaluator Interface (`src/query/predicate.h`)

`query::Evaluator` defines the interface: `EvaluateTags()`, `EvaluateNumeric()`, `EvaluateText()`.

### PrefilterEvaluator (`src/indexes/vector_base.h`)

The sole concrete implementation. Used in the pre-filtering path to evaluate predicates against per-key data in the index structures:
- Tags: looks up key in `Tag` index
- Numeric: looks up key in `Numeric` index
- Text: looks up key in per-key `TextIndex`

Post-filtering uses inline predicate evaluation during content resolution rather than a separate evaluator class.

## FT._DEBUG TEXTINFO (`src/indexes/text/textinfocmd.cc`)

Debug subcommand for inspecting text index internals:

```
FT._DEBUG TEXTINFO <index_name> PREFIX <word> [WITHKEYS [WITHPOSITIONS]]
FT._DEBUG TEXTINFO <index_name> SUFFIX <word> [WITHKEYS [WITHPOSITIONS]]
FT._DEBUG TEXTINFO <index_name> STEM <word>
FT._DEBUG TEXTINFO <index_name> LEXER <string> [<stemsize>]
```

Dumps prefix/suffix tree entries, stem mappings, and lexer tokenization results. Only available when debug mode is enabled.

## Cancellation (`src/utils/cancel.h`)

All search operations carry a `cancel::Token`. Checked periodically during HNSW graph traversal and filter evaluation. Triggered on timeout (`TIMEOUT` parameter) or client disconnect.
