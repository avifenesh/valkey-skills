# valkey-json - Native JSON Data Type

Use when storing, querying, or manipulating JSON documents in Valkey, migrating from RedisJSON, or integrating JSON operations with GLIDE clients.

---

## Overview

valkey-json adds a native JSON data type to Valkey with full JSONPath query support. It is a drop-in replacement for RedisJSON - API and RDB compatible with RedisJSON v1 and v2.

| Property | Value |
|----------|-------|
| Status | GA |
| License | BSD |
| Language | C++ (uses RapidJSON parser) |
| Redis equivalent | RedisJSON |
| Compatibility | API + RDB compatible with RedisJSON v1.0.8+ and v2 |
| Valkey version | 8.0+ |
| Included in | valkey-bundle container image |

## Key Commands

### Core Operations

| Command | Description |
|---------|-------------|
| `JSON.SET key path value [NX\|XX]` | Set a JSON value at a path. NX = only if not exists, XX = only if exists |
| `JSON.GET key [path ...]` | Get one or more paths from a JSON document |
| `JSON.MGET key [key ...] path` | Get a path from multiple keys atomically |
| `JSON.DEL key [path]` | Delete a value at a path (or the entire key) |
| `JSON.TYPE key [path]` | Return the JSON type at a path |

### Numeric Operations

| Command | Description |
|---------|-------------|
| `JSON.NUMINCRBY key path value` | Increment a numeric value at a path |
| `JSON.NUMMULTBY key path value` | Multiply a numeric value at a path |

### String Operations

| Command | Description |
|---------|-------------|
| `JSON.STRLEN key [path]` | Get the length of a string value |
| `JSON.STRAPPEND key [path] value` | Append to a string value |

### Array Operations

| Command | Description |
|---------|-------------|
| `JSON.ARRAPPEND key path value [value ...]` | Append elements to an array |
| `JSON.ARRINSERT key path index value [value ...]` | Insert elements at an index |
| `JSON.ARRINDEX key path value [start [stop]]` | Find the index of an element |
| `JSON.ARRLEN key [path]` | Get array length |
| `JSON.ARRPOP key [path [index]]` | Pop an element from an array |
| `JSON.ARRTRIM key path start stop` | Trim an array to a range |

### Object Operations

| Command | Description |
|---------|-------------|
| `JSON.OBJKEYS key [path]` | Get keys of a JSON object |
| `JSON.OBJLEN key [path]` | Get number of keys in a JSON object |

### Utility Commands

| Command | Description |
|---------|-------------|
| `JSON.CLEAR key [path]` | Clear arrays, objects, and reset numbers to 0 |
| `JSON.TOGGLE key path` | Toggle a boolean value |
| `JSON.RESP key [path]` | Return the value in RESP format |
| `JSON.DEBUG MEMORY key [path]` | Report memory usage of a JSON value |
| `JSON.DEBUG FIELDS key [path]` | Report number of fields in a JSON value |

## Performance

valkey-json uses the RapidJSON library - a header-only C++ JSON parser with no external dependencies. Memory overhead is 16 bytes per JSON value on most 32/64-bit architectures.

## JSONPath Syntax

valkey-json supports full JSONPath query language - wildcard selections, filter expressions, array slices, union operations, and recursive searches. Complies with RFC 7159 and ECMA-404.

Two path syntaxes are available:

### Restricted Syntax (RedisJSON v1 compatible)

- Dot-notation: `.store.book[0].title`
- Root is implicit or starts with `.`
- Returns a single value from the first match
- Backward compatible with RedisJSON v1

### Enhanced Syntax (Goessner-style JSONPath)

- Dollar-notation: `$.store.book[*].author`
- Root is `$`
- Returns arrays of all matching values
- Supports wildcards, recursive descent, array slicing, and filter expressions

| Syntax | Example | Description |
|--------|---------|-------------|
| `$` | `$` | Root element |
| `$.field` | `$.name` | Child field |
| `$..field` | `$..price` | Recursive descent |
| `$[*]` | `$.items[*]` | All array elements |
| `$[0:3]` | `$.items[0:3]` | Array slice |
| `$[?(@.price<10)]` | `$.items[?(@.price<10)]` | Filter expression |

When mixing both syntaxes in a multi-path `JSON.GET`, all paths are treated as enhanced JSONPath.

## Usage Examples

```
# Store a JSON document
JSON.SET user:1 $ '{"name":"Alice","age":30,"tags":["admin"]}'

# Read a nested value
JSON.GET user:1 $.name
# '["Alice"]'

# Increment a number
JSON.NUMINCRBY user:1 $.age 1
# '[31]'

# Append to an array
JSON.ARRAPPEND user:1 $.tags '"developer"'
# '[2]'

# Conditional set (only if path does not exist)
JSON.SET user:1 $.email '"alice@example.com"' NX

# Get multiple paths in one call
JSON.GET user:1 $.name $.age $.tags

# Multi-key get
JSON.MGET user:1 user:2 user:3 $.name
```

## Client Integration via GLIDE

GLIDE provides dedicated JSON APIs as static utility classes. These use `customCommand` internally and work with both standalone and cluster clients.

| Language | Class | Import |
|----------|-------|--------|
| Node.js | `GlideJson` | `@valkey/valkey-glide` |
| Java | `Json` | `glide.api.commands.servermodules.Json` |
| Python | `json` | `glide.json` |

See the **valkey-glide** skill for complete API reference and code examples across all languages.

## RDB Compatibility

valkey-json RDB format is compatible with:

- RedisJSON v1.0.8 and later v1 releases
- RedisJSON v2 (all versions)

This means you can migrate from a Redis instance with RedisJSON to Valkey with valkey-json by importing RDB snapshots directly. The reverse is also true - RDB files from valkey-json can be loaded by RedisJSON.

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| 1.0.0 | April 2025 | Initial GA release |
| 1.0.1 | June 2025 | Bug fixes and stability improvements |
| 1.0.2 | September 2025 | macOS/Clang build support, SharedAPI interface for inter-module access |

**Open community requests**: JSON.MERGE support has been requested but is not yet available.

**AWS ElastiCache**: Supports JSON natively for Valkey 7.2+ (their versioning) as a built-in feature, not via module loading.

## When to Use

| Scenario | Recommendation |
|----------|---------------|
| Nested document storage with path queries | valkey-json |
| Simple flat key-value pairs | Core Valkey Strings or Hashes |
| Documents indexed for vector search | valkey-json + valkey-search (indexes JSON fields) |
| High-throughput atomic counter | Core Valkey INCR (faster than JSON.NUMINCRBY) |
| Documents with array manipulation | valkey-json (native array operations) |

## Cross-References

- [overview.md](overview.md) - Module system overview and loading
- [search.md](search.md) - valkey-search can index JSON document fields
- [gaps.md](gaps.md) - Feature comparison with Redis Stack
- `clients/landscape.md` - client library decision framework
- **valkey-glide** skill - GlideJson / Json API for Python, Java, Node.js
