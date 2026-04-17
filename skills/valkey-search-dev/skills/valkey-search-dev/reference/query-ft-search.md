# FT.SEARCH internals

Use when reasoning about FT.SEARCH command handling, parameter parsing, validation, or response serialization.

Source: `src/commands/ft_search.cc`, `src/commands/ft_search_parser.{h,cc}`, `src/commands/commands.h`, `src/query/response_generator.h`.

## Syntax

```
FT.SEARCH index query
  [RETURN count field [AS alias] ...] [LIMIT offset count] [NOCONTENT]
  [SORTBY field [ASC|DESC]] [WITHSORTKEYS]
  [PARAMS nargs name value ...] [TIMEOUT ms] [DIALECT version]
  [CONSISTENT|INCONSISTENT] [LOCALONLY|ALLSHARDS|SOMESHARDS]
  [VERBATIM] [SLOP n] [INORDER]
```

## Handler

```cpp
absl::Status FTSearchCmd(ctx, argv, argc) {
  return QueryCommand::Execute(ctx, argv, argc,
      std::make_unique<SearchCommand>(ValkeyModule_GetSelectedDb(ctx)));
}
```

`QueryCommand::Execute` (`commands.h`) is shared with FT.AGGREGATE:

1. Parse `argv[1]` as index name, resolve `IndexSchema` via `SchemaManager`.
2. `argv[2]` is the query string.
3. `cmd->ParseCommand(iter)` - command-specific params.
4. `ValkeyModule_BlockClient` with timeout/free callbacks.
5. `SearchAsync` -> reader pool.

## `QueryCommand` base (`commands.h`)

```cpp
struct QueryCommand : public query::SearchParameters {
  static absl::Status Execute(...);
  virtual absl::Status ParseCommand(vmsdk::ArgsIterator&) = 0;
  virtual void SendReply(ValkeyModuleCtx*, query::SearchResult&) = 0;
  virtual bool RequiresCompleteResults() const = 0;
  void QueryCompleteBackground(unique_ptr<SearchParameters>) override;
  void QueryCompleteMainThread(unique_ptr<SearchParameters>) override;
  std::optional<vmsdk::BlockedClient> blocked_client;
};
```

Completions unblock the client and call `SendReply()`. Background completion schedules unblock directly; main-thread completion runs after content resolution.

## `SearchCommand`

```cpp
struct SearchCommand : public QueryCommand {
  absl::Status ParseCommand(vmsdk::ArgsIterator&) override;
  void SendReply(...) override;
  absl::Status PostParseQueryString() override;
  bool RequiresCompleteResults() const override { return sortby.has_value(); }
  std::optional<query::SortByParameter> sortby;
  bool with_sort_keys{false};
};
```

`RequiresCompleteResults() = true` only when SORTBY - disables background trimming.

## Parse flow

`ParseCommand()` uses a static `KeyValueParser<SearchCommand>` (`CreateSearchParser()`). Sequence:

1. `SearchParser.Parse(*this, iter)` - table-driven keyword parsing.
2. Check no unparsed arguments remain.
3. `PreParseQueryString()` - extract KNN clause from query, parse filter via `FilterParser`.
4. `PostParseQueryString()` - validate SORTBY field exists in schema.
5. `VerifyQueryString()` - KNN K / EF_RUNTIME / timeout / dialect / unused params.

## Parameters

| Keyword | Field | Notes |
|---------|-------|-------|
| `LIMIT` | `limit.first_index`, `limit.number` | default 0, 10 |
| `NOCONTENT` | `no_content` | IDs only |
| `RETURN` | `return_attributes` | count 0 = NOCONTENT; `AS alias` supported |
| `SORTBY` | `sortby` | field [ASC\|DESC], ASC default |
| `WITHSORTKEYS` | `with_sort_keys` | include sort key value (`#<value>`) |
| `PARAMS` | `parse_vars.params` | even-count key/value pairs |
| `TIMEOUT` | `timeout_ms` | max 60000 |
| `DIALECT` | `dialect` | 2, 3, or 4 |
| `VERBATIM` | `verbatim` | disable stemming |
| `SLOP` | `slop` | proximity window |
| `INORDER` | `inorder` | require term order |
| `LOCALONLY` | `local_only` | local node only |
| `ALLSHARDS` | `enable_partial_results = false` | |
| `SOMESHARDS` | `enable_partial_results = true` | |
| `CONSISTENT` | `enable_consistency = true` | |
| `INCONSISTENT` | `enable_consistency = false` | |

Defaults come from config: `enable_partial_results` from `prefer-partial-results`, `enable_consistency` from `prefer-consistent-results`.

## PARAMS substitution

Stored as `{name -> (ref_count, value)}`. `SubstituteParam()` (`search.cc`): `$`-prefixed strings look up in the map, bump `ref_count`. `VerifyQueryString()` enforces all params referenced at least once.

Typical:

```
FT.SEARCH idx "*=>[KNN 10 @vec $BLOB]" PARAMS 2 BLOB "\x12\xa9..."
```

## `VerifyQueryString`

| Check | Constraint |
|-------|-----------|
| KNN K | 1 .. `max-vector-knn` (default 10000, max 100000) |
| EF_RUNTIME | 1 .. `max-ef-runtime` |
| Timeout | 0 .. 60000 |
| Dialect | 2, 3, 4 |
| Unused PARAMS | all referenced at least once |
| Vector query | non-empty query string |

`PostParseQueryString()` additionally checks SORTBY field is a known schema attribute.

## `SendReply`

Main thread, post-search:

1. Bump `query_successful_requests_cnt`.
2. `HandleEarlyReplyScenarios()`: `ShouldReturnNoResults()` -> just total count; `no_content` -> `SendReplyNoContent()` (IDs only).
3. `ProcessNeighborsForQuery()` - fetch content, drop invalid neighbors.
4. `ApplySorting()` if SORTBY present.
5. Serialize - `SerializeNeighbors()` (vector) or `SerializeNonVectorNeighbors()` (non-vector).

Errors bump `query_failed_requests_cnt` + error reply.

## Response shape

### Vector

```
1) total (capped at K)
2) key_1
3) [field_name, field_value, ..., score_alias, score_value]
...
```

RETURN filters returned fields. Score (from `AS` in KNN clause) formatted `%.12g`. Empty RETURN = all stored attributes + score. Explicit RETURN = only listed fields; score included only if its alias is in RETURN.

### Non-vector

```
1) total
2) key_1
3) [field_name, field_value, ...]
...
```

WITHSORTKEYS adds a `#<value>` element before each content block. `GetSortKeyValue()` extracts the sort field from `attribute_contents`.

## SORTBY (`ApplySorting`)

1. Check sort field is a declared numeric attribute.
2. Numeric: sort parsed doubles via `expr::Value`.
3. Else string: `expr::Compare`.
4. `partial_sort` when subset needed (offset + count < total), else `stable_sort`.

ASC/DESC respected. Missing-field docs pushed to end. `expr::Compare` returns `Ordering::{kLESS, kGREATER, kEQUAL, kUNORDERED}`.

SORTBY forces `RequiresCompleteResults() = true` - full set required before sort.
