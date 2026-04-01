# JSONPath Selector

Use when working with the Selector class, Lexer, Token types, path syntax detection, operation modes, entry points, the EBNF grammar, or safety limits.

Source: `src/json/selector.h`, `src/json/selector.cc`

## Contents

- [Token and Lexer](#token-and-lexer)
- [Selector Class](#selector-class)
- [Path Syntax: v1 (Legacy) vs v2](#path-syntax-v1-legacy-vs-v2)
- [Operation Modes](#operation-modes)
- [Entry Points](#entry-points)
- [Two-Stage Write](#two-stage-write)
- [EBNF Grammar](#ebnf-grammar)
- [Safety Limits](#safety-limits)
- [Result Format](#result-format)

## Token and Lexer

`Token` (selector.h:8-29) is a struct with a `TokenType` enum and a `string_view` holding the matched text. Token types:

| Category | Types |
|----------|-------|
| Structure | DOLLAR, DOT, DOTDOT, WILDCARD, COLON, COMMA, AT, QUESTION_MARK |
| Brackets | LBRACKET, RBRACKET, LPAREN, RPAREN |
| Quotes | SINGLE_QUOTE, DOUBLE_QUOTE |
| Arithmetic | PLUS, MINUS, DIV, PCT |
| Comparison | EQ (==), NE (!=), GT (>), LT (<), GE (>=), LE (<=), NOT (!), ASSIGN (=) |
| Content | ALPHA, DIGIT, SPACE, SPECIAL_CHAR |
| Keywords | TRUE, FALSE, AND (&&), OR (\|\|) |
| Control | UNKNOWN, END |

Two-character tokens (DOTDOT, EQ, NE, GE, LE, AND, OR) are recognized by `peekToken()` which looks one character ahead. The DOTDOT token also increments `rdTokens` for recursive descent accounting (selector.cc:199).

`Lexer` (selector.h:65-99) holds the current position `p` into the path string and the current `next` token. Key methods:

- `init(path)` - reset position to start of path string
- `peekToken()` - look at next token type without consuming
- `nextToken(skipSpace)` - consume and return next token
- `matchToken(type, skipSpace)` - consume if type matches, return bool
- `scanInteger(val)` - scan signed integer from token stream
- `scanUnquotedMemberName(name)` - scan until terminator chars `.[]()<>=!'" |&`
- `scanNumberInFilterExpr(sv)` - scan number including scientific notation chars
- `scanDoubleQuotedString(parser)` - scan double-quoted string, unescape via JParser
- `scanSingleQuotedString(ss)` / `scanSingleQuotedStringAndConvertToDoubleQuotedString(ss)` - handle single-quoted strings
- `scanPathValue(output)` - scan a `$`-prefixed partial path used as a comparison value in filters
- `scanIdentifier(sv)` - scan alphanumeric identifier (for `null`, `true`, `false`)

## Selector Class

`Selector` (selector.h:145-368) is the JSONPath parser and evaluator. It combines parsing and evaluation in a single pass - there is no intermediate AST. The class name reflects that for READ mode it selects matching values, and for WRITE mode it selects values to update plus locations to insert.

Constructor takes an optional `force_v2_path_behavior` flag. Key members:

- `isV2Path` - set to true when `$` is encountered or forced at construction
- `root` - pointer to the document root JValue
- `node` - pointer to the current node being visited during traversal
- `nodePath` - JSON Pointer format string tracking the current node's location
- `lex` - embedded Lexer instance
- `resultSet` - vector of `ValueInfo` (JValue*, path) pairs - selected values
- `insertPaths` - set of JSON Pointer paths where inserts should occur
- `mode` - current operation mode (READ, INSERT, UPDATE, INSERT_OR_UPDATE, DELETE)
- `isRecursiveSearch` - flag suppressing inserts during `..` traversal
- `error` - stored error code for deferred reporting

The `ValueInfo` typedef is `std::pair<JValue*, jsn::string>` - a pointer to the matched value and the JSON Pointer path to reach it.

## Path Syntax: v1 (Legacy) vs v2

The selector auto-detects syntax at `parseSupportedPath()` (selector.cc:932-941):

```
SupportedPath ::= ["$" | "."] RelativePath
```

If the path starts with `$`, `isV2Path` is set to true. If it starts with `.` or directly with a member name, it remains v1.

**v1 (legacy) behavior:**
- Returns first matching value (scalar), not an array
- Returns NONEXISTENT error when no value matches
- Syntax errors fail the entire command
- Non-syntax errors also fail the command

**v2 ($-prefixed) behavior:**
- Returns all matching values wrapped in a JSON array
- Returns empty array `[]` when no value matches
- Syntax errors fail the command
- Non-syntax errors only terminate the current path branch; other branches continue

The static helper `has_at_least_one_v2path(paths, num_paths)` checks if any path in a multi-path command starts with `$`. When mixing v1 and v2 paths in `JSON.GET`, the entire command adopts v2 behavior (dom.cc:373).

**Error classification** (selector.cc:915-927) - the `isSyntaxError()` method distinguishes syntax errors (which abort all paths) from non-syntax errors (which only end one branch):

Syntax errors: `INVALID_JSON_PATH`, `INVALID_MEMBER_NAME`, `INVALID_NUMBER`, `INVALID_IDENTIFIER`, `EMPTY_EXPR_TOKEN`, `ARRAY_INDEX_NOT_NUMBER`, `STEP_CANNOT_NOT_BE_ZERO`, `PARENT_ELEMENT_NOT_EXIST`, and the three limit-exceeded codes.

Non-syntax errors: `JSON_PATH_NOT_EXIST`, `INDEX_OUT_OF_ARRAY_BOUNDARIES`, `JSON_ELEMENT_NOT_OBJECT`, `JSON_ELEMENT_NOT_ARRAY`, `INVALID_USE_OF_WILDCARD`.

## Operation Modes

The private `Mode` enum (selector.h:223-229):

| Mode | Set by | Purpose |
|------|--------|---------|
| READ | `getValues()` | Select values matching the path |
| INSERT | (internal) | Add new keys to objects |
| UPDATE | (internal) | Replace existing values |
| INSERT_OR_UPDATE | `setValues()` / `prepareSetValues()` | JSON.SET semantics - insert or update |
| DELETE | `deleteValues()` | Select values for deletion |

Mode affects behavior at `traverseToObjectMember()` (selector.cc:1358-1416):
- In READ mode, a missing member nulls out `node` - the branch silently ends.
- In INSERT/INSERT_OR_UPDATE mode, a missing member at the end of the path adds it to `insertPaths`. A missing member in the middle returns `JSONUTIL_JSON_PATH_NOT_EXIST`.
- The `isRecursiveSearch` flag prevents inserts during `..` traversal - you cannot insert new members into every object found during recursive descent.

Mode also affects wildcard behavior (selector.cc:1260-1264): applying `*` to a scalar is a syntax error in v1 but a non-syntax error in v2.

## Entry Points

### getValues (READ)

```cpp
JsonUtilCode getValues(JValue &root, const char *path);
```

Initializes in READ mode, runs the evaluator. On success, `resultSet` contains all matching (value, path) pairs. Called by `dom_get_value_as_str()`, `dom_increment_by()`, `dom_array_append()`, and other read-then-modify DOM functions (selector.cc:605-608).

### setValues (Single-Stage WRITE)

```cpp
JsonUtilCode setValues(JValue &root, const char *path, JValue &new_val);
```

Delegates to `prepareSetValues()` + `commit()`. Used when no precondition checks are needed (selector.cc:734-738).

### prepareSetValues + commit (Two-Stage WRITE)

```cpp
JsonUtilCode prepareSetValues(JValue &root, const char *path);
JsonUtilCode commit(JValue &new_val);
```

`prepareSetValues` runs path evaluation without modifying data. After checking preconditions (NX/XX flags, document size limits, path depth limits), the caller invokes `commit()` to apply mutations. This is the primary flow for `JSON.SET` via `dom_set_value()` (selector.cc:751-757, dom.cc:188-208).

### deleteValues (DELETE)

```cpp
JsonUtilCode deleteValues(JValue &root, const char *path, size_t &numValsDeleted);
```

Evaluates in DELETE mode, collects matching paths, then erases them. Multi-value deletes sort paths deepest-first using `pathCompare` to avoid invalidating parent paths before children are removed (selector.cc:647-716). Deletion uses `JPointer::Erase()` from RapidJSON.

## Two-Stage Write

The two-stage write pattern (selector.cc:740-876) exists to support:

1. **NX/XX flags** - `JSON.SET key path val NX` must not overwrite existing values. `prepareSetValues()` populates `resultSet` (updates) and `insertPaths` (inserts). `dom_set_value()` checks `hasUpdates()` / `hasInserts()` against the NX/XX flags before calling `commit()`.

2. **Document path depth limit** - `CHECK_DOCUMENT_PATH_LIMIT` compares `selector.getMaxPathDepth() + new_val.GetMaxDepth()` against `json_get_max_path_limit()` (default 128).

3. **Document size limit** - `CHECK_DOCUMENT_SIZE_LIMIT` compares current doc size plus new value size against `json_get_max_document_size()` (default 0 = unlimited).

The `commit()` method (selector.cc:762-876):
- **Updates**: iterates `getUniqueResultSet()`, uses `JPointer::Swap()` to replace each value in-place. For multi-value updates, copies `new_val` for each path since Swap moves the value.
- **Inserts**: iterates `insertPaths`, uses `JPointer::Set()` to create each new path. Again copies `new_val` for multi-insert.

The method does not expect both `resultSet` and `insertPaths` to be non-empty simultaneously in typical usage, but handles both if they are.

## EBNF Grammar

The full grammar is documented in selector.cc (lines 64-105). Summarized structure:

```
SupportedPath       ::= ["$" | "."] RelativePath
RelativePath        ::= empty | RecursivePath | DotPath | BracketPath | QualifiedPath
RecursivePath       ::= ".." SupportedPath
DotPath             ::= "." QualifiedPath
BracketPath         ::= BracketPathElement [ RelativePath ]
QualifiedPath       ::= QualifiedPathElement RelativePath
QualifiedPathElement ::= Key | BracketPathElement
Key                 ::= "*" [ [ "." ] WildcardFilter ] | UnquotedMemberName
BracketPathElement  ::= "[" ( "*" "]" | NameInBrackets | IndexExpr ) "]"
IndexExpr           ::= Filter | SliceStartsWithColon | SliceOrUnionOrIndex
Filter              ::= "?" "(" FilterExpr ")"
FilterExpr          ::= Term { "||" Term }
Term                ::= Factor { "&&" Factor }
Factor              ::= "@" [ MemberName ] [ ComparisonOp ComparisonValue ]
                      | ComparisonValue ComparisonOp "@" [ MemberName ]
                      | "(" FilterExpr ")"
ComparisonValue     ::= "null" | Bool | Number | QuotedString | PartialPath
PartialPath         ::= "$" RelativePath
```

Each grammar production maps to a `parse*()` method on the Selector. Parsing and evaluation are interleaved - the parser descends into the DOM tree as it consumes tokens.

## Safety Limits

Three compile-time macros enforce resource limits (selector.cc:42-62):

**RecursionDepthTracker** (selector.cc:42-55) - a thread-local `current_depth` counter incremented on construction, decremented on destruction. The `CHECK_RECURSION_DEPTH()` macro creates a tracker at function entry and returns `PARSER_RECURSION_DEPTH_LIMIT_EXCEEDED` if depth exceeds `json_get_max_parser_recursion_depth()`. Default: **200** levels. Applied in the evaluator, `evalMember()`, `parseFilterExpr()`, `parseTerm()`, `parseFactor()`, `parseComparisonValue()`.

**CHECK_RECURSIVE_DESCENT_TOKENS** (selector.cc:57-59) - counts `..` tokens via `lex.rdTokens`. Returns `RECURSIVE_DESCENT_TOKEN_LIMIT_EXCEEDED` when the count exceeds `json_get_max_recursive_descent_tokens()`. Default: **20** tokens. Checked in `parseRecursivePath()`.

**CHECK_QUERY_STRING_SIZE** (selector.cc:61-62) - `strlen(path)` check at `init()` time. Returns `QUERY_STRING_SIZE_LIMIT_EXCEEDED` when the path exceeds `json_get_max_query_string_size()`. Default: **128 KB**.

All limits are configurable at runtime via `CONFIG SET json.*` parameters.

## Result Format

After evaluation, results are in `resultSet` - a `jsn::vector<ValueInfo>` where each entry is a `(JValue*, jsn::string)` pair. The string is a JSON Pointer path (e.g., `/address/city`).

Key access methods:
- `hasValues()` / `hasUpdates()` - check if resultSet is non-empty
- `hasInserts()` - check if insertPaths is non-empty
- `getResultSet()` - const reference to resultSet
- `getSelectedValues(values)` - extract just the JValue pointers into a vector
- `getUniqueResultSet()` - deduplicated resultSet preserving insertion order (by JValue pointer identity)
- `dedupe()` - in-place deduplication of resultSet, called after recursive search

The `dedupe()` method (selector.cc:2416-2424) delegates to `getUniqueResultSet()` (selector.cc:2399-2411) which uses a pointer-based `unordered_set<JValue*>` to remove duplicate entries that can arise from recursive descent matching the same node via different traversal paths.
