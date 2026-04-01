# Cross-Module API and Configuration

Use when integrating valkey-json with other modules (especially valkey-search), using the SharedJSON API, calling C API functions from external code, or tuning module configuration parameters.

Source: `src/json/shared_api.h`, `src/json/shared_api.cc`, `src/json/json_api.h`, `src/json/json_api.cc`, `src/json/json.cc` (lines 40-119, 2430-2564)

## Contents

- [SharedJSON API](#sharedjson-api)
- [C API Functions](#c-api-functions)
- [Module Configs](#module-configs)
- [KeyTable Tuning](#keytable-tuning)
- [HashTable Tuning](#hashtable-tuning)
- [Hash Function](#hash-function)

## SharedJSON API

The SharedJSON API allows other Valkey modules (notably valkey-search) to read JSON values without going through the command interface. It uses Valkey's shared API mechanism to export a function pointer.

### Registration

In `shared_api.cc` (line 13), the API is exported during module load:

```c
void SharedAPI_Register(ValkeyModuleCtx *ctx) {
    if (ValkeyModule_ExportSharedAPI(ctx, "JSON_GetValue",
                                     (void *)SharedJSON_Get) != VALKEYMODULE_OK) {
        ValkeyModule_Assert(false);
    }
}
```

The exported name is `"JSON_GetValue"`. Other modules import this symbol with `ValkeyModule_GetSharedAPI("JSON_GetValue")` and cast it to the correct function pointer type.

### SharedJSON_Get

Declared in `shared_api.h` (line 24):

```c
int SharedJSON_Get(ValkeyModuleKey *key, const char *path, ValkeyModuleString **result);
```

Parameters:
- `key` - An already-opened `ValkeyModuleKey` (the caller opens the key)
- `path` - JSONPath expression (v1 or v2 syntax)
- `result` - Output parameter, receives a `ValkeyModuleString` with the serialized JSON

Return values:
- `VALKEYMODULE_OK` - Success, `*result` contains the JSON text
- `VALKEYMODULE_ERR` - Key is not a JSON type, or path does not match

Implementation in `shared_api.cc` (line 19):

```c
int SharedJSON_Get(ValkeyModuleKey *key, const char *path, ValkeyModuleString **result) {
    if (verify_open_doc_key(key) != JSONUTIL_SUCCESS) {
        return VALKEYMODULE_ERR;
    }
    JDocument *doc = static_cast<JDocument *>(ValkeyModule_ModuleTypeGetValue(key));
    rapidjson::StringBuffer output;
    if (dom_get_value_as_str(doc, path, nullptr, output) == JSONUTIL_SUCCESS) {
        *result = ValkeyModule_CreateString(nullptr, output.GetString(), output.GetLength());
        return VALKEYMODULE_OK;
    } else {
        return VALKEYMODULE_ERR;
    }
}
```

The caller is responsible for freeing the returned `ValkeyModuleString`. The function verifies the key holds a JSON document type before accessing it.

## C API Functions

The C API in `json_api.h` / `json_api.cc` provides a lower-level interface for other modules compiled alongside valkey-json, or for internal use. Unlike SharedJSON, these functions take key names as strings and handle key open/close internally.

### is_json_key

```c
int is_json_key(ValkeyModuleCtx *ctx, ValkeyModuleKey *key);
int is_json_key2(ValkeyModuleCtx *ctx, ValkeyModuleString *keystr);
```

Check whether a key holds a JSON document. `is_json_key` takes an already-opened key; `is_json_key2` takes a key name string and opens/closes the key itself. Returns 1 for JSON keys, 0 otherwise.

### get_json_value_type

```c
int get_json_value_type(ValkeyModuleCtx *ctx, const char *keyname, const size_t key_len,
                        const char *path, char **type, size_t *len);
```

Returns the JSON type string at a given path (e.g., "string", "integer", "object"). If multiple values match the path, only the first is returned. The caller must free `*type` with `ValkeyModule_Free`. Returns 0 on success, -1 on error.

### get_json_value

```c
int get_json_value(ValkeyModuleCtx *ctx, const char *keyname, const size_t key_len,
                   const char *path, char **value, size_t *len);
```

Returns the serialized JSON string at a given path. If multiple values match, only the first is returned. The caller must free `*value` with `ValkeyModule_Free`. Returns 0 on success, -1 on error.

### get_json_values_and_types

```c
int get_json_values_and_types(ValkeyModuleCtx *ctx, const char *keyname, const size_t key_len,
                              const char **paths, const int num_paths,
                              char ***values, size_t **lengths,
                              char ***types, size_t **type_lengths);
```

Batch version - retrieves values and optionally types for multiple paths in a single call. This avoids repeated key lookups when the caller needs several fields from the same document.

Memory ownership: The caller must free each string in `*values` and `*types` arrays, plus the arrays themselves, all via `ValkeyModule_Free`. Passing `types = nullptr` skips type retrieval.

Returns 0 on success, -1 if the key is not a JSON document. Individual paths that fail to match will have nullptr entries in the output arrays.

## Module Configs

The module registers two configuration parameters through `registerModuleConfigs` (json.cc line 2555):

### json.max-document-size

```
CONFIG SET json.max-document-size <bytes>
```

| Property | Value |
|----------|-------|
| Default | 0 (unlimited) |
| Range | 0 to LLONG_MAX |
| Flag | VALKEYMODULE_CONFIG_MEMORY |
| Runtime | Yes |

Controls the maximum allowed size for a JSON document. When set to 0 (default), there is no limit. When non-zero, any mutation (JSON.SET, JSON.ARRAPPEND, etc.) that would cause the document to exceed this size is rejected with `JSONUTIL_DOCUMENT_SIZE_LIMIT_EXCEEDED`. The check is applied only on non-replicated commands - replicas accept any size to avoid replication divergence (json.cc line 110).

### json.max-path-limit

```
CONFIG SET json.max-path-limit <depth>
```

| Property | Value |
|----------|-------|
| Default | 128 |
| Range | 0 to INT_MAX |
| Flag | VALKEYMODULE_CONFIG_DEFAULT |
| Runtime | Yes |

Controls the maximum nesting depth for JSON documents. Operations that would create or traverse structures deeper than this limit are rejected. Also used during RDB version 0 load to prevent stack overflow (dom.cc line 1477).

### Other Internal Limits

These are compile-time defaults not exposed via `CONFIG SET`:

| Parameter | Default | Variable | Purpose |
|-----------|---------|----------|---------|
| Max parser recursion depth | 200 | config_max_parser_recursion_depth | RapidJSON parser recursion limit |
| Max recursive descent tokens | 20 | config_max_recursive_descent_tokens | JSONPath recursive descent limit |
| Max query string size | 128KB | config_max_query_string_size | JSONPath expression length limit |
| Defrag threshold | 64MB | config_defrag_threshold | Max doc size for defrag |

## KeyTable Tuning

The KeyTable is the string interning table for JSON object member names. It uses a sharded hash table with configurable parameters. These are set via internal config functions, not `CONFIG SET`.

### Shard Configuration

```c
#define DEFAULT_KEY_TABLE_SHARDS 32768
#define DEFAULT_HASH_TABLE_MIN_SIZE 64
```

The number of shards (default 32768) is configured at startup via `configKeyTable()` (json.cc line 2517) which calls `handleSetNumShards` (json.cc line 2502). It can only be changed when the table is empty (no documents loaded). Each shard has its own mutex, so more shards means less contention under concurrent access.

To change at runtime (only when empty): `CONFIG SET json.key-table-num-shards <value>`.

### Load Factor Tuning

The KeyTable uses linear probing with configurable load factors (json.cc line 2517):

| Factor | Default | Config Param | Description |
|--------|---------|--------------|-------------|
| grow | 1.0 (100%) | key-table-grow-factor | Growth rate when table exceeds maxLoad |
| shrink | 0.5 (50%) | key-table-shrink-factor | Shrink rate when table falls below minLoad |
| minLoad | 0.25 | key-table-min-load-factor | Trigger shrink below this load factor |
| maxLoad | 0.85 | key-table-max-load-factor | Trigger grow above this load factor |

These factors are validated together - `shrink` must not exceed `(1.0 - minLoad)` to ensure rehash-down always succeeds. Config values are expressed as percentages (integer) and divided by 100 internally.

### Performance Advisory

The KeyTable emits a warning log when a shard exceeds 2^19 entries:

> Fast KeyTable Shard size exceeded, increase json.key-table-num-shards to improve performance

Below 2^19 entries per shard, hash metadata fits in pointer bits (19 bits in PtrWithMetaData), making rehash operations cache-friendly. Above that threshold, rehash must fetch the original hash from the KeyTable_Layout struct, causing extra cache misses.

## HashTable Tuning

The HashTable tuning controls the hash tables inside RapidJSON's `GenericValue` for JSON object members. These are separate from the KeyTable - they manage the per-object member lookup within each JValue node.

Configuration in `configHashtable` (json.cc line 2530):

| Factor | Default | Description |
|--------|---------|-------------|
| grow | 1.0 (100%) | Growth rate on exceeding maxLoad |
| shrink | 0.5 (50%) | Shrink rate on falling below minLoad |
| minLoad | 0.25 | Load factor floor |
| maxLoad | 0.85 | Load factor ceiling |
| minHTSize | 64 | Minimum hash table size for object members |

Defined in `rapidjson/document.h` (line 124) as `HashTableFactors`. The global instance is `rapidjson::hashTableFactors`. Stats are tracked in `rapidjson::hashTableStats`:

```c
struct HashTableStats {
    std::atomic<size_t> rehashUp;      // Times table grew
    std::atomic<size_t> rehashDown;    // Times table shrank
    std::atomic<size_t> convertToHT;   // Vector-to-hashtable conversions
    std::atomic<size_t> reserveHT;     // reserve() calls that created a hashtable
};
```

Small objects (fewer members than `minHTSize`) use a vector-based linear scan. Objects that grow beyond this threshold are automatically converted to hash tables for O(1) member lookup.

## Hash Function

The module uses FNV-1a 64-bit with XOR-folding to 38 bits (json.cc line 2571):

```c
size_t hash_function(const char *text, size_t length) {
    const unsigned char *t = reinterpret_cast<const unsigned char *>(text);
    size_t hsh = 14695981039346656037ull;   // FNV offset basis
    for (size_t i = 0; i < length; ++i) {
        hsh = (hsh ^ t[i]) * 1099511628211ull;  // FNV prime
    }
    return hsh ^ (hsh >> 38);  // XOR-fold to 38 bits
}
```

The 38-bit result is split between shard selection (upper bits) and per-shard indexing (lower bits). The XOR-folding improves low-order bit distribution compared to simple truncation.
