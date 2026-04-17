# FT.AGGREGATE pipeline

Use when reasoning about FT.AGGREGATE stages, reducers, the expression engine, or the Record / RecordSet data model.

Source: `src/commands/ft_aggregate{,_parser,_exec}.{h,cc}`, `src/expr/expr.h`, `src/expr/value.h`.

## Syntax

```
FT.AGGREGATE index query
  [LOAD count|* field ...]
  [GROUPBY nargs @field ... REDUCE func nargs arg ... [AS name] ...]
  [APPLY expr AS name]
  [SORTBY nargs [@field ASC|DESC ...] [MAX n]]
  [LIMIT offset count]
  [FILTER expr]
  [PARAMS nargs name value ...] [TIMEOUT ms] [DIALECT version]
  [VERBATIM] [SLOP n] [INORDER] [ADDSCORES]
```

## Handler

```cpp
absl::Status FTAggregateCmd(ctx, argv, argc) {
  return QueryCommand::Execute(ctx, argv, argc,
      std::make_unique<aggregate::AggregateParameters>(ValkeyModule_GetSelectedDb(ctx)));
}
```

Same `QueryCommand::Execute` path as FT.SEARCH.

## `AggregateParameters`

Extends both `QueryCommand` and `expr::Expression::CompileContext`:

```cpp
struct AggregateParameters : public expr::Expression::CompileContext, public QueryCommand {
  bool loadall_{false};
  std::vector<std::string> loads_;
  bool load_key{false};
  bool addscores_{false};
  std::vector<std::unique_ptr<Stage>> stages_;
  absl::flat_hash_map<std::string, size_t> record_indexes_by_identifier_;
  absl::flat_hash_map<std::string, size_t> record_indexes_by_alias_;
  std::vector<AttributeRecordInfo>         record_info_by_index_;
};
```

Dual role: `AggregateParameters` is the `CompileContext` for the expression compiler - provides `MakeReference()` (`@field` -> record index) and `GetParam()` (`$param`). Expression compilation in APPLY / FILTER / SORTBY / REDUCE is against the evolving record schema.

`AddRecordAttribute()` assigns an index per unique `(identifier, alias)`. Pseudo-fields `__key` (index 0) and score (index 1) always registered first.

## Stages

```cpp
class Stage {
  virtual absl::Status Execute(RecordSet& records) const = 0;
  virtual std::optional<query::SerializationRange> GetSerializationRange() const = 0;
};
```

`GetSerializationRange()` determines how many search results are fetched. First LIMIT stage's range drives it. GROUPBY / APPLY / FILTER / SORTBY return `SerializationRange::All()` - full set required.

Execution in `SendReplyInner()`:

1. `CreateRecordsFromNeighbors()` -> `RecordSet`.
2. `ExecuteAggregationStages()` runs each sequentially.
3. `GenerateResponse()` serializes.

Cancellation token checked between stages.

## GROUPBY + REDUCE

Parse (`ConstructGroupByParser`): field count + `@field` refs (must start with `@`), then zero or more `REDUCE func nargs arg... [AS name]`. Each REDUCE references a function from `GroupBy::reducerTable`. Args compiled via `Expression::Compile()`.

Execution (`GroupBy::Execute`):

1. `flat_hash_map<GroupKey, vector<ReducerInstance>>`.
2. Per input: compute `GroupKey` from group field values.
3. New key -> instantiate `ReducerInstance`s.
4. Per reducer: `ProcessRecord(args)` with evaluated arg values.
5. After input: one output record per group - fields from group-key values + each reducer's `GetResult()`.

`GroupKey` = `InlinedVector<expr::Value, 4>` with hash/equality (hash-map key).

### Reducers

```cpp
struct ReducerInstance {
  virtual void ProcessRecord(InlinedVector<expr::Value, 4>& values) = 0;
  virtual expr::Value GetResult() const = 0;
};
```

| Reducer | Args | Notes |
|---------|------|-------|
| `COUNT` | 0 | counts records |
| `SUM` | 1 | numeric |
| `MIN` / `MAX` | 1 | |
| `AVG` | 1 | numeric |
| `STDDEV` | 1 | sample (N-1) |
| `COUNT_DISTINCT` | 1 | `flat_hash_set<Value>` |

Nil skipped by all except COUNT. Numeric reducers call `AsDouble()` and skip non-numeric.

## APPLY

`APPLY "expr" AS name`. Expr compiled via `Expression::Compile()`; output via `MakeReference(name, /*create=*/true)`.

```cpp
for (auto& r : records) SetField(*r, *name_, expr_->Evaluate(ctx, *r));
```

Processes all records. Can reference anything defined earlier - LOAD, earlier APPLY, GROUPBY outputs.

## SORTBY

`SORTBY nargs @f1 ASC @f2 DESC [MAX n]`. Each field compiled as expression, ASC default. MAX default 10.

Two strategies:

- `records > MAX`: `std::priority_queue<Record*>` - O(N log MAX) top-N.
- `records <= MAX`: `std::stable_sort`.

`SortFunctor` evaluates each sort key on both records via `expr::Compare()`. `kEQUAL` / `kUNORDERED` continue to next key; `kLESS` / `kGREATER` return per direction.

## LIMIT

`LIMIT offset count`. Pop `offset` from front, pop from back until `size <= count`.

**Only stage that can reduce fetch count** - `GetSerializationRange()` returns `{offset, offset + limit}`, read during command parsing to constrain the search range.

## FILTER

`FILTER "expr"`. Evaluate per record, keep where `IsTrue()`:

```cpp
if (expr_->Evaluate(ctx, *r).IsTrue()) filtered.push_back(std::move(r));
```

Requires all input records (`SerializationRange::All()`).

## LOAD (not a stage)

Parsed before stages, controls which document fields are fetched during search.

- `LOAD *` -> all attributes (`loadall_ = true`).
- `LOAD count @f1 @f2 ...` -> lookup per field in schema, push to `return_attributes`.
- `__key` field -> `load_key = true`.
- Score field references skipped (always available).
- No content fields requested -> `no_content = true`.

Each LOAD field also calls `AddRecordAttribute()` so expressions can reference it.

## Expression engine

`src/expr/expr.h`, `src/expr/value.h`.

- `Expression::Compile(CompileContext&, string_view)` - parse to AST.
- `Evaluate(EvalContext&, Record&)` - run on a record.
- `CompileContext` -> `MakeReference(name, create)` resolves `@field`; `GetParam(name)` resolves `$param`. `AggregateParameters` implements it.

`expr::Value`: variant of nil / double / string. `IsTrue()`, `IsNil()`, `AsDouble()`, `AsStringView()`, `Compare()` -> `Ordering::{kLESS, kGREATER, kEQUAL, kUNORDERED}`. Hash/equality for containers.

`@field` references compile to `Attribute` (in `ft_aggregate_parser.h`) with a `record_index_` into `Record::fields_`. `MakeReference(name, /*create=*/true)` creates a new slot (APPLY outputs); `false` requires it to exist (GROUPBY inputs).

## Record / RecordSet

```cpp
class Record : public expr::Expression::Record {
  std::vector<expr::Value> fields_;                       // by record schema index
  std::vector<std::pair<std::string, expr::Value>> extra_fields_;  // unregistered
};
```

`fields_[i]` aligns with `AggregateParameters::record_info_by_index_[i]`. `extra_fields_` holds document attributes outside the schema.

`RecordSet` extends `deque<unique_ptr<Record>>` with custom `pop_front()` / `pop_back()` returning ownership.

`CreateRecordsFromNeighbors()`:

1. Set `__key` if `load_key`.
2. Set score for vector queries.
3. Each attribute content: look up by alias, then identifier.
4. Numeric -> `Value(double)`; text/tag -> `Value(string)`.
5. JSON values unquoted; records with unquotable JSON are dropped.

## Response

`GenerateResponse()` -> RESP array:

```
1) record_count
2) [name, value, name, value, ...]
3) [...]
```

Per record: iterate both `fields_` and `extra_fields_`, `ReplyWithValue()` on non-nil. Dialect-specific:

- Dialect 2: plain strings.
- Dialect 3/4: wrapped (`[value]`).

Numeric formatting `%.11g`. Nil skipped (no name/value emitted).
