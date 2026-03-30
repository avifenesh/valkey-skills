# Server Modules - JSON and Search

Use when you need JSON document storage and manipulation (nested paths, array operations, numeric increments) or full-text search, filtering, and vector similarity search over Valkey data.

GLIDE provides dedicated APIs for Valkey server modules: JSON (for document storage and manipulation) and Search/Vector (for indexing, full-text search, and vector similarity). These are exposed as static utility classes that take a client instance as the first argument and use `customCommand` internally. JSON and Search modules must be loaded on the server - they are not part of the core Valkey distribution.

## JSON Module (GlideJson / Json)

The JSON module stores JSON documents as first-class values in Valkey. Commands operate on paths within JSON documents using either JSONPath syntax (prefix `$`) or legacy dot-notation paths.

### API Surface

| Command | Node.js | Java | Python | Description |
|---------|---------|------|--------|-------------|
| JSON.SET | `GlideJson.set` | `Json.set` | `json.set` | Set a JSON value at a path |
| JSON.GET | `GlideJson.get` | `Json.get` | `json.get` | Get a JSON value at one or more paths |
| JSON.MGET | `GlideJson.mget` | `Json.mget` | `json.mget` | Get a path from multiple keys |
| JSON.DEL | `GlideJson.del` | `Json.del` | `json.delete` | Delete a value at a path |
| JSON.FORGET | `GlideJson.forget` | `Json.forget` | `json.forget` | Alias for JSON.DEL |
| JSON.TYPE | `GlideJson.type` | `Json.type` | `json.type` | Report the type at a path |
| JSON.CLEAR | `GlideJson.clear` | `Json.clear` | `json.clear` | Clear arrays, objects, reset numbers/bools/strings |
| JSON.TOGGLE | `GlideJson.toggle` | `Json.toggle` | `json.toggle` | Toggle a boolean value |
| JSON.NUMINCRBY | `GlideJson.numincrby` | `Json.numincrby` | `json.numincrby` | Increment a number |
| JSON.NUMMULTBY | `GlideJson.nummultby` | `Json.nummultby` | `json.nummultby` | Multiply a number |
| JSON.STRLEN | `GlideJson.strlen` | `Json.strlen` | `json.strlen` | Length of a string value |
| JSON.STRAPPEND | `GlideJson.strappend` | `Json.strappend` | `json.strappend` | Append to a string value |
| JSON.ARRAPPEND | `GlideJson.arrappend` | `Json.arrappend` | `json.arrappend` | Append to an array |
| JSON.ARRINSERT | `GlideJson.arrinsert` | `Json.arrinsert` | `json.arrinsert` | Insert into an array at index |
| JSON.ARRINDEX | `GlideJson.arrindex` | `Json.arrindex` | `json.arrindex` | Find index of element in array |
| JSON.ARRLEN | `GlideJson.arrlen` | `Json.arrlen` | `json.arrlen` | Length of an array |
| JSON.ARRPOP | `GlideJson.arrpop` | `Json.arrpop` | `json.arrpop` | Pop an element from an array |
| JSON.ARRTRIM | `GlideJson.arrtrim` | `Json.arrtrim` | `json.arrtrim` | Trim an array to a range |
| JSON.OBJKEYS | `GlideJson.objkeys` | `Json.objkeys` | `json.objkeys` | Get keys of a JSON object |
| JSON.OBJLEN | `GlideJson.objlen` | `Json.objlen` | `json.objlen` | Get number of keys in a JSON object |
| JSON.RESP | `GlideJson.resp` | `Json.resp` | `json.resp` | Get value in RESP format |
| JSON.DEBUG MEMORY | `GlideJson.debugMemory` | `Json.debugMemory` | `json.debug_memory` | Memory usage of a value |
| JSON.DEBUG FIELDS | `GlideJson.debugFields` | `Json.debugFields` | `json.debug_fields` | Number of fields in a value |

### Path Syntax

Two path formats are supported:

- **JSONPath** (starts with `$`): Returns arrays of results for all matching paths. Example: `$.store.book[*].author`
- **Legacy path** (starts with `.` or bare name): Returns a single value from the first match. Example: `.store.book[0].author`

When multiple paths are provided and they mix JSONPath and legacy syntax, the command treats all as JSONPath.

### JSON Examples

#### Node.js

```typescript
import { GlideJson } from "@valkey/valkey-glide";

// Store a document
await GlideJson.set(client, "user:1", "$", JSON.stringify({
    name: "Alice",
    age: 30,
    tags: ["admin", "user"],
}));

// Read a nested value
const name = await GlideJson.get(client, "user:1", { path: "$.name" });
// '["Alice"]'

// Increment a number
await GlideJson.numincrby(client, "user:1", "$.age", 1);

// Append to an array
await GlideJson.arrappend(client, "user:1", "$.tags", ['"developer"']);

// Conditional set (NX - only if path does not exist)
await GlideJson.set(client, "user:1", "$.email", '"alice@example.com"', {
    conditionalChange: "NX",
});
```

#### Python

```python
from glide import json

# Store a document
await json.set(client, "user:1", "$", '{"name":"Alice","age":30,"tags":["admin"]}')

# Read values
name = await json.get(client, "user:1", "$.name")
# '["Alice"]'

# Array operations
await json.arrappend(client, "user:1", "$.tags", ['"developer"'])
length = await json.arrlen(client, "user:1", "$.tags")
# [2]
```

#### Java

```java
import glide.api.commands.servermodules.Json;

// Store a document
Json.set(client, "user:1", "$", "{\"name\":\"Alice\",\"age\":30}").get();

// Read values
String result = Json.get(client, "user:1", "$.name").get();
// '["Alice"]'
```

## Search and Vector Module (GlideFt / FT)

The Search module provides full-text search, filtering, aggregation, and vector similarity search over Valkey data.

### API Surface

| Command | Node.js | Java | Python | Description |
|---------|---------|------|--------|-------------|
| FT.CREATE | `GlideFt.create` | `FT.create` | `ft.create` | Create an index with schema |
| FT.SEARCH | `GlideFt.search` | `FT.search` | `ft.search` | Search an index |
| FT.AGGREGATE | `GlideFt.aggregate` | `FT.aggregate` | `ft.aggregate` | Aggregate query with pipeline |
| FT.DROPINDEX | `GlideFt.dropindex` | `FT.dropindex` | `ft.dropindex` | Delete an index |
| FT._LIST | `GlideFt.list` | `FT.list` | `ft.list` | List all indexes |
| FT.INFO | `GlideFt.info` | `FT.info` | `ft.info` | Get index metadata |
| FT.EXPLAIN | `GlideFt.explain` | `FT.explain` | `ft.explain` | Parse a query into execution plan |
| FT.EXPLAINCLI | `GlideFt.explaincli` | `FT.explaincli` | `ft.explaincli` | Explain in array format |
| FT.PROFILE | `GlideFt.profileSearch` / `GlideFt.profileAggregate` | `FT.profile` | `ft.profile` | Profile a search or aggregate query |
| FT.ALIASADD | `GlideFt.aliasadd` | `FT.aliasadd` | `ft.aliasadd` | Add an alias for an index |
| FT.ALIASDEL | `GlideFt.aliasdel` | `FT.aliasdel` | `ft.aliasdel` | Delete an alias |
| FT.ALIASUPDATE | `GlideFt.aliasupdate` | `FT.aliasupdate` | `ft.aliasupdate` | Update an alias to point to different index |
| FT._ALIASLIST | `GlideFt.aliaslist` | `FT.aliaslist` | `ft.aliaslist` | List all aliases |

### Schema Field Types

| Field Type | Description | Key Attributes |
|------------|-------------|----------------|
| TEXT | Full-text searchable content | - |
| TAG | Comma-separated tag values | `separator`, `caseSensitive` |
| NUMERIC | Numeric range filtering | - |
| VECTOR | Vector similarity search | `algorithm`, `dimensions`, `distanceMetric`, `type` |

### Vector Field Algorithms

| Algorithm | Description | Specific Attributes |
|-----------|-------------|---------------------|
| FLAT | Brute force linear scan, exact results | - |
| HNSW | Hierarchical Navigable Small World graph, approximate results | `m` (max edges, default 16), `efConstruction` (default 200), `efRuntime` (default 10) |

Vector field attributes shared by both algorithms:
- `dimensions` (required): Number of dimensions in the vector
- `distanceMetric` (required): `L2`, `IP`, or `COSINE`
- `type`: Vector element type, only `FLOAT32` supported
- `initialCap`: Pre-allocated capacity (default 1024)

### FtCreateOptions

| Field | Type | Description |
|-------|------|-------------|
| `dataType` | `"JSON"` or `"HASH"` | Type of data to index |
| `prefixes` | string[] | Key prefixes to index |

### FtSearchOptions

| Field | Type | Description |
|-------|------|-------------|
| `returnFields` | array | Fields to return with optional aliases |
| `timeout` | number | Query timeout in milliseconds |
| `params` | key-value pairs | Query parameters referenced with `$` |
| `limit` | `{offset, count}` | Pagination (default: first 10 documents) |
| `count` | boolean | Return only the count, not documents |

### FtAggregateOptions

| Field | Type | Description |
|-------|------|-------------|
| `loadFields` or `loadAll` | string[] or boolean | Fields to load from the index |
| `timeout` | number | Query timeout in milliseconds |
| `params` | key-value pairs | Query parameters |
| `clauses` | array | Pipeline of LIMIT, FILTER, GROUPBY, SORTBY, APPLY |

Aggregate clauses are applied in order, with each clause's output feeding the next.

### Search Examples

#### Node.js - Vector Search

```typescript
import { GlideFt } from "@valkey/valkey-glide";

// Create a vector index on JSON documents
await GlideFt.create(client, "vec_idx", [{
    type: "VECTOR",
    name: "$.embedding",
    alias: "VEC",
    attributes: {
        algorithm: "HNSW",
        type: "FLOAT32",
        dimensions: 128,
        distanceMetric: "COSINE",
        numberOfEdges: 32,
    },
}, {
    type: "TEXT",
    name: "$.title",
    alias: "title",
}], {
    dataType: "JSON",
    prefixes: ["doc:"],
});

// KNN search with query vector
const queryVec = Buffer.alloc(128 * 4); // 128-dim FLOAT32
const results = await GlideFt.search(
    client,
    "vec_idx",
    "*=>[KNN 5 @VEC $query_vec]",
    { params: [{ key: "query_vec", value: queryVec }] },
);
// results[0] = total count, results[1] = document records
```

#### Node.js - Aggregate with GROUPBY

```typescript
const results = await GlideFt.aggregate(client, "idx", "*", {
    loadFields: ["__key"],
    clauses: [
        {
            type: "GROUPBY",
            properties: ["@category"],
            reducers: [{
                function: "COUNT",
                args: [],
                name: "count",
            }],
        },
        {
            type: "SORTBY",
            properties: [{ property: "@count", order: "DESC" }],
        },
        { type: "LIMIT", offset: 0, count: 10 },
    ],
});
```

#### Python - Create and Search

```python
from glide import ft
from glide_shared.commands.server_modules.ft_options.ft_create_options import (
    FtCreateOptions, TextField, TagField, VectorFieldHnsw, DataType
)

# Create an index
schema = [
    TextField("title"),
    TagField("category"),
]
options = FtCreateOptions(DataType.HASH, prefixes=["article:"])
await ft.create(client, "article_idx", schema, options)

# Search
results = await ft.search(client, "article_idx", "@category:{tech}")
```

#### Java - Create and Search

```java
import glide.api.commands.servermodules.FT;

// Create an index
FT.create(client, "idx",
    new Field[] { Field.text("title"), Field.tag("status") },
    FtCreateOptions.builder()
        .dataType(FtCreateOptions.DataType.HASH)
        .prefixes(new String[]{"item:"})
        .build()
).get();

// Search
Object[] results = FT.search(client, "idx", "@status:{active}").get();
```

### FT.PROFILE

Profile returns performance information alongside search or aggregate results. Useful for query optimization.

```typescript
// Profile a search query
const [searchResult, profileData] = await GlideFt.profileSearch(
    client, "idx", "@title:valkey",
    { limited: true }
);
// profileData contains timing and processing metrics

// Profile an aggregate query
const [aggResult, aggProfile] = await GlideFt.profileAggregate(
    client, "idx", "*",
    { clauses: [{ type: "GROUPBY", properties: ["@type"], reducers: [] }] }
);
```

## Vector Search - Java KNN Example

```java
import glide.api.commands.servermodules.FT;

// Create HNSW vector index
FieldInfo[] fields = new FieldInfo[] {
    new FieldInfo("vec", "VEC", VectorFieldHnsw.builder(DistanceMetric.L2, 2).build())
};
FT.create(client, index, fields, FTCreateOptions.builder()
    .dataType(DataType.HASH).prefixes(new String[]{prefix}).build());

// Search with KNN
String query = "*=>[KNN 2 @VEC $query_vec]";
Object[] results = FT.search(client, index, query, searchOptions).get();
```

## Using Unsupported Modules

For modules without dedicated GLIDE interfaces (anything other than JSON and Search), use `custom_command`:

```python
# Python - call any module command
result = await client.custom_command(["MODULE_COMMAND", "arg1", "arg2"])
```

Use `INFO MODULES` or `MODULE LIST` to verify which modules are loaded on the server.

## Language Support Status

| Module | Java | Node.js | Python | Go | C# |
|--------|------|---------|--------|----|----|
| JSON | Done | Done | Done | Not yet | Not yet |
| Search/Vector | Done | Done | Done | Not yet | Not yet |

## Module Availability

JSON and Search modules must be loaded on the Valkey server. These are not part of the core Valkey distribution - they require the Valkey module system. Check availability with `MODULE LIST` or use `FT._LIST` / `JSON.SET` and handle errors if modules are not loaded.

All module commands are sent via `customCommand` internally, so they work with both standalone and cluster clients without special routing logic.

## Related Features

- [Geospatial](geospatial.md) - for simple location queries, native GEOSEARCH may suffice without the Search module
- [Batching](batching.md) - module commands can be included in batches via `custom_command` within the batch
