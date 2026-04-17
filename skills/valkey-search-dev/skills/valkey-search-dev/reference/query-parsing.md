# Filter expression parser

Use when reasoning about query parsing, the predicate AST, or adding new predicate types.

Source: `src/commands/filter_parser.{h,cc}`, `src/query/predicate.h`.

## `FilterParser`

Recursive-descent parser in namespace `valkey_search`. Takes an `IndexSchema` reference for field-name/type validation at parse time.

```cpp
FilterParser parser(index_schema, expression, text_options);
absl::StatusOr<FilterParseResults> result = parser.Parse();
```

Called from `SearchParameters::PreParseQueryString()`. For vector queries, the part **before** `=>` is the filter; the KNN clause follows. `*` matches all documents.

Result fields:

- `root_predicate` - `unique_ptr<query::Predicate>`.
- `filter_identifiers` - schema identifiers referenced.
- `query_operations` - bitmask (see below).

## Recursive descent

Tracks position `pos_`. Key private methods:

| Method | Purpose |
|--------|---------|
| `ParseExpression(level)` | top-level, handles AND/OR/negate at a nesting level |
| `ParseFieldName()` | `@field:` syntax, returns alias |
| `ParseNumericPredicate(alias)` | `[start end]` (or `(` exclusive) ranges |
| `ParseTagPredicate(alias)` | `{tag1\|tag2}` sets |
| `ParseTextPredicate(field)` | full-text against a text field |
| `ParseTextTokens(field)` | term, prefix, suffix, fuzzy sequences |
| `ParseQuotedTextToken(...)` | `"exact phrase"` |
| `ParseUnquotedTextToken(...)` | bare words, prefix `word*`, suffix `*word`, infix `*word*`, fuzzy `%%word%%` |
| `WrapPredicate(...)` | combines predicates with logical ops, builds N-ary trees |

Operators: implicit AND (space), explicit `|` for OR, `-` prefix for negation. `()` groups. `node_count_` checked against the configured max at each node creation.

## Predicate hierarchy (`query::Predicate`)

```
Predicate (abstract)
  +-- NumericPredicate       kNumeric
  +-- TagPredicate           kTag
  +-- TextPredicate          kText (abstract)
  |     +-- TermPredicate / PrefixPredicate / SuffixPredicate / InfixPredicate / FuzzyPredicate
  +-- ComposedPredicate      kComposedAnd / kComposedOr
  +-- NegatePredicate        kNegate
```

`PredicateType` enum: `kTag`, `kNumeric`, `kComposedAnd`, `kComposedOr`, `kNegate`, `kText`, `kNone`.

Every predicate implements `Evaluate(Evaluator&)`. The `Evaluator` dispatches to `EvaluateText` / `EvaluateTags` / `EvaluateNumeric`.

## `NumericPredicate`

Range `[start, end]` + inclusive/exclusive flags. Holds pointer to `indexes::Numeric` + field identifier. `+inf` / `-inf` -> `double::max()` / `double::lowest()` (under clang `-ffast-math`). `Evaluate(const double*)` overload for direct value comparison.

## `TagPredicate`

Raw tag string + parsed `flat_hash_set<string>`. Query separator is **always `|`** regardless of index separator. `Evaluate(const flat_hash_set<string_view>*, bool case_sensitive)` overload for direct set matching.

## `TextPredicate` variants

Shared fields: `text_index_schema_`, `field_mask_` (uint64_t, up to 64 fields), `BuildTextIterator(...)`, `EstimateSize(is_vec_query)`.

| Subclass | Syntax | Notes |
|----------|--------|-------|
| `TermPredicate` | `word` or `"word"` | exact or stemmed; `exact_` flag controls stemming |
| `PrefixPredicate` | `word*` | |
| `SuffixPredicate` | `*word` | |
| `InfixPredicate` | `*word*` | |
| `FuzzyPredicate` | `%%word%%` | `distance_` = edit distance (1-3 `%` pairs = distance 1-3) |

`SetupTextFieldConfiguration()` sets the field mask. `@field:`-scoped = only that bit. Unscoped = all indexed text fields.

## `ComposedPredicate`

N-ary (not binary):

```cpp
ComposedPredicate(LogicalOperator op, vector<unique_ptr<Predicate>> children,
                  optional<uint32_t> slop = nullopt, bool inorder = false);
```

`WrapPredicate()` flattens nested compositions of the same type - three ANDed terms become one `ComposedPredicate(kComposedAnd, [A, B, C])`, not nested binary.

`FlagNestedComposedPredicate()` sets `kContainsNestedComposed` on nested composed predicates (planner uses for optimization).

`slop_` / `inorder_` fields carry SLOP / INORDER settings for proximity evaluation.

## `NegatePredicate`

Single child, inverted result. Created by `-` prefix. Presence forces prefilter evaluation and possibly a universal-set fetcher.

## `QueryOperations` bitmask

`uint64_t` with bitwise ops. Set during parse, drives planner and execution.

| Flag | Bit | Set when |
|------|-----|----------|
| `kNone` | 0 | empty |
| `kContainsOr` | 1<<0 | `\|` present |
| `kContainsAnd` | 1<<1 | AND present |
| `kContainsNumeric` | 1<<2 | numeric field referenced |
| `kContainsTag` | 1<<3 | tag field referenced |
| `kContainsNegate` | 1<<4 | `-` present |
| `kContainsText` | 1<<5 | text field referenced |
| `kContainsProximity` | 1<<6 | SLOP/INORDER |
| `kContainsNestedComposed` | 1<<7 | composed inside composed |
| `kContainsTextTerm` | 1<<8 | exact/stemmed term |
| `kContainsTextPrefix` | 1<<9 | prefix search |
| `kContainsTextSuffix` | 1<<10 | suffix search |
| `kContainsTextFuzzy` | 1<<11 | fuzzy search |

Downstream (`search.cc`): `IsUnsolvedQuery()` (prefilter needed), `NeedsDeduplication()` (OR/tag/non-text-negation), `IncrementQueryOperationMetrics()`.

## `Evaluator` interface (`predicate.h`)

```cpp
class Evaluator {
  virtual EvaluationResult EvaluateText   (const TextPredicate&, bool require_positions) = 0;
  virtual EvaluationResult EvaluateTags   (const TagPredicate&) = 0;
  virtual EvaluationResult EvaluateNumeric(const NumericPredicate&) = 0;
  virtual const InternedStringPtr& GetTargetKey() const = 0;
  virtual bool IsPrefilterEvaluator() const { return false; }
};
```

`EvaluationResult`: `bool matches` + optional `TextIterator` for position-aware matching (used by proximity/SLOP in `ComposedPredicate::EvaluateWithContext`).

Main impl: `indexes::PrefilterEvaluator` in `src/indexes/vector_base.h` (inline and prefilter paths). Tag/numeric values via per-key indexes; text via per-key `TextIndex`.

## Safety limits

| Config | Default | Max | Purpose |
|--------|---------|-----|---------|
| `query-string-depth` | 1000 | UINT_MAX | paren nesting depth |
| `query-string-terms-count` | 1000 | 10 000 | predicate nodes total |
| `fuzzy-max-distance` | 3 | 50 | max Levenshtein edit distance |
| `max-vector-knn` | 10 000 | 100 000 | K parameter for vector queries |

`ParseExpression(level)` checks `level` against `query-string-depth`. `node_count_` checked against `query-string-terms-count` at each creation. Violations -> `InvalidArgumentError`.

## `TextParsingOptions`

```cpp
struct TextParsingOptions {
  bool verbatim = false;    // skip stemming
  bool inorder = false;     // INORDER flag
  std::optional<uint32_t> slop;  // SLOP flag
};
```

Set from command-level VERBATIM / INORDER / SLOP. Top-level AND node carries these for proximity evaluation.
