# Filter Expression Parser

Use when working on query string parsing, the predicate AST, filter expression syntax, or adding new predicate types.

Source: `src/commands/filter_parser.h`, `src/commands/filter_parser.cc`, `src/query/predicate.h`

## Contents

- FilterParser Overview (line 22)
- Parsing Entry Point (line 32)
- Recursive Descent Structure (line 41)
- Predicate Type Hierarchy (line 59)
- TextPredicate Variants (line 89)
- ComposedPredicate (N-ary Tree) (line 108)
- NegatePredicate (line 131)
- QueryOperations Bitmask (line 141)
- Evaluator Interface (line 167)
- Safety Limits (line 185)
- TextParsingOptions (line 199)

## FilterParser Overview

`FilterParser` is a recursive descent parser that converts FT.SEARCH/FT.AGGREGATE query strings into a predicate AST. It lives in namespace `valkey_search` and takes an `IndexSchema` reference to validate field names and types at parse time.

The parser produces a `FilterParseResults` struct containing:

- `root_predicate` - the root of the predicate tree (`unique_ptr<query::Predicate>`)
- `filter_identifiers` - set of schema identifier strings referenced by the filter
- `query_operations` - bitmask describing which operation types appear in the query

## Parsing Entry Point

```cpp
FilterParser parser(index_schema, expression, text_options);
absl::StatusOr<FilterParseResults> result = parser.Parse();
```

`Parse()` is called from `SearchParameters::PreParseQueryString()` during command parsing. For vector queries, the query string before the `=>` delimiter is the filter expression; the KNN clause follows after it. For non-vector queries, the entire query string is the filter expression. A `*` expression matches all documents.

## Recursive Descent Structure

The parser maintains position state (`pos_`) and walks the expression character by character. Key private methods:

| Method | Purpose |
|--------|---------|
| `ParseExpression(level)` | Top-level recursive entry, handles AND/OR/negate at a nesting level |
| `ParseFieldName()` | Expects `@field:` syntax, returns the field alias |
| `ParseNumericPredicate(alias)` | Parses `[start end]` range with inclusive `[` or exclusive `(` bounds |
| `ParseTagPredicate(alias)` | Parses `{tag1\|tag2}` tag sets |
| `ParseTextPredicate(field)` | Parses full-text search terms against a text field |
| `ParseTextTokens(field)` | Parses sequences of text tokens (terms, prefix, suffix, fuzzy) |
| `ParseQuotedTextToken(...)` | Handles `"exact phrase"` tokens |
| `ParseUnquotedTextToken(...)` | Handles bare word tokens, prefix (`word*`), suffix (`*word`), infix (`*word*`), fuzzy (`%%word%%`) |
| `WrapPredicate(...)` | Combines predicates with logical operators, building N-ary trees |

Boolean operators: implicit AND (space between predicates), explicit `|` for OR, `-` prefix for negation. Parentheses `()` control grouping. The parser tracks `node_count_` against the configured maximum at each node creation.

## Predicate Type Hierarchy

All predicates inherit from `query::Predicate` (namespace `valkey_search::query`):

```
Predicate (abstract)
  +-- NumericPredicate      kNumeric
  +-- TagPredicate          kTag
  +-- TextPredicate         kText (abstract)
  |     +-- TermPredicate
  |     +-- PrefixPredicate
  |     +-- SuffixPredicate
  |     +-- InfixPredicate
  |     +-- FuzzyPredicate
  +-- ComposedPredicate     kComposedAnd / kComposedOr
  +-- NegatePredicate       kNegate
```

The `PredicateType` enum distinguishes: `kTag`, `kNumeric`, `kComposedAnd`, `kComposedOr`, `kNegate`, `kText`, `kNone`.

Every predicate implements `Evaluate(Evaluator&)` for filter evaluation. The `Evaluator` abstract class dispatches to type-specific evaluation methods (`EvaluateText`, `EvaluateTags`, `EvaluateNumeric`).

### NumericPredicate

Stores a range `[start, end]` with inclusive/exclusive flags. Holds a pointer to the `indexes::Numeric` index and the field identifier. Supports `+inf`/`-inf` bounds (mapped to `double::max()`/`double::lowest()` under clang with `-ffast-math`). The `Evaluate(const double* value)` overload allows direct value comparison without going through the Evaluator.

### TagPredicate

Stores the raw tag string plus a parsed `flat_hash_set<string>` of individual tag values. Tag query syntax uses `|` as separator regardless of the index's configured separator. Holds a pointer to the `indexes::Tag` index. The `Evaluate(const flat_hash_set<string_view>*, bool case_sensitive)` overload supports direct tag-set matching.

## TextPredicate Variants

`TextPredicate` is abstract with five concrete subclasses. All share:

- `text_index_schema_` - shared pointer to the schema's text index configuration
- `field_mask_` - a `uint64_t` bitmask selecting which text fields to search (up to 64 fields)
- `BuildTextIterator(...)` - creates a `TextIterator` for postings-list traversal
- `EstimateSize(is_vec_query)` - estimates result count for planner decisions

| Subclass | Query Syntax | Description |
|----------|-------------|-------------|
| `TermPredicate` | `word` or `"word"` | Exact or stemmed term match. `exact_` flag controls stemming |
| `PrefixPredicate` | `word*` | Matches terms starting with the prefix |
| `SuffixPredicate` | `*word` | Matches terms ending with the suffix |
| `InfixPredicate` | `*word*` | Matches terms containing the substring |
| `FuzzyPredicate` | `%%word%%` | Levenshtein edit-distance match. `distance_` stores the max edit distance (1-3 `%` pairs = distance 1-3) |

The field mask is set up by `SetupTextFieldConfiguration()`. When a text predicate is scoped to a specific field via `@field:`, only that field's bit is set. Without a field scope, all indexed text fields are included in the mask.

## ComposedPredicate (N-ary Tree)

`ComposedPredicate` is an N-ary logical operator node storing a vector of child predicates. The logical operator is encoded in the `PredicateType`: `kComposedAnd` or `kComposedOr`.

```cpp
ComposedPredicate(LogicalOperator logical_op,
                  vector<unique_ptr<Predicate>> children,
                  optional<uint32_t> slop = nullopt,
                  bool inorder = false);
```

Key properties:

- `children_` - vector of child predicates (N-ary, not binary)
- `slop_` - optional proximity window for SLOP queries
- `inorder_` - whether terms must appear in order (INORDER queries)
- `AddChild()` - appends a child predicate during tree construction
- `ReleaseChildren()` - transfers ownership of children out

During parsing, `WrapPredicate()` flattens nested compositions of the same type into a single N-ary node. For example, three ANDed terms become one `ComposedPredicate(kComposedAnd, [A, B, C])` rather than nested binary nodes.

`FlagNestedComposedPredicate()` sets `kContainsNestedComposed` in `query_operations_` when a composed predicate is nested inside another, which the planner uses for optimization decisions.

## NegatePredicate

Wraps a single child predicate and inverts its evaluation result:

```cpp
NegatePredicate(unique_ptr<Predicate> predicate);
```

Created when the parser encounters the `-` prefix operator. The negation affects planner decisions - queries containing negation always require prefilter evaluation and may use a universal set fetcher.

## QueryOperations Bitmask

`QueryOperations` is a `uint64_t` enum with bitwise operations. The parser sets flags as it encounters different predicate types. The bitmask drives planner and execution decisions.

| Flag | Value | Set When |
|------|-------|----------|
| `kNone` | `0` | Default, empty query |
| `kContainsOr` | `1 << 0` | Query has OR (`\|`) operators |
| `kContainsAnd` | `1 << 1` | Query has AND (implicit or explicit) |
| `kContainsNumeric` | `1 << 2` | Query references a numeric field |
| `kContainsTag` | `1 << 3` | Query references a tag field |
| `kContainsNegate` | `1 << 4` | Query uses negation (`-`) |
| `kContainsText` | `1 << 5` | Query references a text field |
| `kContainsProximity` | `1 << 6` | Query uses SLOP/INORDER proximity |
| `kContainsNestedComposed` | `1 << 7` | Composed predicate nested inside another |
| `kContainsTextTerm` | `1 << 8` | Contains an exact/stemmed term |
| `kContainsTextPrefix` | `1 << 9` | Contains a prefix search |
| `kContainsTextSuffix` | `1 << 10` | Contains a suffix search |
| `kContainsTextFuzzy` | `1 << 11` | Contains a fuzzy search |

Downstream usage in `search.cc`:

- `IsUnsolvedQuery()` - checks if prefilter evaluation is needed (AND with numeric/tag, or negation)
- `NeedsDeduplication()` - checks if OR, tag, or non-text negation requires dedup
- `IncrementQueryOperationMetrics()` - records counters per operation type

## Evaluator Interface

The `Evaluator` abstract class (in `predicate.h`) provides the visitor pattern for predicate evaluation:

```cpp
class Evaluator {
  virtual EvaluationResult EvaluateText(const TextPredicate&, bool require_positions) = 0;
  virtual EvaluationResult EvaluateTags(const TagPredicate&) = 0;
  virtual EvaluationResult EvaluateNumeric(const NumericPredicate&) = 0;
  virtual const InternedStringPtr& GetTargetKey() const = 0;
  virtual bool IsPrefilterEvaluator() const { return false; }
};
```

`EvaluationResult` carries a `bool matches` and an optional `TextIterator` for position-aware text matching. The iterator is used by proximity/SLOP evaluation in `ComposedPredicate::EvaluateWithContext()`.

The main implementation is `indexes::PrefilterEvaluator` (in `src/indexes/vector_base.h`), used during both inline and prefilter evaluation paths. It looks up values in the per-key indexes for tag and numeric fields, and uses the per-key `TextIndex` for text predicates.

## Safety Limits

The parser enforces configurable limits to prevent resource exhaustion from adversarial queries:

| Config | Default | Max | Purpose |
|--------|---------|-----|---------|
| `query-string-depth` | 1000 | UINT_MAX | Maximum nesting depth of parentheses |
| `query-string-terms-count` | 1000 | 10000 | Maximum number of predicate nodes in the tree |
| `fuzzy-max-distance` | 3 | 50 | Maximum Levenshtein distance for `%%` fuzzy queries |

The `level` parameter in `ParseExpression(level)` is checked against `query-string-depth`. The `node_count_` member is incremented at each predicate creation and checked against `query-string-terms-count`. Both return `InvalidArgumentError` when exceeded.

For vector queries, `max-vector-knn` limits the K parameter (default 10000, max 100000).

## TextParsingOptions

```cpp
struct TextParsingOptions {
  bool verbatim = false;   // Skip stemming
  bool inorder = false;    // Require term order (INORDER flag)
  optional<uint32_t> slop; // Proximity window (SLOP flag)
};
```

These options are set from the FT.SEARCH/FT.AGGREGATE command-level VERBATIM, INORDER, and SLOP parameters and passed to `FilterParser` at construction. They affect how `ComposedPredicate` nodes are created - when SLOP or INORDER is set, the top-level AND node carries those values for proximity evaluation.
