# Module Commands

Use when working with Valkey modules that extend the core command set. Modules add specialized data types and operations - Bloom filters for probabilistic membership testing, JSON for document storage, and Search for full-text indexing.

Module commands are not part of the core Valkey server. They require loading the respective module via `MODULE LOAD` or `MODULE LOADEX`, or using a distribution that bundles them (such as the valkey-bundle container image).

---

## Module Availability

| Module | Status | Container | Notes |
|--------|--------|-----------|-------|
| Bloom (valkey-bloom) | Stable | valkey-bundle | Probabilistic membership testing |
| JSON (valkey-json) | Stable | valkey-bundle | JSON document storage and manipulation |
| Search (valkey-search) | In development | valkey-bundle | Full-text search and secondary indexing |

**Checking loaded modules**:

```
MODULE LIST
-- 1) 1) "name" 2) "bf" 3) "ver" 4) (integer) 1 5) "path" 6) "/usr/lib/valkey/modules/bloom.so"
-- 2) 1) "name" 2) "ReJSON" 3) "ver" 4) (integer) 20000 ...
```

**Loading a module** (requires admin privileges):

```
MODULE LOADEX /path/to/module.so [CONFIG name value ...] [ARGS arg ...]
```

---

## Bloom Filter Commands

Bloom filters answer "is this element in the set?" with either "definitely not" or "probably yes." They never produce false negatives but can produce false positives at a configurable rate. Use when you need fast membership testing with minimal memory - URL deduplication, spam detection, username availability checks.

A Bloom filter with 1 million items at 1% error rate uses approximately 1.14 MB.

### BF.RESERVE

```
BF.RESERVE key error_rate capacity [EXPANSION expansion] [NONSCALING]
```

Creates a new Bloom filter with specified parameters. Returns an error if the key already exists.

| Parameter | Description |
|-----------|-------------|
| `error_rate` | Target false positive rate (e.g., 0.01 for 1%) |
| `capacity` | Expected number of items |
| `EXPANSION` | Growth factor when capacity is reached (default 2) |
| `NONSCALING` | Return error when capacity is reached instead of growing |

```
-- 1% error rate, capacity for 100K items
BF.RESERVE user:emails 0.01 100000
-- OK

-- Tighter filter, no auto-scaling
BF.RESERVE dedup:urls 0.001 1000000 NONSCALING
-- OK
```

**Use when**: you know the expected capacity upfront and want to control the error rate. If you skip BF.RESERVE and go straight to BF.ADD, a default filter is created (error_rate=0.01, capacity=100).

### BF.ADD

```
BF.ADD key item
```

Adds an item to the Bloom filter. Creates the filter with default parameters if it does not exist. Returns 1 if the item is newly added, 0 if it may have existed already.

**Complexity**: O(K) where K is the number of hash functions

```
BF.ADD seen:urls "https://example.com/page1"
-- (integer) 1

BF.ADD seen:urls "https://example.com/page1"
-- (integer) 0    -- probably already exists
```

### BF.MADD

```
BF.MADD key item [item ...]
```

Adds multiple items in one call. Returns an array of 0/1 values.

```
BF.MADD seen:urls "https://a.com" "https://b.com" "https://c.com"
-- 1) (integer) 1
-- 2) (integer) 1
-- 3) (integer) 0    -- probably already seen
```

### BF.EXISTS

```
BF.EXISTS key item
```

Checks if an item may exist in the filter. Returns 1 for "probably yes" and 0 for "definitely not."

**Complexity**: O(K) where K is the number of hash functions

```
BF.EXISTS seen:urls "https://example.com/page1"
-- (integer) 1    -- might be there (could be false positive)

BF.EXISTS seen:urls "https://never-visited.com"
-- (integer) 0    -- definitely not in the filter
```

### BF.MEXISTS

```
BF.MEXISTS key item [item ...]
```

Checks multiple items. Returns an array of 0/1 values.

```
BF.MEXISTS seen:urls "https://a.com" "https://never.com"
-- 1) (integer) 1
-- 2) (integer) 0
```

### BF.INFO

```
BF.INFO key
```

Returns information about the Bloom filter.

```
BF.INFO seen:urls
-- 1) "Capacity"       2) (integer) 100000
-- 3) "Size"           4) (integer) 143416
-- 5) "Number of filters"  6) (integer) 1
-- 7) "Number of items inserted"  8) (integer) 2
-- 9) "Expansion rate"  10) (integer) 2
```

**Use when**: monitoring filter utilization. When inserted items approach capacity, the filter may auto-scale (increasing memory) or start returning more false positives.

### Bloom Filter Pattern - Deduplication

```
-- Check before expensive operation
exists = BF.EXISTS dedup:events event_id
if exists == 0
    -- Definitely new, process it
    BF.ADD dedup:events event_id
    process(event)
else
    -- Probably duplicate, skip (occasional false positive is acceptable)
    skip(event)
```

---

## JSON Commands

JSON module stores, retrieves, and manipulates JSON documents as a native Valkey data type. Values are stored in a binary tree format with O(1) access to nested paths. Use when your data is naturally hierarchical and you need to read or update individual fields without fetching the entire document.

JSON paths use JSONPath syntax starting with `$` (root). The legacy dot notation (starting with `.`) is also supported.

### JSON.SET

```
JSON.SET key path value [NX | XX]
```

Sets the JSON value at the given path. Creates the key if it does not exist (when path is `$`). NX only sets if the path does not exist; XX only sets if it does.

```
-- Create a document
JSON.SET user:1000 $ '{"name":"Alice","age":30,"tags":["premium"]}'
-- OK

-- Update a nested field
JSON.SET user:1000 $.age 31
-- OK

-- Add a new field
JSON.SET user:1000 $.email '"alice@example.com"'
-- OK

-- Conditional: only set if field does not exist
JSON.SET user:1000 $.name '"Bob"' NX
-- (nil)    -- name already exists, not set
```

### JSON.GET

```
JSON.GET key [path [path ...]]
```

Returns the JSON value at the given path(s). Without a path, returns the entire document. Multiple paths return a JSON object keyed by path.

```
JSON.GET user:1000
-- '{"name":"Alice","age":31,"tags":["premium"],"email":"alice@example.com"}'

JSON.GET user:1000 $.name
-- '["Alice"]'

JSON.GET user:1000 $.name $.age
-- '{"$.name":["Alice"],"$.age":[31]}'
```

**Note**: JSONPath results are always wrapped in arrays when using `$` syntax, even for single values.

### JSON.DEL

```
JSON.DEL key [path]
```

Deletes the value at the path. If path is omitted or is the root, deletes the entire key. Returns the number of paths deleted.

```
JSON.DEL user:1000 $.email
-- (integer) 1

JSON.DEL user:1000
-- (integer) 1    -- entire key deleted
```

### JSON.MGET

```
JSON.MGET key [key ...] path
```

Returns the value at `path` from multiple keys. Returns nil for keys that do not exist or where the path does not match.

```
JSON.SET user:1000 $ '{"name":"Alice","score":95}'
JSON.SET user:1001 $ '{"name":"Bob","score":87}'

JSON.MGET user:1000 user:1001 user:9999 $.name
-- 1) '["Alice"]'
-- 2) '["Bob"]'
-- 3) (nil)
```

**Use when**: fetching the same field across multiple documents (batch read pattern).

### JSON.TYPE

```
JSON.TYPE key [path]
```

Returns the JSON type at the path: object, array, string, integer, number, boolean, or null.

```
JSON.TYPE user:1000 $.name
-- 1) "string"

JSON.TYPE user:1000 $.tags
-- 1) "array"
```

### JSON.NUMINCRBY

```
JSON.NUMINCRBY key path value
```

Increments the numeric value at the path. Returns the new value. Works with integers and floating-point numbers.

```
JSON.SET user:1000 $ '{"score":95,"balance":100.50}'

JSON.NUMINCRBY user:1000 $.score 5
-- '[100]'

JSON.NUMINCRBY user:1000 $.balance -20.25
-- '[80.25]'
```

**Use when**: updating counters or balances within a JSON document without fetch-modify-store round trips.

### JSON.ARRAPPEND

```
JSON.ARRAPPEND key path value [value ...]
```

Appends values to the JSON array at the path. Returns the new array length.

```
JSON.SET user:1000 $ '{"tags":["premium"]}'

JSON.ARRAPPEND user:1000 $.tags '"vip"' '"early-adopter"'
-- 1) (integer) 3

JSON.GET user:1000 $.tags
-- '[["premium","vip","early-adopter"]]'
```

### JSON Pattern - Document Store

```
-- Store user profile
JSON.SET user:1000 $ '{"name":"Alice","prefs":{"theme":"dark","lang":"en"},"logins":0}'

-- Update nested preference
JSON.SET user:1000 $.prefs.theme '"light"'

-- Increment login counter
JSON.NUMINCRBY user:1000 $.logins 1

-- Read specific fields (avoid fetching entire document)
JSON.GET user:1000 $.name $.prefs.theme
-- '{"$.name":["Alice"],"$.prefs.theme":["light"]}'
```

---

## Search Commands (Overview)

Valkey Search adds secondary indexing and full-text search on top of Hash and JSON data. It is under active development - check valkey-search release notes for current command coverage.

### FT.CREATE

```
FT.CREATE index [ON HASH|JSON] [PREFIX count prefix [...]]
    SCHEMA field_name field_type [field_name field_type ...]
```

Creates a search index. Field types include TEXT (full-text), TAG (exact match), NUMERIC (range queries), and GEO (location queries).

```
-- Index user hashes
FT.CREATE idx:users ON HASH PREFIX 1 user:
    SCHEMA name TEXT SORTABLE email TAG age NUMERIC

-- Index JSON documents
FT.CREATE idx:products ON JSON PREFIX 1 product:
    SCHEMA $.name AS name TEXT $.price AS price NUMERIC $.category AS category TAG
```

### FT.SEARCH

```
FT.SEARCH index query [LIMIT offset num] [RETURN count field [...]] [SORTBY field [ASC|DESC]]
```

Searches the index. Query syntax supports full-text matching, tag filters, numeric ranges, and boolean operators.

```
-- Full-text search
FT.SEARCH idx:users "Alice"

-- Tag filter
FT.SEARCH idx:users "@email:{alice@example.com}"

-- Numeric range
FT.SEARCH idx:users "@age:[25 35]"

-- Combined
FT.SEARCH idx:users "@age:[25 35]" SORTBY age ASC LIMIT 0 10
```

**Note**: Search module availability and feature completeness varies by distribution. Check the valkey-search project for current status and supported commands.

---

## Quick Reference

| Command | Use when... |
|---------|-------------|
| `MODULE LIST` | Checking which modules are loaded |
| `BF.RESERVE key rate cap` | Creating a Bloom filter with specific parameters |
| `BF.ADD key item` | Adding to a Bloom filter |
| `BF.EXISTS key item` | Checking probable membership |
| `BF.INFO key` | Monitoring filter utilization |
| `JSON.SET key $ doc` | Storing a JSON document |
| `JSON.GET key $.field` | Reading specific JSON fields |
| `JSON.NUMINCRBY key $.f N` | Atomic numeric update in JSON |
| `JSON.ARRAPPEND key $.f v` | Appending to a JSON array |
| `JSON.MGET k1 k2 $.field` | Batch reading across documents |
| `FT.CREATE idx ...` | Creating a search index |
| `FT.SEARCH idx query` | Querying an index |

---

## See Also

- [Hash Commands](hashes.md) - hashes are the primary backing type for Search indexes
- [String Commands](strings.md) - JSON module stores documents as a specialized string type
- [Set Commands](sets.md) - exact membership testing alternative to Bloom filters (higher memory, zero error)
- [What is Valkey](../overview/what-is-valkey.md) - Valkey module API compatibility with Redis modules
- [Compatibility and Migration](../overview/compatibility.md) - Redis module compatibility in Valkey
- [Search and Autocomplete Patterns](../patterns/search-autocomplete.md) - full-text search and typeahead patterns
- [Memory Best Practices](../best-practices/memory.md) - Bloom filter sizing, JSON vs hash memory trade-offs
- [Server Commands](server.md) - MODULE LIST to check loaded modules
