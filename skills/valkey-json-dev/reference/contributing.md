# Contributing to valkey-json

Use when adding new commands, extending the JSONPath engine, modifying RDB serialization, or understanding code conventions for the valkey-json module.

## Contents

- Code Structure (line 15)
- Adding a New Command (line 40)
- Extending the JSONPath Engine (line 108)
- Modifying RDB Serialization (line 135)
- Coding Conventions (line 148)
- Module Configuration (line 182)
- PR Checklist (line 202)

## Code Structure

```
src/
  json/
    json.cc          - Module entry point and command handlers (~3000 lines)
    json.h           - Config getters, instrumentation flags, key verification
    dom.cc/.h        - Document model (parse, serialize, CRUD, RDB)
    selector.cc/.h   - JSONPath parser and evaluator
    keytable.cc/.h   - String interning hash table
    alloc.cc/.h      - DOM memory allocator
    stats.cc/.h      - Memory tracking, histograms, logical stats
    memory.cc/.h     - Low-level allocator, traps, jsn:: STL types
    util.cc/.h       - Error codes, number formatting, helpers
    json_api.cc/.h   - C API for cross-module access (get_json_value, get_json_value_type)
    shared_api.cc/.h - SharedJSON_Get via ValkeyModule_ExportSharedAPI
    rapidjson_includes.h - RapidJSON config and includes
  rapidjson/         - Vendored RapidJSON headers (modified: object hash table, KeyTable)
  commands/          - 23 command spec JSON files (json.set.json, json.get.json, etc.)
  include/           - Auto-copied valkeymodule.h (generated at build)
tst/
  unit/              - GoogleTest C++ tests
  integration/       - pytest integration tests against live server
```

## Adding a New Command

### 1. Write the Command Handler

In `json.cc`, add a handler following the naming convention `Command_JsonXxx`:

```cpp
int Command_JsonXxx(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModule_AutoMemory(ctx);
    // Parse arguments
    // Open key, verify it's a JSON document
    // Delegate work to dom_* functions
    // For write commands: call ValkeyModule_ReplicateVerbatim(ctx)
    // Reply to client
    return VALKEYMODULE_OK;
}
```

### 2. Register the Command

In `ValkeyModule_OnLoad()`, add registration:

```cpp
if (ValkeyModule_CreateCommand(ctx, "JSON.XXX", Command_JsonXxx,
                              cmdflg_..., 1, 1, 1) == VALKEYMODULE_ERR) {
    ValkeyModule_Log(ctx, "warning", "Failed to create command JSON.XXX.");
    return VALKEYMODULE_ERR;
}
if (ValkeyModule_SetCommandACLCategories(
        ValkeyModule_GetCommand(ctx, "JSON.XXX"), cat_...) == VALKEYMODULE_ERR) {
    return VALKEYMODULE_ERR;
}
```

Command flag groups defined in `ValkeyModule_OnLoad`:
- `cmdflg_readonly` ("fast readonly") - read commands
- `cmdflg_slow_write_deny` ("write deny-oom") - write commands that may grow memory
- `cmdflg_fast_write` ("fast write") - write commands that don't grow memory
- `cmdflg_fast_write_deny` ("fast write deny-oom") - fast write that may grow

### 3. Set Command Info (key-spec)

After registration, call `set_command_info()` with arity and key-spec flags:

```cpp
if (!set_command_info(ctx, "JSON.XXX", arity, ks_flags, bs_index, key_range)) {
    return VALKEYMODULE_ERR;
}
```

### 4. Add Command Spec JSON

Create `src/commands/json.xxx.json` with the command's documentation metadata. Follow the format of existing files like `json.set.json`.

### 5. Write Tests

- Unit test in `tst/unit/` testing the DOM-level function
- Integration test cases in `tst/integration/test_json_basic.py`

### 6. Write Command Must-Haves

For every write command:
- Use `deny-oom` flag if the command can increase total memory
- Call `ValkeyModule_ReplicateVerbatim(ctx)` for replication
- Track memory: `jsonstats_begin_track_mem()` before mutation, `jsonstats_end_track_mem()` after
- Check document size limit with `CHECK_DOCUMENT_SIZE_LIMIT` macro
- Update document size: `dom_set_doc_size(doc, orig_size + delta)`

## Extending the JSONPath Engine

### Adding a New Path Feature

1. Update the EBNF grammar comment at the top of `selector.cc`
2. Add token types to `Token::TokenType` enum in `selector.h` if needed
3. Implement a parse method in the `Selector` class (e.g., `parseNewFeature()`)
4. Wire it into the appropriate parse chain (e.g., from `parseBracketPathElement`)
5. Add processing logic that populates `resultSet` or `insertPaths`
6. Add tests in `tst/unit/selector_test.cc`

### Key Selector Internals

- `Lexer` - tokenizer that walks the path string character by character
- `Selector::getValues()` / `setValues()` / `deleteValues()` - entry points for READ/WRITE/DELETE
- `Selector::resultSet` - `vector<pair<JValue*, string>>` of matched values with their paths
- `Selector::insertPaths` - set of JSON Pointer paths for inserts (write mode only)
- Path tracking uses JSON Pointer format internally (e.g., `/store/book/0/price`)

### State Management for Recursive Search

The `..` operator uses `snapshotState()`/`restoreState()` to save and restore the current position in both the JSON tree and the path string during recursive descent. The `recursiveSearch()` method walks all children of the current node.

### Filter Expressions

Filter processing (`parseFilterExpr`, `parseTerm`, `parseFactor`) produces a vector of matching array indexes. Logical operators (`&&`, `||`) combine results via set intersection/union.

## Modifying RDB Serialization

### Current Format (encver 3)

The document is serialized as a single JSON string. This is simpler and more compact than the node-by-node format. To modify:

1. Bump `DOCUMENT_TYPE_ENCODING_VERSION` in `json.cc`
2. Add a new case in `dom_save()` and `dom_load()` in `dom.cc`
3. Keep backward compatibility - old encver cases must still load
4. Add `test_rdb.py` tests for round-trip verification

### Important: `dom_load` must handle all historical encoding versions. Never remove old cases.

## Coding Conventions

### Naming

- Command handlers: `Command_JsonXxx`
- Callback methods: `DocumentType_Xxx`
- DOM functions: `dom_xxx`
- Util functions: `jsonutil_xxx`
- Stats functions: `jsonstats_xxx`

### Error Handling

- Functions that can fail return `JsonUtilCode` enum
- Output parameters are placed last and initialized at the start of the method
- Error codes are defined in `util.h` (`JSONUTIL_SUCCESS`, `JSONUTIL_JSON_PARSE_ERROR`, etc.)

### Memory Management

- All heap allocations must use `dom_alloc`/`dom_free` (for DOM objects) or `memory_alloc`/`memory_free` (for non-DOM objects)
- Never use raw `malloc`/`free` - memory would not be reported to Valkey
- If a function returns a heap-allocated object, document it so the caller knows to free
- Use `jsn::` types (`jsn::vector`, `jsn::string`) for STL containers

### Avoiding Valkey Types in DOM Layer

DOM and util functions should avoid `ValkeyModuleCtx`, `ValkeyModuleString`, etc. to keep them unit-testable. The `module_sim.cc` mock has limited coverage. Pass C primitives (`const char*`, `size_t`) instead.

### Build Flags

- `-Wall -Werror -Wextra` - all warnings are errors
- `-fPIC` - required for shared library
- `-Wno-mismatched-tags -Wno-format` - suppressed for RapidJSON compatibility
- C11 for C files, C++17 for C++ files

## Module Configuration

Two configs are registered in `registerModuleConfigs()` and accessible via `CONFIG SET json.*`:

| Config | Default | Flag | Purpose |
|--------|---------|------|---------|
| max-document-size | 0 | VALKEYMODULE_CONFIG_MEMORY | Max bytes per document (0 = unlimited) |
| max-path-limit | 128 | VALKEYMODULE_CONFIG_DEFAULT | Max JSONPath nesting depth |

Internal defaults (not exposed via CONFIG SET - compile-time only):

| Static Variable | Default | Purpose |
|----------------|---------|---------|
| config_max_parser_recursion_depth | 200 | Selector recursion limit |
| config_max_recursive_descent_tokens | 20 | Token limit for `..` queries |
| config_max_query_string_size | 128KB | Max path string length |
| config_defrag_threshold | 64MB | Max doc size for defrag |

KeyTable tuning (grow/shrink factors, shard count) is configured internally at startup via `configKeyTable()`.

## PR Checklist

- [ ] Unit tests pass: `./build.sh --unit`
- [ ] Integration tests pass: `./build.sh --integration`
- [ ] ASAN clean: `ASAN_BUILD=true ./build.sh --integration`
- [ ] No new compiler warnings (`-Wall -Werror`)
- [ ] Write commands replicate and track memory
- [ ] Command spec JSON added for new commands
- [ ] Backward-compatible RDB changes (if touching serialization)
