# Filter Expressions

Use when working with JSONPath filter expressions `[?(...)]`, comparison operators, boolean logic, attribute existence checks, type coercion rules, or the lexer tokenization pipeline.

Source: `src/json/selector.cc` (lines 1632-2295), `src/json/selector.h` (Token enum)

## Contents

- [Filter Expression Grammar](#filter-expression-grammar)
- [Parsing Pipeline](#parsing-pipeline)
- [Comparison Operators](#comparison-operators)
- [Boolean Operators](#boolean-operators)
- [Attribute Existence Filter](#attribute-existence-filter)
- [Comparison Values](#comparison-values)
- [Partial Path References](#partial-path-references)
- [Type Coercion Rules](#type-coercion-rules)
- [Array Contains Filter](#array-contains-filter)
- [Index-Based Filter](#index-based-filter)

## Filter Expression Grammar

The filter expression grammar (selector.cc:1632-1647):

```
Filter              ::= "?" "(" FilterExpr ")"
FilterExpr          ::= Term { "||" Term }
Term                ::= Factor { "&&" Factor }
Factor              ::= "@" [ MemberName ] [ ComparisonOp ComparisonValue ]
                      | ComparisonValue ComparisonOp "@" [ MemberName ]
                      | "(" FilterExpr ")"
MemberName          ::= ("." (UnquotedMemberName | BracketedMemberName))
                      | BracketedMemberName
BracketedMemberName ::= "[" QuotedMemberName "]"
ComparisonOp        ::= "<" | "<=" | ">" | ">=" | "==" | "!="
ComparisonValue     ::= "null" | Bool | Number | QuotedString | PartialPath
```

Filter expressions select array elements (or object members) that satisfy a boolean condition. The `@` symbol refers to the current element being tested. Results are indices into the current array.

Filters can appear in two syntactic positions:
- After a bracket subscript: `$[?(@.price > 10)]`
- After a wildcard: `$.*[?(@.active == true)]` or `$[*][?(@.x > 5)]`

## Parsing Pipeline

Filter parsing follows standard operator-precedence with three levels (selector.cc:1648-1886):

1. **parseFilter()** (selector.cc:1648) - entry point. Consumes `?` and `(`, delegates to `parseFilterExpr()`, expects `)` and `]`.

2. **parseFilterExpr()** (selector.cc:1693) - handles OR (`||`). Parses first Term, then for each `||` token, parses another Term and unions the index vectors. Uses `vectorUnion()` which preserves order and uses a set for deduplication.

3. **parseTerm()** (selector.cc:1722) - handles AND (`&&`). Parses first Factor, then for each `&&` token, parses another Factor and intersects the index vectors. Uses `vectorIntersection()` which preserves order from the first vector.

4. **parseFactor()** (selector.cc:1754) - handles three forms:
   - `@.member op value` - left-hand attribute comparison
   - `value op @.member` - right-hand attribute comparison (operators are swapped via `swapComparisonOpSide()`)
   - `(FilterExpr)` - parenthesized sub-expression for grouping

Parenthesized sub-expressions recurse into `parseFilterExpr()`, enabling arbitrary nesting. Both `parseFilterExpr()` and `parseTerm()` apply `CHECK_RECURSION_DEPTH()` to prevent stack overflow.

The result of each filter evaluation is a `jsn::vector<int64_t>` containing indices of matching array elements.

## Comparison Operators

Six comparison operators are supported (selector.cc:1982-2019):

| Operator | Token | Description |
|----------|-------|-------------|
| `==` | EQ | Equal |
| `!=` | NE | Not equal |
| `<` | LT | Less than |
| `<=` | LE | Less than or equal |
| `>` | GT | Greater than |
| `>=` | GE | Greater than or equal |

`parseComparisonOp()` (selector.cc:1984) skips spaces, reads the operator token, and advances. `swapComparisonOpSide()` (selector.cc:1999) flips the direction when the value appears before `@`:
- EQ and NE are symmetric - no change
- GT swaps to LT, LT to GT
- GE swaps to LE, LE to GE

`10 > @.price` is internally treated the same as `@.price < 10`.

## Boolean Operators

AND and OR combine filter sub-expressions using set operations on index vectors (selector.cc:1693-1738):

**OR (`||`)** - `vectorUnion()` (selector.cc:2304-2310) merges indices from both operands, preserving order and deduplicating via an `unordered_set<int64_t>`. The first term's results come first, then unique elements from subsequent terms.

**AND (`&&`)** - `vectorIntersection()` (selector.cc:2315-2323) keeps only indices present in both operands. Preserves the order from the left operand. Uses a set built from the right operand for O(1) lookup.

Operator precedence: AND binds tighter than OR (standard). Parentheses override precedence:

```
$[?(@.a > 1 && @.b < 5 || @.c == true)]     # (a>1 AND b<5) OR c==true
$[?((@.a > 1) && (@.b < 5 || @.c == true))]  # a>1 AND (b<5 OR c==true)
```

## Attribute Existence Filter

`processAttributeFilter()` (selector.cc:2279-2295) handles the case where `@.member` appears with no comparison operator:

```
$[?(@.name)]
```

This selects array elements that have the named attribute, regardless of its value. The implementation:

- For arrays: iterates elements, skips non-objects, checks `FindMember()` for the attribute name. Pushes the index if the member exists.
- For objects: checks if the object has the named member. Pushes index 0 if found (treating the object as a single-element collection).
- For scalars: returns `JSONUTIL_INVALID_JSON_PATH`.

The attribute filter is triggered in `parseFactor()` when `@.member` is followed by a non-operator token (e.g., `)` or `&&` or `||`) rather than a comparison operator (selector.cc:1830-1832).

**Self-reference** (`@` without `.member`): When `@` appears directly with a comparison operator, the `is_self` flag in `processComparisonExpr()` (selector.cc:2084-2110) compares the array element itself rather than a child member. This enables filters like `$[?(@ > 5)]` on scalar arrays.

## Comparison Values

`parseComparisonValue()` (selector.cc:1924-1978) parses the right-hand side of a comparison:

| Type | Detection | Parsing |
|------|-----------|---------|
| null | Token ALPHA starting with `n` | `scanIdentifier()`, verify == "null" |
| true/false | Token ALPHA starting with `t` or `f` | `scanIdentifier()`, verify == "true" or "false" |
| Number | Token DIGIT, PLUS, or MINUS | `scanNumberInFilterExpr()`, supports scientific notation |
| Quoted string | Token DOUBLE_QUOTE | `scanDoubleQuotedString()` via JParser |
| Quoted string | Token SINGLE_QUOTE | `scanSingleQuotedStringAndConvertToDoubleQuotedString()` |
| Partial path | Token DOLLAR | `scanPathValue()`, then evaluate via nested Selector |

All parsed values are converted to a `JValue` for comparison. String and number literals are parsed through JParser to get proper RapidJSON values. Single-quoted strings are first converted to double-quoted form then parsed.

## Partial Path References

A comparison value can be a `$`-prefixed JSONPath that resolves against the root document (selector.cc:1928-1941):

```
$[?(@.price < $.expensive)]
```

Implementation:
1. `scanPathValue()` scans the partial path string, tracking bracket nesting and quotes
2. A new temporary `Selector` is created
3. `selector.getValues(*root, path)` evaluates the path against the document root
4. The result must be exactly one scalar value (not an object or array)
5. The value is copied into a JValue for use in the comparison

Enables dynamic comparisons where the threshold comes from another part of the document.

## Type Coercion Rules

`evalOp()` (selector.cc:2112-2277) performs the actual comparison. The type system is strict with one exception:

**Type mismatch returns false** - if the left-hand value's RapidJSON type differs from the comparison value's type, the comparison evaluates to false. No implicit coercion between strings and numbers, or between null and other types.

**Exception: booleans** - `kTrueType` and `kFalseType` are treated as the same type for comparison purposes (selector.cc:2114-2116). Allows `true == true` and `true != false` to work correctly despite RapidJSON using separate type tags.

Per-type comparison rules:

| Type | EQ | NE | LT/LE/GT/GE |
|------|----|----|-------------|
| null | Always true (null == null) | N/A (single value) | Not supported |
| boolean | `GetBool()` comparison | `GetBool()` comparison | `GetBool()` < ordering |
| string | `GetStringView()` == | `GetStringView()` != | Lexicographic `string_view` comparison |
| number (int) | `GetInt64()` == | `GetInt64()` != | `GetInt64()` ordering |
| number (uint64) | `GetUint64()` == | `GetUint64()` != | `GetUint64()` ordering |
| number (double) | Uses <= and >= (avoids float ==) | Uses < or > | `GetDouble()` ordering |
| object/array | Not compared | Not compared | Not compared |

**Float equality** - instead of `==`, the code checks `v <= comp && v >= comp` to avoid compiler warnings about floating-point equality (selector.cc:2137-2138). For `!=`, it checks `v < comp || v > comp`.

**Number subtype selection** - when either operand is double, double comparison is used. When both are uint64, uint64 comparison is used. Otherwise int64 comparison is used.

## Array Contains Filter

`processArrayContains()` (selector.cc:2024-2051) handles nested array membership tests:

```
$[?(@.tags[?(@=="active")])]
```

Checks whether each element's `.tags` sub-array contains a value matching the condition. The implementation:

1. Iterates the current array's elements
2. For each element that is an object, finds the named member
3. If the member is an array, iterates its elements
4. Applies `evalOp()` to each inner element
5. If any inner element matches, pushes the outer index to results
6. Uses a `found` flag to stop after the first match per outer element

Only looks one level deep - further nesting is not recursed. The syntax requires `@.member[?(@` followed by an operator and value, closed with `)]`.

## Index-Based Filter

`processComparisonExprAtIndex()` (selector.cc:2053-2081) handles filters that compare a specific array index:

```
$[?(@.scores[0] > 90)]
```

Checks the element at a specific index within each element's sub-array. The implementation:

1. Iterates the current array's elements
2. For each element that is an object, finds the named member
3. If the member is an array, resolves the index (supporting negative indices)
4. Applies `evalOp()` to the element at that index
5. Pushes the outer index if the comparison succeeds

Allows filtering based on a specific position within nested arrays.
