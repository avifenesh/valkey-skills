# AOF Rewrite - aof_rewrite Callback and EmitAOF

Use when implementing the aof_rewrite callback for a custom data type, emitting commands with ValkeyModule_EmitAOF, choosing EmitAOF format specifiers, or understanding how module data types survive AOF persistence and rewrite cycles.

Source: `src/module.c` (lines 7813-7865), `src/modules/hellotype.c` (lines 275-282)

## Contents

- [AOF rewrite overview](#aof-rewrite-overview)
- [Callback signature](#callback-signature)
- [EmitAOF function](#emitaof-function)
- [Format specifiers](#format-specifiers)
- [Implementation patterns](#implementation-patterns)
- [ReplicateVerbatim and AOF](#replicateverbatim-and-aof)

---

## AOF Rewrite Overview

The append-only file (AOF) persists commands as they execute. During an AOF rewrite, Valkey replaces the growing AOF with a minimal set of commands that reconstructs the current dataset. For native types (strings, hashes, etc.) the server knows how to emit the right commands. For module data types, the server calls your `aof_rewrite` callback, which must emit the commands needed to recreate the current value from scratch.

The callback is invoked once per key of your type during rewrite. You emit one or more commands using `ValkeyModule_EmitAOF()` that, when replayed, will reconstruct the value.

## Callback Signature

```c
typedef void (*ValkeyModuleTypeRewriteFunc)(
    ValkeyModuleIO *aof,
    ValkeyModuleString *key,
    void *value
);
```

| Parameter | Description |
|---|---|
| `aof` | IO context for emitting commands - pass to `ValkeyModule_EmitAOF()` |
| `key` | The key name being rewritten |
| `value` | The module type value (cast to your struct) |

## EmitAOF Function

```c
void ValkeyModule_EmitAOF(
    ValkeyModuleIO *io,
    const char *cmdname,
    const char *fmt,
    ...
);
```

Emits a command into the AOF during rewrite. The function works like `ValkeyModule_Call()` for parameter formatting but produces no return value - error handling is internal.

**Parameters:**

| Parameter | Description |
|---|---|
| `io` | The IO context from the aof_rewrite callback |
| `cmdname` | Command name string (e.g., `"MYMODULE.SET"`) |
| `fmt` | Format string specifying argument types |
| `...` | Arguments matching the format specifiers |

**Error behavior:** If `cmdname` is not a registered command, the server logs a warning and sets the IO error flag. If the format string is invalid, same behavior. These are fatal during AOF rewrite and indicate a bug in the module.

The command validation check can be bypassed if the module set `VALKEYMODULE_OPTIONS_SKIP_COMMAND_VALIDATION` - useful for modules that emit commands registered by other modules.

## Format Specifiers

The format string uses the same specifiers as `ValkeyModule_Call()`:

| Specifier | Type | Description |
|---|---|---|
| `s` | `ValkeyModuleString*` | Module string argument |
| `c` | `const char*` | C string (null-terminated) |
| `b` | `const char*, size_t` | Binary-safe buffer (two args) |
| `l` | `long long` | Integer argument |
| `v` | `ValkeyModuleString**, size_t` | Vector of module strings (two args) |

## Implementation Patterns

**Pattern 1: One command per element** - most common for collections:

```c
void MyType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    MyList *list = value;
    MyNode *node = list->head;
    while (node) {
        ValkeyModule_EmitAOF(aof, "MYTYPE.ADD", "sl", key, node->value);
        node = node->next;
    }
}
```

This is the pattern used by `hellotype` in the Valkey source:

```c
void HelloTypeAofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    struct HelloTypeObject *hto = value;
    struct HelloTypeNode *node = hto->head;
    while (node) {
        ValkeyModule_EmitAOF(aof, "HELLOTYPE.INSERT", "sl", key, node->value);
        node = node->next;
    }
}
```

**Pattern 2: Single command with serialized blob** - for complex nested structures:

```c
void MyType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    size_t len;
    char *serialized = MyType_Serialize(value, &len);
    ValkeyModule_EmitAOF(aof, "MYTYPE.RESTORE", "sb", key, serialized, len);
    free(serialized);
}
```

**Pattern 3: Multiple command types** - for values with distinct fields:

```c
void MyType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    MyConfig *cfg = value;
    // Emit the create command first
    ValkeyModule_EmitAOF(aof, "MYTYPE.CREATE", "sc", key, cfg->name);
    // Then each setting
    for (int i = 0; i < cfg->num_settings; i++) {
        ValkeyModule_EmitAOF(aof, "MYTYPE.SET", "scl",
            key, cfg->settings[i].name, cfg->settings[i].value);
    }
}
```

**Key requirement:** The commands you emit must be module commands that already handle setting up the data type value. When the AOF is replayed, these commands execute normally and reconstruct your value.

## ReplicateVerbatim and AOF

During normal operation (outside of AOF rewrite), module commands must propagate themselves to the AOF using `ValkeyModule_ReplicateVerbatim()` or `ValkeyModule_Replicate()`. The `aof_rewrite` callback is separate - it handles AOF compaction by emitting the minimal set of commands to reconstruct the current state.

See [../advanced/replication.md](../advanced/replication.md) for the full `ReplicateVerbatim` and `Replicate` API reference and strategy selection guide.
