# IO Context Helpers - GetKeyNameFromIO, Aux Data, and OptCtx Accessors

Use when accessing key metadata during RDB/AOF callbacks, implementing aux_load/aux_save for out-of-keyspace global state, using ValkeyModuleKeyOptCtx accessors in v2 callbacks (mem_usage2, free_effort2, unlink2, copy2), or enabling IO error handling for diskless replication.

Source: `src/module.c` (lines 7867-7901, 449-456, 4482-4499), `src/valkeymodule.h` (lines 297-299, 320-321)

## Contents

- [IO context metadata](#io-context-metadata)
- [ValkeyModuleKeyOptCtx accessors](#valkeymodulekeyoptctx-accessors)
- [Aux data callbacks](#aux-data-callbacks)
- [IO error handling](#io-error-handling)

---

## IO Context Metadata

These functions extract key and database information from the `ValkeyModuleIO*` context passed to `rdb_load`, `rdb_save`, and `aof_rewrite` callbacks.

**GetKeyNameFromIO** - get the key name during RDB/AOF operations:

```c
const ValkeyModuleString *ValkeyModule_GetKeyNameFromIO(ValkeyModuleIO *io);
```

Returns the key name being processed, or `NULL` if not available. There is no guarantee the key name is always set - during aux data callbacks, for example, there is no associated key.

**GetDbIdFromIO** - get the database ID:

```c
int ValkeyModule_GetDbIdFromIO(ValkeyModuleIO *io);
```

Returns the database ID of the key being processed, or `-1` if not available.

**GetContextFromIO** - obtain a module context from the IO handle:

```c
ValkeyModuleCtx *ValkeyModule_GetContextFromIO(ValkeyModuleIO *io);
```

Returns a `ValkeyModuleCtx*` that can be used for logging or other context-dependent operations within RDB/AOF callbacks. Only one context can exist per IO handle - subsequent calls return the same context.

## ValkeyModuleKeyOptCtx Accessors

The `ValkeyModuleKeyOptCtx` struct provides richer metadata to v2 callbacks (`mem_usage2`, `free_effort2`, `unlink2`, `copy2`). It holds source and destination key/db information.

Internal structure (from `src/module.c`):

```c
typedef struct ValkeyModuleKeyOptCtx {
    struct serverObject *from_key, *to_key;
    int from_dbid, to_dbid;
} ValkeyModuleKeyOptCtx;
```

**Source key accessors:**

```c
const ValkeyModuleString *ValkeyModule_GetKeyNameFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
```

Returns the source key name.

```c
int ValkeyModule_GetDbIdFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
```

Returns the source database ID.

**Destination key accessors** (relevant for `copy2` callback):

```c
const ValkeyModuleString *ValkeyModule_GetToKeyNameFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
```

Returns the destination key name. Only valid in callbacks that involve two keys, such as `copy2`.

```c
int ValkeyModule_GetToDbIdFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
```

Returns the destination database ID. Only valid in multi-key callbacks.

**Usage in copy2:**

```c
void *MyType_Copy2(ValkeyModuleKeyOptCtx *ctx, const void *value) {
    const ValkeyModuleString *from = ValkeyModule_GetKeyNameFromOptCtx(ctx);
    const ValkeyModuleString *to = ValkeyModule_GetToKeyNameFromOptCtx(ctx);
    int from_db = ValkeyModule_GetDbIdFromOptCtx(ctx);
    int to_db = ValkeyModule_GetToDbIdFromOptCtx(ctx);

    // Deep copy the value
    MyData *copy = MyData_DeepCopy((MyData *)value);
    return copy;
}
```

## Aux Data Callbacks

Aux (auxiliary) data lets a module store out-of-keyspace data in the RDB file - data that is not associated with any particular key, such as global module state, metadata, or indexes.

**Callback signatures:**

```c
typedef int (*ValkeyModuleTypeAuxLoadFunc)(ValkeyModuleIO *rdb, int encver, int when);
typedef void (*ValkeyModuleTypeAuxSaveFunc)(ValkeyModuleIO *rdb, int when);
```

**Trigger flags** (set in `ValkeyModuleTypeMethods.aux_save_triggers`):

| Flag | Value | Description |
|---|---|---|
| `VALKEYMODULE_AUX_BEFORE_RDB` | `1 << 0` | Save/load aux data before key data |
| `VALKEYMODULE_AUX_AFTER_RDB` | `1 << 1` | Save/load aux data after key data |

Both flags can be combined with bitwise OR to save aux data at both points.

**aux_save callback:** Called during RDB save. Use the standard `SaveUnsigned`, `SaveString`, etc. primitives to write global state. The `when` parameter indicates whether this is the before-RDB or after-RDB pass.

**aux_load callback:** Called during RDB load. Use the standard `LoadUnsigned`, `LoadString`, etc. primitives to restore global state. Must return `VALKEYMODULE_OK` on success or `VALKEYMODULE_ERR` on failure.

**aux_save2 vs aux_save:** The `aux_save2` variant (version 5) has different semantics: if the callback writes nothing, no aux data record is stored in the RDB. This means the RDB can be loaded even if the module is not present. With the original `aux_save`, an empty-write still creates a record that requires the module at load time.

**Example:**

```c
void MyModule_AuxSave(ValkeyModuleIO *rdb, int when) {
    if (when == VALKEYMODULE_AUX_BEFORE_RDB) {
        ValkeyModule_SaveUnsigned(rdb, global_counter);
        ValkeyModule_SaveStringBuffer(rdb, global_name, strlen(global_name));
    }
}

int MyModule_AuxLoad(ValkeyModuleIO *rdb, int encver, int when) {
    if (when == VALKEYMODULE_AUX_BEFORE_RDB) {
        global_counter = ValkeyModule_LoadUnsigned(rdb);
        if (ValkeyModule_IsIOError(rdb)) return VALKEYMODULE_ERR;
        size_t len;
        char *name = ValkeyModule_LoadStringBuffer(rdb, &len);
        if (ValkeyModule_IsIOError(rdb)) return VALKEYMODULE_ERR;
        memcpy(global_name, name, len);
        ValkeyModule_Free(name);
    }
    return VALKEYMODULE_OK;
}
```

Register with triggers:

```c
ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load = MyType_RdbLoad,
    .rdb_save = MyType_RdbSave,
    .free = MyType_Free,
    .aux_load = MyModule_AuxLoad,
    .aux_save = MyModule_AuxSave,
    .aux_save_triggers = VALKEYMODULE_AUX_BEFORE_RDB,
};
```

## IO Error Handling

See [rdb-callbacks.md - Error Handling](rdb-callbacks.md#error-handling) for the full `VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS` reference and code example. The same error handling applies to aux_load callbacks and `LoadDataTypeFromString` / `LoadDataTypeFromStringEncver`. The flag is also required for diskless replication - the server checks `moduleAllDatatypesHandleErrors()` and disables diskless loading if any module type lacks it.

## See Also

- [registration.md](registration.md) - ValkeyModuleTypeMethods struct with aux fields and version history
- [rdb-callbacks.md](rdb-callbacks.md) - RDB save/load primitives used in aux callbacks
- [digest.md](digest.md) - Similar metadata accessors (GetKeyNameFromDigest, GetDbIdFromDigest)
- [rdb-stream.md](rdb-stream.md) - Full-file RDB API for module-driven persistence
- [../lifecycle/module-options.md](../lifecycle/module-options.md) - HANDLE_IO_ERRORS and other module option flags
- [../defrag.md](../defrag.md) - Defrag callback that also uses ValkeyModuleKeyOptCtx-style context
