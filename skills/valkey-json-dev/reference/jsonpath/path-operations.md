# Path Operations

Use when working with dot notation, bracket notation, wildcards, recursive descent, array slicing, index unions, or understanding how path operations map to DOM mutations.

Source: `src/json/selector.cc` (path operation methods), `src/json/dom.cc` (CRUD operations)

## Contents

- [Dot Notation](#dot-notation)
- [Bracket Notation](#bracket-notation)
- [Wildcards](#wildcards)
- [Recursive Descent](#recursive-descent)
- [Array Slicing](#array-slicing)
- [Array Index Union](#array-index-union)
- [Member Name Union](#member-name-union)
- [Path to DOM Mutation Mapping](#path-to-dom-mutation-mapping)

## Dot Notation

Dot notation accesses object members by unquoted name. Handled by `parseDotPath()` and `parseKey()` (selector.cc:1038-1222).

```
$.store.book       # traverse to store, then book
$.store.*          # wildcard all members of store
```

`parseDotPath()` (selector.cc:1038-1041) consumes the `.` token and delegates to `parseQualifiedPath()`, which calls `parseKey()`.

`parseKey()` (selector.cc:1208-1222) has two branches:
- Wildcard `*` - optionally followed by a filter expression `[?(...)]`
- Unquoted member name - scanned by `Lexer::scanUnquotedMemberName()` which reads until hitting any terminator character: `.[]()<>=!'" |&`

Member lookup uses `traverseToObjectMember()` (selector.cc:1358-1416):
1. Checks the current node is an object - if not, behavior depends on mode (READ silently ends the branch; WRITE returns an error)
2. Calls `node->FindMember(name)` on the RapidJSON object
3. If found: appends the member name to `nodePath` (escaped for JSON Pointer - `/` becomes `~1`) and advances `node`
4. If not found in WRITE mode: appends to `insertPaths` if this is the last path element; returns `JSON_PATH_NOT_EXIST` if there are more path elements

## Bracket Notation

Bracket notation supports quoted member names, index expressions, wildcards, and filters. Parsed by `parseBracketPathElement()` (selector.cc:1060-1083).

```
$['store']              # quoted member name
$["store"]              # double-quoted member name
$['first name']         # member name with spaces
$[0]                    # array index
$[-1]                   # negative index (from end)
$[*]                    # wildcard
$[?(@.price > 10)]      # filter
```

The method dispatches based on the first token after `[`:
- `*` token -> `parseWildcardInBrackets()` - may be followed by a filter `[?(...)]`
- Single/double quote -> `parseNameInBrackets()` - quoted member name(s)
- Anything else -> `parseIndexExpr()` - filter, slice, union, or simple index

**Quoted member names** (selector.cc:1114-1133, 1169-1182): both single and double quotes are supported. Double-quoted strings are unescaped via `JParser::Parse()`. Single-quoted strings go through `scanSingleQuotedString()` which handles `\'` escape sequences and converts control characters. Multiple quoted names separated by commas form a member union:

```
$['name', 'age']       # union of two member names
```

**Array index** traversal uses `traverseToArrayIndex()` (selector.cc:1418-1447):
1. Negative indices are converted: `idx += node->Size()`
2. Bounds checking: returns `INDEX_OUT_OF_ARRAY_BOUNDARIES` if out of range
3. Appends the index to `nodePath` and advances `node`

## Wildcards

Wildcards match all children of the current node. Handled by `processWildcard()` (selector.cc:1254-1265).

For objects - `processWildcardKey()` (selector.cc:1267-1283): iterates all object members. For each member, snapshots state, calls `evalObjectMember()` to continue parsing the remaining path, then restores state. Syntax errors abort the entire search; non-syntax errors just end that branch.

For arrays - `processWildcardIndex()` (selector.cc:1285-1296): iterates all array elements by index. For each index, calls `evalArrayMember()` to continue parsing the remaining path.

For scalars - returns `INVALID_USE_OF_WILDCARD` (non-syntax error) in v2 mode, or `INVALID_JSON_PATH` (syntax error) in v1 mode.

The wildcard with filter pattern `[*][?(@.x > 5)]` (selector.cc:1088-1108) first processes the wildcard, then applies the filter to each resulting array. This is parsed as two separate bracket elements.

**State management** is critical for wildcards and recursive operations. The `State` struct (selector.h:231-244) captures:
- `currNode` - current JValue pointer
- `nodePath` - current path string
- `currPathPtr` - lexer position in the path string
- `currToken` - current lexer token
- `currPathDepth` - current nesting depth

`snapshotState()` saves and `restoreState()` restores these fields, enabling the selector to fork exploration of multiple branches and backtrack.

## Recursive Descent

The `..` operator performs DFS over the entire subtree. Implemented by `parseRecursivePath()` and `recursiveSearch()` (selector.cc:962-1033).

`parseRecursivePath()` (selector.cc:962-971):
1. Sets `isRecursiveSearch = true` (suppresses inserts)
2. Consumes the `..` token
3. Checks `CHECK_RECURSIVE_DESCENT_TOKENS()` limit (default 20 `..` tokens per query)
4. Calls `recursiveSearch()` on the current node
5. Calls `dedupe()` to remove duplicates from multiple traversal paths

`recursiveSearch()` (selector.cc:979-1033) implements DFS:
1. Rejects three or more consecutive dots as invalid (selector.cc:982-985)
2. Rejects non-container nodes (neither object nor array) by nulling the node
3. At each visited node: snapshots state, runs the evaluator with remaining path, restores state
4. If syntax error occurs during evaluation, propagates immediately
5. Descends into children:
   - Objects: iterates members, appends each name to `nodePath`, recurses, restores path
   - Arrays: iterates by index, appends index to `nodePath`, recurses, restores path
6. Nulls out `node` when done

The recursive search visits every node in the subtree. At each node, it attempts to match the remaining path after `..`. This means `$..price` visits every node and tries to match `.price` from each.

**Performance implications**: `..` is the most expensive operation. Each `..` token can fan out to every node in the document. The `rdTokens` counter (default limit 20) prevents queries with excessive `..` usage. The `CHECK_RECURSION_DEPTH()` macro (default 200) prevents stack overflow from deep nesting.

## Array Slicing

Array slicing selects a range of elements. Syntax: `[start:end:step]`. Handled by `parseSliceStartsWithColon()`, `parseSliceStartsWithInteger()`, `parseEndAndStep()`, `parseStep()`, and `processSlice()` (selector.cc:1490-1630).

```
$[0:3]          # elements 0, 1, 2
$[1:]           # elements from index 1 to end
$[:2]           # elements 0, 1
$[::2]          # every other element (step 2)
$[-2:]          # last two elements
$[3:0:-1]       # elements 3, 2, 1 (reverse with negative step)
```

Omitted components default to: start=0, end=array.Size(), step=1.

`processSlice()` (selector.cc:1591-1630) implementation:
1. Verifies current node is an array
2. Handles negative indices: `start += Size()`, `end += Size()`
3. Rejects step=0 with `STEP_CANNOT_NOT_BE_ZERO`
4. Clamps out-of-bounds indices to `[0, Size()]`
5. Iterates with the step value:
   - Positive step: `for (i = start; i < end; i += step)`
   - Negative step: `for (i = start; i > end; i += step)` (note: `i += step` where step is negative)
6. Calls `evalArrayMember(i)` for each selected index to continue parsing remaining path

The parsing flow branches based on which components are present:
- `[:...]` - `parseSliceStartsWithColon()` (start defaults to 0)
- `[n:...]` - `parseSliceStartsWithInteger()` (start is explicit)
- `[n]` alone - falls through to `processSubscript()`

## Array Index Union

Index unions select multiple specific elements. Syntax: `[idx1,idx2,idx3]`. Handled by `parseUnionOfIndexes()` and `processUnion()` (selector.cc:2328-2383).

```
$[0,2,4]        # elements at indices 0, 2, 4
$[0,-1]         # first and last elements
```

`parseUnionOfIndexes()` (selector.cc:2328-2366):
1. Verifies current node is an array
2. Starts with the first already-parsed index
3. Reads comma-separated integers, rejecting double commas or trailing commas
4. Delegates to `processUnion()`

`processUnion()` (selector.cc:2368-2383):
1. Iterates the index vector
2. Handles negative indices: `i += node->Size()`
3. Skips out-of-bounds indices silently (no error)
4. Calls `evalArrayMember(i)` for each valid index

## Member Name Union

Member name unions select multiple object members. Syntax: `['name1','name2']`. Handled by `parseNameInBrackets()` and `processUnionOfMembers()` (selector.cc:1114-1164).

```
$['name','age']         # two members
$["first","last"]       # double-quoted variant
```

`parseNameInBrackets()` (selector.cc:1114-1133) parses comma-separated quoted member names into a vector.

`processUnionOfMembers()` (selector.cc:1135-1164):
- Single name: delegates to `traverseToObjectMember()` (normal member access)
- Multiple names: requires current node to be an object. Iterates names, calls `FindMember()`, and evaluates each found member via `evalObjectMember()`. Missing members are silently skipped.

## Path to DOM Mutation Mapping

The Selector produces results that DOM functions consume. The flow:

| Command | DOM Function | Selector Usage | Mutation |
|---------|-------------|----------------|----------|
| JSON.SET | `dom_set_value()` | `prepareSetValues()` + `commit()` | `JPointer::Swap()` for updates, `JPointer::Set()` for inserts |
| JSON.DEL | `dom_delete_value()` | `deleteValues()` | `JPointer::Erase()` deepest-first |
| JSON.GET | `dom_get_value_as_str()` | `getValues()` | Read-only serialization |
| JSON.NUMINCRBY | `dom_increment_by()` | `getValues()` | In-place `SetInt64()` or `SetDouble()` on selected values |
| JSON.NUMMULTBY | `dom_multiply_by()` | `getValues()` | In-place `SetDouble()` on selected values |
| JSON.ARRAPPEND | `dom_array_append()` | `getValues()` | `PushBack()` on each selected array |
| JSON.ARRINSERT | `dom_array_insert()` | `getValues()` | Shift elements right, overwrite at index |
| JSON.ARRPOP | `dom_array_pop()` | `getValues()` | Serialize element, `Erase()` at index |
| JSON.ARRTRIM | `dom_array_trim()` | `getValues()` | `Erase()` elements outside [start, stop] |
| JSON.STRAPPEND | `dom_string_append()` | `getValues()` | Concatenate strings in-place |
| JSON.TOGGLE | `dom_toggle()` | `getValues()` | Flip boolean via `SetBool(!GetBool())` |

**Read-then-modify pattern** - most commands besides JSON.SET and JSON.DEL use `getValues()` to select targets, then mutate the returned JValue pointers directly. Since resultSet contains pointers into the live document, in-place mutations take effect immediately. `getUniqueResultSet()` ensures each value is modified only once even if matched by multiple path branches.

**Delete ordering** - `deleteValues()` sorts paths deepest-first using `pathCompare` (selector.cc:611-645). This comparator orders by path depth descending, then by element index descending within the same parent. This ensures children are removed before parents, preventing dangling references.

**Document size tracking** - DOM mutation functions use `CHECK_DOCUMENT_SIZE_LIMIT` and `CHECK_DOCUMENT_PATH_LIMIT` macros before committing changes. The two-stage write pattern in `dom_set_value()` is specifically designed to allow these checks between path evaluation and actual mutation.
