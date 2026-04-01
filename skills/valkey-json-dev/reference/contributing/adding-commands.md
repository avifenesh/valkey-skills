# Adding Commands

Use when implementing a new JSON.* command, understanding command handler patterns, working with command metadata, or extending the command registration in valkey-json.

Source: `src/json/json.cc` (lines 650-3086), `src/commands/*.json` in valkey-io/valkey-json

## Contents

- [Command Handler Pattern](#command-handler-pattern)
- [V1 vs V2 Path Reply Differences](#v1-vs-v2-path-reply-differences)
- [Command Registration](#command-registration)
- [JSON Command Metadata](#json-command-metadata)
- [Subcommands](#subcommands)
- [Step-by-Step: Adding a New Command](#step-by-step-adding-a-new-command)

## Command Handler Pattern

Every JSON command follows the same structure. Here is `Command_JsonToggle` (json.cc:1260-1301) as a concise example:

```cpp
int Command_JsonToggle(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    // 1. Enable automatic memory management
    ValkeyModule_AutoMemory(ctx);

    // 2. Parse arguments
    ValkeyModuleString *key_str;
    const char *path;
    JsonUtilCode rc = parseSimpleCmdArgs(argv, argc, &key_str, &path);
    if (rc != JSONUTIL_SUCCESS) {
        if (rc == JSONUTIL_WRONG_NUM_ARGS)
            return ValkeyModule_WrongArity(ctx);
        else
            return ValkeyModule_ReplyWithError(ctx, jsonutil_code_to_message(rc));
    }

    // 3. Open and verify the key
    ValkeyModuleKey *key;
    rc = verify_doc_key(ctx, key_str, &key);
    if (rc != JSONUTIL_SUCCESS)
        return ValkeyModule_ReplyWithError(ctx, jsonutil_code_to_message(rc));

    // 4. Get the document from the key
    JDocument *doc = static_cast<JDocument*>(
        ValkeyModule_ModuleTypeGetValue(key));
    size_t orig_doc_size = dom_get_doc_size(doc);

    // 5. Track memory for stats
    int64_t begin_val = jsonstats_begin_track_mem();

    // 6. Perform the DOM operation
    jsn::vector<int> vec;
    bool is_v2_path;
    rc = dom_toggle(doc, path, vec, is_v2_path);
    if (rc != JSONUTIL_SUCCESS)
        return ValkeyModule_ReplyWithError(ctx, jsonutil_code_to_message(rc));

    // 7. End memory tracking
    END_TRACKING_MEMORY(ctx, "JSON.TOGGLE", doc, orig_doc_size, begin_val)

    // 8. Replicate to replicas
    ValkeyModule_ReplicateVerbatim(ctx);

    // 9. Keyspace notification
    ValkeyModule_NotifyKeyspaceEvent(ctx, VALKEYMODULE_NOTIFY_GENERIC,
        "json.toggle", key_str);

    // 10. Send reply
    reply_toggle(vec, is_v2_path, ctx);
    return VALKEYMODULE_OK;
}
```

### Handler Steps

| Step | Purpose | Required |
|------|---------|----------|
| `ValkeyModule_AutoMemory(ctx)` | Auto-free module allocations on return | Always |
| Parse args | Extract key, path, values from argv/argc | Always |
| `verify_doc_key()` | Open key, check type is DocumentType | Read/write commands |
| `ValkeyModule_ModuleTypeGetValue()` | Get JDocument pointer from key | When doc exists |
| `jsonstats_begin_track_mem()` | Start memory delta tracking | Write commands |
| DOM operation | Call `dom_*` function (dom_set_value, dom_toggle, etc.) | Always |
| `END_TRACKING_MEMORY()` | Record memory change in stats | Write commands |
| `ValkeyModule_ReplicateVerbatim()` | Forward command to replicas | Write commands |
| `ValkeyModule_NotifyKeyspaceEvent()` | Emit keyspace notification | Write commands |
| Reply | Send response to client | Always |

### Read-only vs Write Commands

Read-only commands (JSON.GET, JSON.OBJLEN, JSON.TYPE, etc.) skip memory tracking, replication, and keyspace notification. They use `verify_doc_key(ctx, key_str, &key, true)` - the `true` flag indicates read-only access.

Write commands (JSON.SET, JSON.DEL, JSON.TOGGLE, etc.) must include all steps.

## V1 vs V2 Path Reply Differences

The DOM operations return `is_v2_path` to indicate which path syntax was used. This affects reply format:

- **V1 paths** (legacy, no `$` prefix) - return a single value directly
- **V2 paths** (`$` prefix, JSONPath) - return an array of matched values

Example from `reply_strlen_objlen` (json.cc:1095):

```cpp
if (!is_v2_path) {
    // V1: single integer reply
    ValkeyModule_ReplyWithLongLong(ctx, vec[0]);
} else {
    // V2: array of integers
    ValkeyModule_ReplyWithArray(ctx, vec.size());
    for (auto &v : vec)
        ValkeyModule_ReplyWithLongLong(ctx, v);
}
```

Every command that returns path-dependent results must handle this distinction.

## Command Registration

Commands are registered in `ValkeyModule_OnLoad` (json.cc:2642). Registration involves three steps per command.

### Step 1: Create the Command

```cpp
ValkeyModule_CreateCommand(ctx, "JSON.TOGGLE", Command_JsonToggle,
    cmdflg_fast_write_deny, 1, 1, 1)
```

Arguments: context, command name, handler function, flags string, first key, last key, step.

### Command Flag Groups

| Variable | Flags | Used By |
|----------|-------|---------|
| `cmdflg_readonly` | `"fast readonly"` | GET, MGET, STRLEN, OBJLEN, OBJKEYS, ARRLEN, ARRINDEX, TYPE, RESP |
| `cmdflg_slow_write_deny` | `"write deny-oom"` | SET, MSET |
| `cmdflg_fast_write` | `"fast write"` | DEL, FORGET, ARRPOP, ARRTRIM, CLEAR, NUMINCRBY, NUMMULTBY |
| `cmdflg_fast_write_deny` | `"fast write deny-oom"` | STRAPPEND, TOGGLE, ARRAPPEND, ARRINSERT |
| `cmdflg_debug` | `"readonly getkeys-api"` | DEBUG (parent) |

### Step 2: Set ACL Category

```cpp
ValkeyModule_SetCommandACLCategories(
    ValkeyModule_GetCommand(ctx, "JSON.TOGGLE"), cat_fast_write_deny)
```

The custom `"json"` ACL category is registered first via `ValkeyModule_AddACLCategory(ctx, "json")`. All commands get the `json` category plus appropriate read/write/fast/slow tags.

### Step 3: Set Command Info (Key Specs)

```cpp
set_command_info(ctx, "JSON.TOGGLE", -2,
    ks_read_write_access_update, 1, std::make_tuple(0, 1, 0))
```

Arguments: context, name, arity, key-spec flags, begin-search index, key range tuple (last_key, step, limit).

Key-spec flag groups:

| Variable | Flags |
|----------|-------|
| `ks_read_write_update` | `RW \| UPDATE` |
| `ks_read_write_insert` | `RW \| INSERT` |
| `ks_read_write_delete` | `RW \| DELETE` |
| `ks_read_write_access_update` | `RW \| UPDATE \| ACCESS` |
| `ks_read_write_access_delete` | `RW \| DELETE \| ACCESS` |
| `ks_read_only` | `RO` |
| `ks_read_only_access` | `RO \| ACCESS` |

## JSON Command Metadata

Each command has a metadata file in `src/commands/json.<name>.json`:

```json
{
    "JSON.TOGGLE": {
        "summary": "Toggle boolean values between true and false at the specified path.",
        "complexity": "O(N) where N is the number of json boolean values matched by the path.",
        "group": "json",
        "module_since": "1.0.0",
        "arity": 2,
        "acl_categories": ["WRITE", "FAST", "JSON"],
        "arguments": [
            { "name": "key", "type": "key", "key_spec_index": 0 },
            { "name": "path", "type": "string", "optional": true }
        ]
    }
}
```

Fields: `summary`, `complexity`, `group` (always `"json"`), `module_since`, `arity`, `acl_categories`, `arguments`. Optional arguments include `"optional": true`.

## Subcommands

JSON.DEBUG uses subcommands registered via `ValkeyModule_CreateSubcommand`:

```cpp
ValkeyModuleCommand *parent = ValkeyModule_GetCommand(ctx, "JSON.DEBUG");
ValkeyModule_CreateSubcommand(parent, "MEMORY", Command_JsonDebug, "", 2, 2, 1);
```

Subcommand info uses pipe-delimited names: `"JSON.DEBUG|MEMORY"`.

## Step-by-Step: Adding a New Command

1. **Implement the DOM operation** in the appropriate `src/json/` file. The function should accept a `JDocument*`, path string, and output parameters. Return `JsonUtilCode`.

2. **Write the command handler** in `src/json/json.cc` following the pattern above. Choose read-only or write based on whether the command modifies data.

3. **Handle v1/v2 path replies** if the command returns path-dependent results. Write a `reply_*` helper if the reply logic is non-trivial.

4. **Register the command** in `ValkeyModule_OnLoad`:
   - `ValkeyModule_CreateCommand()` with appropriate flags
   - `ValkeyModule_SetCommandACLCategories()` with the `json` category
   - `set_command_info()` with arity and key-spec flags

5. **Create the metadata file** at `src/commands/json.<name>.json` with the standard fields.

6. **Write unit tests** in `tst/unit/` testing the DOM operation directly.

7. **Write integration tests** in `tst/integration/test_json_basic.py` testing the command end-to-end, including error cases and v1/v2 path variants.

8. **Verify CI** - the command must pass all 16 CI matrix jobs (4 job types x 4 server versions).

## See Also

- [build.md](build.md) - Building the module after adding commands
- [testing.md](testing.md) - Unit and integration test patterns
- [ci-pipeline.md](ci-pipeline.md) - CI validation requirements
- [jdocument.md](../document/jdocument.md) - JDocument/JValue types used in DOM operations
- [path-operations.md](../jsonpath/path-operations.md) - How JSONPath maps to DOM mutations in command handlers
- [cross-module.md](../persistence/cross-module.md) - Module config registration for new configurable parameters
