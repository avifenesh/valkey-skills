# Data Type Registration - CreateDataType, ValkeyModuleTypeMethods, Name Encoding

Use when registering a custom module data type, choosing a 9-character type name, setting up the ValkeyModuleTypeMethods callback struct, or storing and retrieving module type values from keys.

Source: `src/module.c` (lines 6890-7317), `src/valkeymodule.h` (lines 60-62, 1413-1433)

## Contents

- [Name encoding scheme](#name-encoding-scheme)
- [CreateDataType](#createdatatype)
- [ValkeyModuleTypeMethods struct](#valkeymoduletypemethods-struct)
- [Callback version history](#callback-version-history)
- [Key value accessors](#key-value-accessors)
- [GetTypeMethodVersion](#gettypemethodversion)

---

## Name Encoding Scheme

Each module data type requires a unique 9-character name that gets encoded into a 64-bit type ID for RDB serialization. The encoding packs 9 characters (6 bits each) plus a 10-bit encoding version into a single `uint64_t`:

```
(high order bits) 6|6|6|6|6|6|6|6|6|10 (low order bits)
                  name[0] ...  name[8]   encver
```

**Allowed character set** (64 symbols, 6 bits each):

```
A-Z a-z 0-9 - _
```

Defined in source as:

```c
const char *ModuleTypeNameCharSet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                    "abcdefghijklmnopqrstuvwxyz"
                                    "0123456789-_";
```

**Constraints:**

| Constraint | Value |
|---|---|
| Name length | Exactly 9 characters |
| Encoding version range | 0 to 1023 |
| Reserved name | `AAAAAAAAA` (produces ID 0, treated as error) |

**Naming convention:** Use `<typename>-<vendor>` format to avoid collisions. Example: `tree-AntZ`. Mix upper and lower case for additional collision avoidance.

## CreateDataType

```c
ValkeyModuleType *ValkeyModule_CreateDataType(
    ValkeyModuleCtx *ctx,
    const char *name,      // 9-char unique type name
    int encver,            // encoding version, 0-1023
    ValkeyModuleTypeMethods *typemethods_ptr
);
```

Returns a `ValkeyModuleType*` handle on success, `NULL` on failure. Store the handle in a module-level global for later use with key APIs.

**Failure conditions:**
- Called outside `ValkeyModule_OnLoad()`
- Invalid name length or characters
- `encver` outside 0-1023
- Name already registered by another module
- `typemethods_ptr->version` is 0

**Usage pattern:**

```c
static ValkeyModuleType *MyType;

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModuleTypeMethods tm = {
        .version = VALKEYMODULE_TYPE_METHOD_VERSION,
        .rdb_load = MyType_RdbLoad,
        .rdb_save = MyType_RdbSave,
        .aof_rewrite = MyType_AofRewrite,
        .free = MyType_Free,
    };

    MyType = ValkeyModule_CreateDataType(ctx, "mytype-ab", 0, &tm);
    if (MyType == NULL) return VALKEYMODULE_ERR;
    return VALKEYMODULE_OK;
}
```

## ValkeyModuleTypeMethods Struct

```c
typedef struct ValkeyModuleTypeMethods {
    uint64_t version;                          // VALKEYMODULE_TYPE_METHOD_VERSION
    ValkeyModuleTypeLoadFunc rdb_load;          // void *(*)(ValkeyModuleIO *rdb, int encver)
    ValkeyModuleTypeSaveFunc rdb_save;          // void (*)(ValkeyModuleIO *rdb, void *value)
    ValkeyModuleTypeRewriteFunc aof_rewrite;    // void (*)(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value)
    ValkeyModuleTypeMemUsageFunc mem_usage;     // size_t (*)(const void *value)
    ValkeyModuleTypeDigestFunc digest;          // void (*)(ValkeyModuleDigest *digest, void *value)
    ValkeyModuleTypeFreeFunc free;              // void (*)(void *value)
    ValkeyModuleTypeAuxLoadFunc aux_load;       // int (*)(ValkeyModuleIO *rdb, int encver, int when)
    ValkeyModuleTypeAuxSaveFunc aux_save;       // void (*)(ValkeyModuleIO *rdb, int when)
    int aux_save_triggers;                      // VALKEYMODULE_AUX_BEFORE_RDB | VALKEYMODULE_AUX_AFTER_RDB
    ValkeyModuleTypeFreeEffortFunc free_effort; // size_t (*)(ValkeyModuleString *key, const void *value)
    ValkeyModuleTypeUnlinkFunc unlink;          // void (*)(ValkeyModuleString *key, const void *value)
    ValkeyModuleTypeCopyFunc copy;              // void *(*)(ValkeyModuleString *fromkey, ValkeyModuleString *tokey, const void *value)
    ValkeyModuleTypeDefragFunc defrag;          // int (*)(ValkeyModuleDefragCtx *ctx, ValkeyModuleString *key, void **value)
    ValkeyModuleTypeMemUsageFunc2 mem_usage2;   // size_t (*)(ValkeyModuleKeyOptCtx *ctx, const void *value, size_t sample_size)
    ValkeyModuleTypeFreeEffortFunc2 free_effort2; // size_t (*)(ValkeyModuleKeyOptCtx *ctx, const void *value)
    ValkeyModuleTypeUnlinkFunc2 unlink2;        // void (*)(ValkeyModuleKeyOptCtx *ctx, const void *value)
    ValkeyModuleTypeCopyFunc2 copy2;            // void *(*)(ValkeyModuleKeyOptCtx *ctx, const void *value)
    ValkeyModuleTypeAuxSaveFunc aux_save2;      // void (*)(ValkeyModuleIO *rdb, int when)
} ValkeyModuleTypeMethods;
```

Always set `.version = VALKEYMODULE_TYPE_METHOD_VERSION` (currently **5**). Unset fields default to `NULL` via C designated initializer zeroing.

## Callback Version History

The server reads fields based on the `version` value in the struct:

| Version | Callbacks Added |
|---|---|
| 1 | `rdb_load`, `rdb_save`, `aof_rewrite`, `mem_usage`, `digest`, `free` |
| 2 | `aux_load`, `aux_save`, `aux_save_triggers` |
| 3 | `free_effort`, `unlink`, `copy`, `defrag` |
| 4 | `mem_usage2`, `free_effort2`, `unlink2`, `copy2` |
| 5 | `aux_save2` |

The "2" variants (`mem_usage2`, `free_effort2`, `unlink2`, `copy2`) receive a `ValkeyModuleKeyOptCtx*` instead of separate key name and db id arguments, providing richer metadata. If both a v1 and v2 variant are set, the v2 variant takes precedence.

The `aux_save2` variant differs from `aux_save` semantically: if the callback writes nothing, no aux data is stored in the RDB, allowing the RDB to load even without the module present.

## Key Value Accessors

**ModuleTypeSetValue** - assign a module value to a key:

```c
int ValkeyModule_ModuleTypeSetValue(ValkeyModuleKey *key, ValkeyModuleType *mt, void *value);
```

Key must be open for writing (`VALKEYMODULE_WRITE`). Deletes any existing value. Returns `VALKEYMODULE_OK` or `VALKEYMODULE_ERR`.

**ModuleTypeGetValue** - retrieve the stored value:

```c
void *ValkeyModule_ModuleTypeGetValue(ValkeyModuleKey *key);
```

Returns `NULL` if key is empty, not a module type, or `key` is `NULL`.

**ModuleTypeGetType** - get the type handle from a key:

```c
ValkeyModuleType *ValkeyModule_ModuleTypeGetType(ValkeyModuleKey *key);
```

Use to verify the key holds your type before accessing its value.

**ModuleTypeReplaceValue** - swap value without freeing the old one:

```c
int ValkeyModule_ModuleTypeReplaceValue(
    ValkeyModuleKey *key, ValkeyModuleType *mt,
    void *new_value, void **old_value);
```

Unlike `SetValue`, this does not free the previous value. The old value is returned through `old_value` if non-NULL. Fails if key type does not match `mt`.

## GetTypeMethodVersion

```c
int ValkeyModule_GetTypeMethodVersion(void);
```

Returns the server's runtime `VALKEYMODULE_TYPE_METHOD_VERSION`. Use this to check which callback fields the running server supports before registration.

## See Also

- [rdb-callbacks.md](rdb-callbacks.md) - RDB save/load primitives for rdb_save and rdb_load callbacks
- [aof-rewrite.md](aof-rewrite.md) - AOF rewrite callback and EmitAOF
- [digest.md](digest.md) - DEBUG DIGEST callback implementation
- [io-context.md](io-context.md) - IO context helpers and aux data callbacks
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - OnLoad where CreateDataType must be called
- [../lifecycle/module-options.md](../lifecycle/module-options.md) - Module option flags including IO error handling
- [../defrag.md](../defrag.md) - Defragmentation callback registered in ValkeyModuleTypeMethods
