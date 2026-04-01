# FT.SEARCH Internals

Use when working on FT.SEARCH command handling, parameter parsing, query validation, response serialization, or the SearchCommand class.

Source: `src/commands/ft_search.cc`, `src/commands/ft_search_parser.cc`, `src/commands/ft_search_parser.h`, `src/commands/commands.h`, `src/query/response_generator.h`

## Contents

- Command Overview (line 23)
- Command Handler (line 35)
- QueryCommand Base Class (line 54)
- SearchCommand Class (line 74)
- Parameter Parsing (line 92)
- Supported Parameters (line 103)
- PARAMS Substitution (line 126)
- Validation (line 137)
- Response Generation (line 152)
- Vector Query Responses (line 166)
- Non-Vector Query Responses (line 182)
- SORTBY Processing (line 205)

## Command Overview

`FT.SEARCH` is the primary query command. Syntax:

```
FT.SEARCH index query [RETURN count field [AS alias] ...]
  [LIMIT offset count] [NOCONTENT] [SORTBY field [ASC|DESC]]
  [PARAMS nargs name value ...] [TIMEOUT ms] [DIALECT version]
  [CONSISTENT|INCONSISTENT] [LOCALONLY|ALLSHARDS|SOMESHARDS]
  [VERBATIM] [SLOP n] [INORDER] [WITHSORTKEYS]
```

## Command Handler

Entry point: `FTSearchCmd()` in `ft_search.cc`:

```cpp
absl::Status FTSearchCmd(ValkeyModuleCtx* ctx, ValkeyModuleString** argv, int argc) {
  return QueryCommand::Execute(ctx, argv, argc,
    unique_ptr<QueryCommand>(new SearchCommand(ValkeyModule_GetSelectedDb(ctx))));
}
```

`QueryCommand::Execute()` (in `commands.h`) is shared by FT.SEARCH and FT.AGGREGATE. It:

1. Parses argv[1] as the index name, looks up the `IndexSchema` via `SchemaManager`
2. Extracts argv[2] as the query string
3. Calls `cmd->ParseCommand(itr)` for command-specific parameter parsing
4. Blocks the client via `ValkeyModule_BlockClient` with timeout/free callbacks
5. Calls `SearchAsync()` to dispatch to the reader thread pool

## QueryCommand Base Class

`QueryCommand` (in `commands.h`) extends `SearchParameters` with command lifecycle methods:

```cpp
struct QueryCommand : public query::SearchParameters {
  static absl::Status Execute(ValkeyModuleCtx*, ValkeyModuleString**, int,
                               unique_ptr<QueryCommand>);
  virtual absl::Status ParseCommand(vmsdk::ArgsIterator&) = 0;
  virtual void SendReply(ValkeyModuleCtx*, query::SearchResult&) = 0;
  virtual bool RequiresCompleteResults() const = 0;

  void QueryCompleteBackground(unique_ptr<SearchParameters>) override;
  void QueryCompleteMainThread(unique_ptr<SearchParameters>) override;
  optional<vmsdk::BlockedClient> blocked_client;
};
```

The completion callbacks unblock the client and invoke `SendReply()`. Background completion schedules the unblock directly; main-thread completion runs after content resolution. The `blocked_client` holds the `ValkeyModule_BlockClient` handle.

## SearchCommand Class

`SearchCommand` (in `ft_search_parser.h`) extends `QueryCommand`:

```cpp
struct SearchCommand : public QueryCommand {
  absl::Status ParseCommand(vmsdk::ArgsIterator&) override;
  void SendReply(ValkeyModuleCtx*, query::SearchResult&) override;
  absl::Status PostParseQueryString() override;
  bool RequiresCompleteResults() const override { return sortby.has_value(); }

  optional<query::SortByParameter> sortby;
  bool with_sort_keys{false};
};
```

`RequiresCompleteResults()` returns true only when SORTBY is present. Without sorting, results can be trimmed early in the background thread via LIMIT-based optimization.

## Parameter Parsing

`SearchCommand::ParseCommand()` uses a `KeyValueParser<SearchCommand>` - a table-driven parser from vmsdk. The parser is created once (static) by `CreateSearchParser()` and handles all keyword parameters.

Parse sequence:
1. `SearchParser.Parse(*this, itr)` - table-driven keyword parsing
2. Check no unparsed arguments remain
3. `PreParseQueryString()` - extract vector KNN clause from query string, parse filter expression via `FilterParser`
4. `PostParseQueryString()` - validate SORTBY field exists in schema
5. `VerifyQueryString()` - validate KNN K, EF_RUNTIME, timeout, dialect, unused params

## Supported Parameters

| Parameter | Field | Parser | Description |
|-----------|-------|--------|-------------|
| `LIMIT` | `limit.first_index`, `limit.number` | Custom | Pagination offset and count (default: 0, 10) |
| `NOCONTENT` | `no_content` | Flag | Return only document IDs, skip content |
| `RETURN` | `return_attributes` | Custom | Select specific fields to return. Count 0 = NOCONTENT. Supports `AS alias` |
| `SORTBY` | `sortby` | Custom | Sort by field with optional ASC/DESC (default ASC) |
| `WITHSORTKEYS` | `with_sort_keys` | Flag | Include sort key values in response (prefixed with `#`) |
| `PARAMS` | `parse_vars.params` | Custom | Named parameter map for `$param` substitution. Count must be even |
| `TIMEOUT` | `timeout_ms` | Value | Query timeout in milliseconds (max 60000) |
| `DIALECT` | `dialect` | Value | Protocol dialect (supported: 2, 3, 4) |
| `VERBATIM` | `verbatim` | Flag | Disable stemming in text search |
| `SLOP` | `slop` | Value | Proximity window for multi-term text queries |
| `INORDER` | `inorder` | Flag | Require terms to appear in order |
| `LOCALONLY` | `local_only` | Flag | Search only the local node |
| `ALLSHARDS` | `enable_partial_results=false` | Negative flag | Require results from all shards |
| `SOMESHARDS` | `enable_partial_results=true` | Flag | Accept partial results if some shards fail |
| `CONSISTENT` | `enable_consistency=true` | Flag | Prefer consistent reads |
| `INCONSISTENT` | `enable_consistency=false` | Negative flag | Allow stale reads |

Config-driven defaults: `enable_partial_results` defaults from `prefer-partial-results`, `enable_consistency` defaults from `prefer-consistent-results`.

## PARAMS Substitution

The PARAMS clause provides named parameters for `$param` references in the query string and KNN clause. Parameters are stored in `parse_vars.params` as `{name -> (ref_count, value)}` pairs.

Substitution happens in `SubstituteParam()` (in `search.cc`): if a string starts with `$`, the rest is looked up in the params map and the ref_count is incremented. During validation, `VerifyQueryString()` checks that all parameters were used at least once - unused parameters produce a `NotFoundError`.

Common use: passing the vector blob as `$BLOB`:
```
FT.SEARCH idx "*=>[KNN 10 @vec $BLOB]" PARAMS 2 BLOB "\x12\xa9..."
```

## Validation

`VerifyQueryString()` (shared between FT.SEARCH and FT.AGGREGATE) enforces:

| Check | Constraint |
|-------|-----------|
| KNN K | 1 to `max-vector-knn` (default 10000, max 100000) |
| EF_RUNTIME | 1 to `max-ef-runtime` config value |
| Timeout | 0 to 60000 ms |
| Dialect | 2, 3, or 4 |
| Unused params | All PARAMS entries must be referenced at least once |
| Vector query | Must have a non-empty query string |

`SearchCommand::PostParseQueryString()` additionally validates that the SORTBY field exists as a known attribute in the index schema.

## Response Generation

`SearchCommand::SendReply()` runs on the main thread after search completes. The flow:

1. Increment `query_successful_requests_cnt`
2. **Early reply check** via `HandleEarlyReplyScenarios()`:
   - `ShouldReturnNoResults()` true -> reply with just the total count
   - `no_content` true -> `SendReplyNoContent()` (IDs only)
3. `ProcessNeighborsForQuery()` - fetch document content, filter invalid neighbors
4. `ApplySorting()` - if SORTBY present, sort neighbors by attribute value
5. Serialize based on query type: `SerializeNeighbors()` (vector) or `SerializeNonVectorNeighbors()` (non-vector)

Errors during processing increment `query_failed_requests_cnt` and reply with an error.

## Vector Query Responses

Response format for vector queries (array):
```
1) total_count (capped at K)
2) key_1
3) [field_name, field_value, ..., score_as, score_value]
4) key_2
5) [...]
...
```

When RETURN is specified, only requested fields are included. The score field (named by the `AS` clause in the KNN expression, e.g., `AS score`) is formatted as `%.12g`.

When RETURN is empty (default), all stored attributes are returned plus the score. When RETURN lists specific fields, only those fields appear, and the score is included only if its alias is in the RETURN list.

## Non-Vector Query Responses

Response format for non-vector queries (array):
```
1) total_count
2) key_1
3) [field_name, field_value, ...]
4) key_2
5) [...]
...
```

When `WITHSORTKEYS` is set, each result gets an extra element - the sort key value prefixed with `#`:
```
1) total_count
2) key_1
3) "#sort_value"
4) [field_name, field_value, ...]
...
```

`GetSortKeyValue()` extracts the sort field value from `attribute_contents`.

## SORTBY Processing

`ApplySorting()` in `ft_search.cc` sorts the neighbors vector after content resolution:

1. Checks if the sort field is a declared numeric attribute in the schema
2. For numeric fields, sorts by parsed double value using `expr::Value` comparison
3. For non-numeric fields, sorts by string value using `expr::Compare`
4. Uses `partial_sort` when only a subset is needed (LIMIT offset + count < total), otherwise `stable_sort`

The sort respects ASC/DESC order from the SORTBY clause. Documents missing the sort field are pushed to the end. The `expr::Compare` function returns `Ordering::kLESS`, `kGREATER`, `kEQUAL`, or `kUNORDERED`.

Note: SORTBY requires `RequiresCompleteResults() = true`, which disables background trimming - the full result set must be available for sorting.
