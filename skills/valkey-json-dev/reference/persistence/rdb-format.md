# RDB Format

Use when working on RDB save/load, understanding encoding versions, adding new data to persisted format, debugging RDB compatibility issues, or implementing AOF rewrite.

Source: `src/json/dom.cc` (lines 1334-1556), `src/json/json.cc` (lines 2296-2385)

## Contents

- [Encoding Versions](#encoding-versions)
- [Encoding Version 3 - Current](#encoding-version-3---current)
- [Encoding Version 0 - Legacy Binary](#encoding-version-0---legacy-binary)
- [Metacodes](#metacodes)
- [RDB Save Flow](#rdb-save-flow)
- [RDB Load Flow](#rdb-load-flow)
- [AOF Rewrite](#aof-rewrite)
- [Data Type Registration](#data-type-registration)
- [Nesting Limits During Load](#nesting-limits-during-load)
- [Error Handling](#error-handling)

## Encoding Versions

The module defines the current encoding version as a compile-time constant in `json.cc` (line 49):

```c
#define DOCUMENT_TYPE_ENCODING_VERSION 3
```

Two encoding versions are supported:

| Version | Format | When Used |
|---------|--------|-----------|
| 3 | JSON string (wire format) | Current - all new saves |
| 0 | Binary with metacodes | Legacy - read-only for backward compat |

The `dom_load` function (dom.cc line 1522) accepts both versions. The `dom_save` function (dom.cc line 1398) always writes the current version (3). When loading an RDB produced by an older module, version 0 data is transparently upgraded to the in-memory DOM representation.

## Encoding Version 3 - Current

Version 3 serializes the entire document as a JSON string using `serialize_value`:

```c
// dom.cc line 1398
void dom_save(const JDocument *doc, ValkeyModuleIO *rdb, int encver) {
    switch (encver) {
        case 3: {
            rapidjson::StringBuffer oss;
            serialize_value(*(doc), 0, nullptr, oss);
            ValkeyModule_SaveStringBuffer(rdb, oss.GetString(), oss.GetLength());
            break;
        }
```

On load (dom.cc line 1526), the JSON string is read back and parsed via `dom_parse`:

```c
case 3: {
    size_t json_len;
    char *json = ValkeyModule_LoadStringBuffer(ctx, &json_len);
    if (!json) return JSONUTIL_INVALID_RDB_FORMAT;
    JsonUtilCode rc = dom_parse(nullptr, json, json_len, doc);
    ValkeyModule_Free(json);
    return rc;
}
```

This is simple and human-readable if you dump the RDB, but requires a full parse on load.

## Encoding Version 0 - Legacy Binary

Version 0 stores each JValue node-by-node using a binary format with type metacodes. This was the original format and is now only loaded, never written. Each node starts with an unsigned metacode byte identifying its type, followed by type-specific data.

Loading version 0 uses `rdbLoadJValue` (dom.cc line 1448) - a recursive function that reads the metacode, then dispatches to type-specific deserialization.

## Metacodes

Defined in dom.cc (lines 1339-1348):

```c
enum meta_codes {
    JSON_METACODE_NULL    = 0x01,  // Nothing follows
    JSON_METACODE_STRING  = 0x02,  // Followed by the string
    JSON_METACODE_DOUBLE  = 0x04,  // Followed by the double
    JSON_METACODE_INTEGER = 0x08,  // Coded as a 64-bit Signed Integer
    JSON_METACODE_BOOLEAN = 0x10,  // Coded as the string '1' or '0'
    JSON_METACODE_OBJECT  = 0x20,  // Followed by member count, then N pairs
    JSON_METACODE_ARRAY   = 0x40,  // Followed by element count, then N JValues
    JSON_METACODE_PAIR    = 0x80   // Codes a string (member name) and a JValue
};
```

Binary layout per type:

| Metacode | Hex | Payload |
|----------|-----|---------|
| NULL | 0x01 | None |
| STRING | 0x02 | `ValkeyModule_SaveStringBuffer` |
| DOUBLE | 0x04 | `ValkeyModule_SaveDouble` (legacy doubles, converted to string-doubles on load) |
| INTEGER | 0x08 | `ValkeyModule_SaveSigned` (int64) or `ValkeyModule_SaveUnsigned` (uint64 < 2^63) |
| BOOLEAN | 0x10 | String "1" or "0" |
| OBJECT | 0x20 | Member count (unsigned), then N x (PAIR metacode + key string + value JValue) |
| ARRAY | 0x40 | Element count (unsigned), then N x JValue |
| PAIR | 0x80 | Key string + recursive JValue |

Objects and arrays recurse into their children. The PAIR metacode is only valid inside an OBJECT and always appears after the member count.

## RDB Save Flow

`DocumentType_RdbSave` (json.cc line 2331) is the registered callback:

```
DocumentType_RdbSave(rdb, value)
  -> dom_save(doc, rdb, DOCUMENT_TYPE_ENCODING_VERSION)
       -> case 3: serialize_value() -> ValkeyModule_SaveStringBuffer()
  -> check ValkeyModule_IsIOError(rdb) for logging
```

The save path in version 3 is a single serialization pass that produces JSON text, then writes it as one string buffer. This is simple but means the entire serialized JSON must fit in memory alongside the DOM.

For version 0 (only in `dom_save` for completeness), `store_JValue` (dom.cc line 1353) recurses through the document tree, writing each node's metacode followed by its payload. The unsigned int handling has a safety check - uint64 values >= 2^63 will assert because the RDB format does not support unsigned integers.

## RDB Load Flow

`DocumentType_RdbLoad` (json.cc line 2301) is the registered callback:

```
DocumentType_RdbLoad(rdb, encver)
  -> reject if encver > DOCUMENT_TYPE_ENCODING_VERSION
  -> jsonstats_begin_track_mem()
  -> dom_load(&doc, rdb, encver)
       -> case 3: ValkeyModule_LoadStringBuffer() -> dom_parse()
       -> case 0: rdbLoadJValue() (recursive)
  -> jsonstats_end_track_mem()
  -> dom_set_doc_size(doc, delta)
  -> jsonstats_update_stats_on_insert()
```

Memory tracking wraps the entire load so the document size is computed from the actual allocation delta, not estimated.

## AOF Rewrite

`DocumentType_AofRewrite` (json.cc line 2380) serializes the document and emits it as a `JSON.SET` command:

```c
void DocumentType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    JDocument *doc = static_cast<JDocument*>(value);
    rapidjson::StringBuffer oss;
    dom_serialize(doc, nullptr, oss);
    ValkeyModule_EmitAOF(aof, "JSON.SET", "scc", key, ".", oss.GetString());
}
```

The AOF format is always `JSON.SET <key> . <full-json>` - a complete replacement at the root path. This means AOF replay creates the document from scratch regardless of the original mutation history.

## Data Type Registration

The module registers the data type with Valkey using the name `ReJSON-RL` (json.cc line 48) for backward compatibility with RedisJSON:

```c
#define DOCUMENT_TYPE_NAME "ReJSON-RL"
```

Registration in `ValkeyModule_OnLoad` (json.cc line 2664):

```c
DocumentType = ValkeyModule_CreateDataType(ctx, DOCUMENT_TYPE_NAME,
                                          DOCUMENT_TYPE_ENCODING_VERSION, &type_methods);
```

The type methods struct registers all eight callbacks:

| Callback | Function | Purpose |
|----------|----------|---------|
| rdb_load | DocumentType_RdbLoad | Deserialize from RDB |
| rdb_save | DocumentType_RdbSave | Serialize to RDB |
| copy | DocumentType_Copy | COPY command support |
| aof_rewrite | DocumentType_AofRewrite | AOF rewrite |
| mem_usage | DocumentType_MemUsage | MEMORY USAGE reporting |
| free | DocumentType_Free | Key deletion cleanup |
| digest | DocumentType_Digest | DEBUG DIGEST |
| defrag | DocumentType_Defrag | Active defrag |

## Nesting Limits During Load

During version 0 load, `rdbLoadJValue` tracks nesting depth via `load_params.nestLevel`. Before recursing into an object or array, it checks against `json_get_max_path_limit()` (default 128):

```c
if (params->nestLevel >= json_get_max_path_limit()) {
    params->status = JSONUTIL_DOCUMENT_PATH_LIMIT_EXCEEDED;
    ValkeyModule_LogIOError(params->rdb, "error", "document path limit exceeded");
    return JValue();
}
```

This prevents stack overflow from maliciously deep documents in legacy RDB files. Version 3 relies on `dom_parse` which has its own recursion depth limit (`config_max_parser_recursion_depth`, default 200).

## Error Handling

Both load paths set error codes on failure:

- `JSONUTIL_INVALID_RDB_FORMAT` - unrecognized metacode, bad boolean, or null string buffer
- `JSONUTIL_DOCUMENT_PATH_LIMIT_EXCEEDED` - nesting too deep
- Parse errors from `dom_parse` (version 3)

The load callback checks for errors and returns nullptr on failure, which tells Valkey to skip the key. The save callback checks `ValkeyModule_IsIOError` after writing and logs a warning.

The module also sets `VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS | VALKEYMODULE_OPTIONS_HANDLE_REPL_ASYNC_LOAD` at load time (json.cc line 2674), telling Valkey the module handles I/O errors gracefully and supports async replication loading rather than aborting.
