# FT.AGGREGATE Pipeline

Use when working on the FT.AGGREGATE command, aggregation stages, the expression engine, reducers, or the Record/RecordSet data model.

Source: `src/commands/ft_aggregate.cc`, `src/commands/ft_aggregate_parser.cc`, `src/commands/ft_aggregate_parser.h`, `src/commands/ft_aggregate_exec.cc`, `src/commands/ft_aggregate_exec.h`, `src/expr/expr.h`, `src/expr/value.h`

## Contents

- Command Overview (line 25)
- Command Handler (line 41)
- AggregateParameters Class (line 55)
- Pipeline Stages (line 78)
- GROUPBY + REDUCE Stage (line 98)
- Reducers (line 118)
- APPLY Stage (line 143)
- SORTBY Stage (line 163)
- LIMIT Stage (line 180)
- FILTER Stage (line 194)
- LOAD Clause (line 213)
- Expression Engine (line 231)
- Record and RecordSet Types (line 241)
- Response Generation (line 263)
- See Also (line 280)

## Command Overview

`FT.AGGREGATE` runs a pipeline of transformation stages on search results. Syntax:

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

## Command Handler

Entry point: `FTAggregateCmd()` in `ft_aggregate.cc`:

```cpp
absl::Status FTAggregateCmd(ValkeyModuleCtx* ctx, ValkeyModuleString** argv, int argc) {
  return QueryCommand::Execute(ctx, argv, argc,
    unique_ptr<QueryCommand>(
        new aggregate::AggregateParameters(ValkeyModule_GetSelectedDb(ctx))));
}
```

Like FT.SEARCH, it goes through `QueryCommand::Execute()` for index lookup, query string extraction, parameter parsing, client blocking, and async dispatch.

## AggregateParameters Class

`AggregateParameters` (in `ft_aggregate_parser.h`) extends both `QueryCommand` and `expr::Expression::CompileContext`:

```cpp
struct AggregateParameters : public expr::Expression::CompileContext,
                             public QueryCommand {
  bool loadall_{false};
  vector<string> loads_;
  bool load_key{false};
  bool addscores_{false};
  vector<unique_ptr<Stage>> stages_;
  // Record schema tracking:
  flat_hash_map<string, size_t> record_indexes_by_identifier_;
  flat_hash_map<string, size_t> record_indexes_by_alias_;
  vector<AttributeRecordInfo> record_info_by_index_;
};
```

Key design: `AggregateParameters` acts as the `CompileContext` for the expression compiler, providing `MakeReference()` to resolve field names to record indexes and `GetParam()` for `$param` substitution. This means field references in APPLY, FILTER, SORTBY, and REDUCE expressions are compiled against the evolving record schema.

`AddRecordAttribute()` assigns a new index to each unique (identifier, alias) pair. The `__key` pseudo-field (index 0) and score field (index 1) are always registered first.

## Pipeline Stages

Stages are parsed in command order and stored in `stages_`. Each stage implements the `Stage` interface:

```cpp
class Stage {
  virtual absl::Status Execute(RecordSet& records) const = 0;
  virtual optional<query::SerializationRange> GetSerializationRange() const = 0;
};
```

`GetSerializationRange()` returns the range of input records needed. The first LIMIT stage's range determines how many search results are fetched. Stages returning `SerializationRange::All()` (GROUPBY, APPLY, FILTER, SORTBY) require the full search result set.

Execution order in `SendReplyInner()`:
1. Process search results into `RecordSet` via `CreateRecordsFromNeighbors()`
2. Execute each stage sequentially via `ExecuteAggregationStages()`
3. Generate response via `GenerateResponse()`

Cancellation is checked between stages via the cancellation token.

## GROUPBY + REDUCE Stage

The GROUPBY stage (class `GroupBy`) groups records by one or more fields and applies reducer functions to each group.

Parsing (`ConstructGroupByParser()`):
1. Parse field count, then `@field` references (must start with `@`)
2. Parse zero or more `REDUCE func nargs arg... [AS name]` clauses
3. Each REDUCE references a function from the static `reducerTable`
4. Arguments are compiled as expressions via `Expression::Compile()`

Execution (`GroupBy::Execute()`):
1. Build a `flat_hash_map<GroupKey, vector<ReducerInstance>>` mapping group keys to reducer state
2. For each input record, compute the `GroupKey` from group field values
3. For new keys, instantiate fresh `ReducerInstance` objects
4. Call `ProcessRecord(args)` on each reducer with evaluated argument values
5. After all input records are consumed, create one output record per group
6. Output record fields are set from the group key values and `GetResult()` from each reducer

`GroupKey` is an `InlinedVector<expr::Value, 4>` with hash and equality support, enabling use as a `flat_hash_map` key.

## Reducers

Available reducers (registered in `GroupBy::reducerTable`):

| Reducer | Args | Description |
|---------|------|-------------|
| `COUNT` | 0 | Count records in each group |
| `SUM` | 1 | Sum of numeric values |
| `MIN` | 1 | Minimum value |
| `MAX` | 1 | Maximum value |
| `AVG` | 1 | Average of numeric values |
| `STDDEV` | 1 | Sample standard deviation (using N-1 formula) |
| `COUNT_DISTINCT` | 1 | Count of unique values (using `flat_hash_set<Value>`) |

Each reducer is a subclass of `ReducerInstance`:

```cpp
struct ReducerInstance {
  virtual void ProcessRecord(InlinedVector<expr::Value, 4>& values) = 0;
  virtual expr::Value GetResult() const = 0;
};
```

Nil values are skipped by all reducers except COUNT. Numeric reducers (`SUM`, `AVG`, `STDDEV`) call `AsDouble()` and skip non-numeric values. `COUNT_DISTINCT` uses `Value` hash/equality for deduplication.

## APPLY Stage

The APPLY stage (class `Apply`) computes a new field from an expression:

```
APPLY "expr" AS name
```

Parsing: the expression string is compiled via `Expression::Compile()`, and the output field is resolved via `MakeReference(name, true)` (creating a new record slot if needed).

Execution: for each record, evaluate the expression and set the output field:

```cpp
for (auto& r : records) {
  SetField(*r, *name_, expr_->Evaluate(ctx, *r));
}
```

APPLY processes all records (returns `SerializationRange::All()`). It can reference any previously defined field - from LOAD, from earlier APPLY stages, or from GROUPBY outputs.

## SORTBY Stage

The SORTBY stage (class `SortBy`) sorts records by one or more expressions with direction:

```
SORTBY nargs @field1 ASC @field2 DESC [MAX n]
```

Parsing: each field is compiled as an expression. Direction defaults to ASC. The optional MAX clause limits the output (default 10).

Execution uses two strategies based on record count vs MAX:

- **When records > MAX** - uses a `std::priority_queue<Record*>` (heap-based top-N) to avoid full sort. This is O(N * log(MAX)) instead of O(N * log(N))
- **When records <= MAX** - uses `std::stable_sort` on the full set

The sort comparator (`SortFunctor`) evaluates each sort key expression on both records and uses `expr::Compare()` for ordering. `Ordering::kEQUAL` and `kUNORDERED` continue to the next sort key; `kLESS`/`kGREATER` return based on the direction.

## LIMIT Stage

The LIMIT stage (class `Limit`) applies offset and count:

```
LIMIT offset count
```

Execution:
1. Pop `offset` records from the front
2. Pop excess records from the back until `size <= count`

LIMIT is the only stage that can reduce the search result fetch count - its `GetSerializationRange()` returns `{offset, offset + limit}`, which is used during command parsing to set the search parameters so the search engine only fetches the needed range.

## FILTER Stage

The FILTER stage (class `Filter`) removes records that don't match an expression:

```
FILTER "expr"
```

Execution: evaluate the expression for each record. Keep only records where the result `IsTrue()`:

```cpp
auto result = expr_->Evaluate(ctx, *r);
if (result.IsTrue()) {
  filtered.push_back(std::move(r));
}
```

FILTER requires all input records (`SerializationRange::All()`).

## LOAD Clause

LOAD is not a pipeline stage - it's parsed before stages and controls which document fields are fetched during the search phase.

```
LOAD count @field1 @field2 ...  # Load specific fields
LOAD *                          # Load all fields
```

Processing in `ManipulateReturnsClause()`:
1. If `LOAD *` (`loadall_`), return all document attributes
2. Otherwise, for each load field, look up its index schema and add to `return_attributes`
3. The special `__key` field sets `load_key = true` (makes the document key available in records)
4. Score field references are skipped (always available)
5. If no content fields are requested, set `no_content = true`

Each LOAD field also calls `AddRecordAttribute()` to register it in the record schema so expressions can reference it.

## Expression Engine

The expression engine (`src/expr/expr.h`, `src/expr/value.h`) provides compilation and evaluation of expressions used in APPLY, FILTER, SORTBY, and REDUCE arguments.

`Expression::Compile(CompileContext&, string_view)` parses an expression string into an AST. `Evaluate(EvalContext&, Record&)` runs it against a record. `CompileContext` provides `MakeReference()` (resolve `@field` to a record index) and `GetParam()` (resolve `$param`). `AggregateParameters` implements `CompileContext`.

`expr::Value` is a variant: nil, double, or string. Supports `IsTrue()`/`IsNil()`, `AsDouble()`, `AsStringView()`, comparison via `Compare()` (returns `kLESS`/`kGREATER`/`kEQUAL`/`kUNORDERED`), and hash/equality for use in containers.

During compilation, `@field` references become `Attribute` objects (in `ft_aggregate_parser.h`) storing a `record_index_` into `Record::fields_`. `GetValue()` indexes into the record's fields vector. The `create` flag in `MakeReference()` controls whether unknown fields create new record slots (outputs like APPLY AS) or must already exist (inputs like GROUPBY fields).

## Record and RecordSet Types

`Record` (in `ft_aggregate_exec.h`) extends `Expression::Record`:

```cpp
class Record : public expr::Expression::Record {
  vector<expr::Value> fields_;               // Indexed by record schema
  vector<pair<string, expr::Value>> extra_fields_;  // Unregistered fields
};
```

Fields are positionally indexed - `fields_[i]` corresponds to the `AttributeRecordInfo` at index `i` in `AggregateParameters::record_info_by_index_`. Extra fields come from document attributes not in the record schema.

`RecordSet` extends `deque<unique_ptr<Record>>` with custom `pop_front()`/`pop_back()` that return ownership. Stages consume and produce `RecordSet` in place.

`CreateRecordsFromNeighbors()` converts search `Neighbor` results into records:
1. Set `__key` field if `load_key` is true
2. Set score field for vector queries
3. For each attribute content, look up by alias then identifier in the record index maps
4. Numeric fields are converted to `Value(double)`, text/tag fields to `Value(string)`
5. JSON values are unquoted. Records with unquotable JSON values are dropped

## Response Generation

`GenerateResponse()` serializes the final `RecordSet`:

```
1) record_count
2) [field_name, field_value, field_name, field_value, ...]
3) [...]
...
```

For each record, iterate both `fields_` and `extra_fields_`, calling `ReplyWithValue()` for each non-nil value. The function handles HASH vs JSON data types and dialect-specific formatting:
- Dialect 2: values are returned as plain strings
- Dialect 3/4: values are wrapped in brackets (`[value]`)

Numeric values are formatted with `%.11g` precision. Nil values are skipped entirely (no field name or value emitted).

## See Also

- [parsing.md](parsing.md) - filter expression parser shared with FT.SEARCH
- [execution.md](execution.md) - search execution flow (shared query phase)
- [ft-search.md](ft-search.md) - FT.SEARCH command handling
- [../architecture/module-overview.md](../architecture/module-overview.md) - module design and registered commands
- [../architecture/index-schema.md](../architecture/index-schema.md) - IndexSchema attributes and field types
- [../cluster/coordinator.md](../cluster/coordinator.md) - cluster-mode search fanout via gRPC
- [../cluster/metrics.md](../cluster/metrics.md) - query counters and latency samplers
