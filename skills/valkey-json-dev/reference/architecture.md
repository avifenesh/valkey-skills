# valkey-json Architecture

Use when understanding the document model, JSONPath engine internals, object hash tables, memory layout, RDB serialization, or the KeyTable string interning system.

## Contents

- Document Model (line 14)
- JSONPath Engine (Selector) (line 66)
- Memory Architecture (line 126)
- KeyTable (String Interning) (line 147)
- RDB Serialization (line 165)
- Defragmentation (line 190)

## Document Model

Each Valkey key holding JSON maps to one `JDocument`. A JDocument is a tree of `JValue` nodes backed by RapidJSON's `GenericValue`.

```
JDocument (inherits JValue)
  +-- size:56 bits   - total memory of this document tree
  +-- bucket_id:8    - histogram bucket for stats
  +-- JValue (root)  - the RapidJSON tree
```

JDocument is 1:1 with a Valkey key. It is heap-allocated via `dom_alloc` (which wraps `ValkeyModule_Alloc`) and tracked in the module's custom memory accounting. The Valkey data type name is `ReJSON-RL` (encoding version 3).

### Type System

RapidJSON supports seven value types. The module maps them directly:

| RapidJSON Type | JSON Type | Storage |
|---------------|-----------|---------|
| kNullType | null | No payload |
| kTrueType/kFalseType | boolean | Encoded in type tag |
| kNumberType (int64) | integer | 64-bit signed |
| kNumberType (double) | number | Stored as string text (avoids precision loss) |
| kStringType | string | Length-prefixed, UTF-8 |
| kObjectType | object | Member vector or hash table of (key, value) pairs |
| kArrayType | array | Contiguous element array |

Numbers are stored as string text internally (not as native doubles) to preserve the exact representation from the original JSON input. The `jsonutil_double_to_string` helpers format numbers for output.

### Custom RapidJSON Allocator

`RapidJsonAllocator` is a custom allocator class passed as a template parameter to RapidJSON's GenericValue and GenericDocument. It delegates all allocations to `dom_alloc`/`dom_free`/`dom_realloc`, which in turn call the memory layer. This ensures all RapidJSON-internal allocations are reported to the Valkey engine via `MEMORY STATS`.

There is exactly one global `RapidJsonAllocator allocator` instance. The constructor asserts that only this single instance exists.

### SIMD Optimization

RapidJSON parsing uses platform-specific SIMD (configured in `rapidjson_includes.h`):
- x86_64: SSE4.2 (`RAPIDJSON_SSE42`)
- ARM: NEON (`RAPIDJSON_NEON`)
- 48-bit pointer optimization enabled (`RAPIDJSON_48BITPOINTER_OPTIMIZATION`)

### Object Member Hash Table

The vendored RapidJSON in `src/rapidjson/document.h` is heavily modified to support an inline hash table for JSON object members. Small objects use a flat member vector (same as upstream RapidJSON). When an object grows past `HashTableFactors::minHTSize` (default 32) members, it auto-converts to an open-addressing hash table for O(1) member lookup instead of O(n) linear scan.

Key details:
- `kHashTableFlag` (0x2000) in the value's flags marks hash table mode
- `HashTableFactors` controls load factors and grow/shrink thresholds (same pattern as KeyTable)
- `HashTableStats` tracks rehash-up, rehash-down, and vector-to-HT conversions
- The hash table is integrated with KeyTable - object member names are interned handles

## JSONPath Engine (Selector)

The `Selector` class in `selector.cc/.h` is a recursive-descent parser and evaluator supporting both v1 (legacy dot-notation) and v2 (dollar-prefix JSONPath) syntax.

### Path Detection

- Paths starting with `$` are v2 JSONPath
- All other paths are v1 legacy syntax
- Detection is automatic per query

### EBNF Grammar (abbreviated)

```
SupportedPath       ::= ["$" | "."] RelativePath
RelativePath        ::= RecursivePath | DotPath | BracketPath | QualifiedPath
RecursivePath       ::= ".." SupportedPath
DotPath             ::= "." QualifiedPath
BracketPathElement  ::= "[" (Wildcard | Name | IndexExpr) "]"
IndexExpr           ::= Filter | Slice | Union | Index
Filter              ::= "?(" FilterExpr ")"
FilterExpr          ::= Term {"||" Term}
```

### Supported Features

- Dot notation: `$.store.book`
- Bracket notation: `$['store']['book']`
- Wildcards: `$.*`, `$[*]`
- Recursive descent: `$..price`
- Array slices: `$[0:3]`, `$[::2]`, `$[-1:]`
- Union of indexes: `$[0,2,4]`
- Union of names: `$['a','b']`
- Filter expressions: `$[?(@.price < 10)]`
- Comparison operators in filters: `==`, `!=`, `<`, `<=`, `>`, `>=`
- Logical operators: `&&`, `||`

### Operating Modes

The Selector operates in one of these modes:

| Mode | Entry Point | Produces |
|------|------------|----------|
| READ | `getValues()` | resultSet of (JValue*, path) pairs |
| INSERT_OR_UPDATE | `setValues()` | resultSet (updates) + insertPaths (new keys) |
| DELETE | `deleteValues()` | resultSet of values to remove |

The two-stage write (`prepareSetValues` + `commit`) allows validation before mutating.

### Safety Limits

| Limit | Default | Configurable | Purpose |
|-------|---------|-------------|---------|
| max-path-limit | 128 | `CONFIG SET json.max-path-limit` | Max nesting depth |
| max-document-size | 0 (unlimited) | `CONFIG SET json.max-document-size` | Max bytes per document |
| max-parser-recursion-depth | 200 | compile-time only | Selector recursion limit |
| max-recursive-descent-tokens | 20 | compile-time only | Token limit for `..` queries |
| max-query-string-size | 128KB | compile-time only | Max path string length |

Only `max-path-limit` and `max-document-size` are registered as module configs via `registerModuleConfigs()`. The other three are static defaults in `json.cc` - changing them requires recompilation.

## Memory Architecture

### Three-Layer Allocator Stack

1. **memory layer** (`memory.cc`) - wraps `ValkeyModule_Alloc`/`ValkeyModule_Free`, provides memory traps (diagnostics for double-free, overwrite, dangling pointer), custom STL allocator (`jsn::stl_allocator`)
2. **dom_alloc layer** (`alloc.cc`) - wraps memory layer, tracks per-document and global memory via `jsonstats_increment_used_mem`/`jsonstats_decrement_used_mem`
3. **RapidJsonAllocator** - template adapter routing RapidJSON allocations to dom_alloc

### jsn:: Namespace

STL containers used in the module use custom allocators under the `jsn::` namespace:

- `jsn::vector<T>`, `jsn::set<T>`, `jsn::unordered_set<T>`
- `jsn::string`, `jsn::stringstream`

Note: `jsn::stl_allocator` currently uses `std::malloc`/`std::free` directly (not the global `memory_alloc`/`memory_free` function pointers). This means jsn:: container allocations are not tracked by the module's memory accounting or protected by memory traps. Only dom_alloc-routed allocations (DOM tree nodes, RapidJSON internals) are fully tracked.

### Memory Traps

Diagnostic feature (dynamically toggleable when no allocations outstanding). Each allocation gets a prefix/suffix with known patterns. Catches double-free, buffer overrun, and dangling pointers. Controlled via `memory_traps_control(bool)`.

## KeyTable (String Interning)

The KeyTable is a thread-safe, sharded hash table that deduplicates JSON object member names across all documents.

### Structure

- Sharded linear-probing hash table (default 32768 shards)
- Each unique string stored in a separately malloc'd `KeyTable_Layout` struct
- Reference-counted (29-bit saturating counter)
- Handle is 8 bytes: pointer + 19 bits of metadata (shard number) packed via `PtrWithMetaData`
- Hash function: FNV-1a 64-bit, XOR-folded to 38 bits

### Operations

- `makeHandle(string)` - insert or find, increment refcount, return handle
- `destroyHandle(handle)` - decrement refcount, remove if zero
- Handle comparison is pointer comparison (same string = same handle)

## RDB Serialization

### Encoding Version 3 (Current)

Serializes the entire document as a single JSON string buffer:
1. `dom_save`: serialize document to `StringBuffer`, call `ValkeyModule_SaveStringBuffer`
2. `dom_load`: read string buffer, call `dom_parse` to reconstruct the tree

### Encoding Version 0 (Legacy)

Node-by-node binary format using metacodes:

| Metacode | Value | Followed By |
|----------|-------|-------------|
| NULL (0x01) | - | nothing |
| STRING (0x02) | - | string buffer |
| DOUBLE (0x04) | - | double (legacy format) |
| INTEGER (0x08) | - | signed 64-bit |
| BOOLEAN (0x10) | - | string "1" or "0" |
| OBJECT (0x20) | - | member count, then N PAIR entries |
| ARRAY (0x40) | - | element count, then N JValue entries |
| PAIR (0x80) | - | string key + JValue |

Version 0 is read-only (for backward compatibility). All new saves use version 3.

## Defragmentation

The `DocumentType_Defrag` callback copies the entire document via `dom_copy` and swaps it in. This is only done for documents under the `defrag-threshold` internal default (64MB, defined as `DEFAULT_DEFRAG_THRESHOLD` in `json.cc`). Large documents are skipped because the current implementation does not support stop-and-resume defrag. This threshold is not exposed as a `CONFIG SET` parameter.
