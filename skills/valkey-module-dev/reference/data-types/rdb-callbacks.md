# RDB Callbacks - rdb_load, rdb_save, and All RDB Primitives

Use when implementing rdb_load and rdb_save callbacks for a custom data type, serializing module values to RDB, choosing between Save/Load primitives, or using SaveDataTypeToString/LoadDataTypeFromString for in-memory serialization.

Source: `src/module.c` (lines 7319-7801), `src/rdb.h` (lines 159-165)

## Contents

- [RDB callback signatures](#rdb-callback-signatures)
- [Save primitives](#save-primitives)
- [Load primitives](#load-primitives)
- [Error handling](#error-handling)
- [String serialization](#string-serialization)
- [Complete example](#complete-example)

---

## RDB Callback Signatures

```c
// rdb_load: called during RDB loading to deserialize a value
typedef void *(*ValkeyModuleTypeLoadFunc)(ValkeyModuleIO *rdb, int encver);

// rdb_save: called during RDB saving to serialize a value
typedef void (*ValkeyModuleTypeSaveFunc)(ValkeyModuleIO *rdb, void *value);
```

The `encver` parameter in `rdb_load` is the encoding version that was used when the data was saved. This lets modules handle format migrations - load old formats while saving in the current format.

## Save Primitives

All save functions operate within the `rdb_save` callback context via the `ValkeyModuleIO*` handle.

| Function | Signature | Notes |
|---|---|---|
| `SaveUnsigned` | `void ValkeyModule_SaveUnsigned(ValkeyModuleIO *io, uint64_t value)` | Unsigned 64-bit integer |
| `SaveSigned` | `void ValkeyModule_SaveSigned(ValkeyModuleIO *io, int64_t value)` | Signed 64-bit integer (stored as uint64 via union) |
| `SaveString` | `void ValkeyModule_SaveString(ValkeyModuleIO *io, ValkeyModuleString *s)` | ValkeyModuleString object |
| `SaveStringBuffer` | `void ValkeyModule_SaveStringBuffer(ValkeyModuleIO *io, const char *str, size_t len)` | Raw C buffer |
| `SaveDouble` | `void ValkeyModule_SaveDouble(ValkeyModuleIO *io, double value)` | 64-bit double (supports NaN, infinity) |
| `SaveFloat` | `void ValkeyModule_SaveFloat(ValkeyModuleIO *io, float value)` | 32-bit float (supports NaN, infinity) |
| `SaveLongDouble` | `void ValkeyModule_SaveLongDouble(ValkeyModuleIO *io, long double value)` | Stored as hex string for portability |

Each save function writes an opcode tag before the value, ensuring type-safe loading. The internal opcode constants from `rdb.h`:

| Opcode | Constant | Value |
|---|---|---|
| End of value | `RDB_MODULE_OPCODE_EOF` | 0 |
| Signed int | `RDB_MODULE_OPCODE_SINT` | 1 |
| Unsigned int | `RDB_MODULE_OPCODE_UINT` | 2 |
| Float | `RDB_MODULE_OPCODE_FLOAT` | 3 |
| Double | `RDB_MODULE_OPCODE_DOUBLE` | 4 |
| String | `RDB_MODULE_OPCODE_STRING` | 5 |

## Load Primitives

All load functions operate within the `rdb_load` callback context. Each validates the opcode before reading the value.

| Function | Signature | Returns on error |
|---|---|---|
| `LoadUnsigned` | `uint64_t ValkeyModule_LoadUnsigned(ValkeyModuleIO *io)` | 0 |
| `LoadSigned` | `int64_t ValkeyModule_LoadSigned(ValkeyModuleIO *io)` | 0 |
| `LoadString` | `ValkeyModuleString *ValkeyModule_LoadString(ValkeyModuleIO *io)` | NULL |
| `LoadStringBuffer` | `char *ValkeyModule_LoadStringBuffer(ValkeyModuleIO *io, size_t *lenptr)` | NULL |
| `LoadDouble` | `double ValkeyModule_LoadDouble(ValkeyModuleIO *io)` | 0 |
| `LoadFloat` | `float ValkeyModule_LoadFloat(ValkeyModuleIO *io)` | 0 |
| `LoadLongDouble` | `long double ValkeyModule_LoadLongDouble(ValkeyModuleIO *io)` | 0 |

**Important differences between LoadString and LoadStringBuffer:**

- `LoadString` returns a `ValkeyModuleString*` - free with `ValkeyModule_FreeString()`
- `LoadStringBuffer` returns a heap-allocated `char*` - free with `ValkeyModule_Free()`. The buffer is NOT null-terminated. Length is stored in `*lenptr`.

**Order matters:** Save and load calls must be in the same order. Every `Save*` in `rdb_save` must have a matching `Load*` in `rdb_load`.

## Error Handling

When an RDB load encounters corrupted or truncated data, the behavior depends on module options:

```c
int ValkeyModule_IsIOError(ValkeyModuleIO *io);
```

Returns non-zero if any previous IO operation failed.

**Without `VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS`:** The server terminates with a panic message including the module name, type name, bytes read, and key name.

**With `VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS`:** The `io->error` flag is set to 1. All subsequent Save/Load calls become no-ops. The `rdb_load` callback should check `ValkeyModule_IsIOError()` and return `NULL` to signal failure.

```c
void *MyType_RdbLoad(ValkeyModuleIO *rdb, int encver) {
    uint64_t count = ValkeyModule_LoadUnsigned(rdb);
    if (ValkeyModule_IsIOError(rdb)) return NULL;

    MyData *data = MyData_Create();
    for (uint64_t i = 0; i < count; i++) {
        char *buf = ValkeyModule_LoadStringBuffer(rdb, &len);
        if (ValkeyModule_IsIOError(rdb)) {
            MyData_Free(data);
            return NULL;
        }
        MyData_Add(data, buf, len);
        ValkeyModule_Free(buf);
    }
    return data;
}
```

Enable IO error handling during module init:

```c
ValkeyModule_SetModuleOptions(ctx, VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS);
```

This is required for diskless replication to work safely with your module, and for safe use of `LoadDataTypeFromString` / `LoadDataTypeFromStringEncver`.

## String Serialization

These functions reuse the `rdb_save`/`rdb_load` callbacks to serialize module values to/from strings in memory, similar to how `DUMP` and `RESTORE` work.

**SaveDataTypeToString** - serialize a value to a ValkeyModuleString:

```c
ValkeyModuleString *ValkeyModule_SaveDataTypeToString(
    ValkeyModuleCtx *ctx, void *data, const ValkeyModuleType *mt);
```

Returns `NULL` on error. The returned string is auto-memory managed if `ctx` is non-NULL.

**LoadDataTypeFromString** - deserialize from a ValkeyModuleString:

```c
void *ValkeyModule_LoadDataTypeFromString(
    const ValkeyModuleString *str, const ValkeyModuleType *mt);
```

Uses encoding version 0. For specific versions, use:

```c
void *ValkeyModule_LoadDataTypeFromStringEncver(
    const ValkeyModuleString *str, const ValkeyModuleType *mt, int encver);
```

Modules should set `VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS` and check for errors - corrupted input will terminate the server otherwise.

## Complete Example

From the built-in `hellotype` module (`src/modules/hellotype.c`):

```c
void *HelloTypeRdbLoad(ValkeyModuleIO *rdb, int encver) {
    if (encver != 0) return NULL;  // reject unknown versions
    uint64_t elements = ValkeyModule_LoadUnsigned(rdb);
    struct HelloTypeObject *hto = createHelloTypeObject();
    while (elements--) {
        int64_t ele = ValkeyModule_LoadSigned(rdb);
        HelloTypeInsert(hto, ele);
    }
    return hto;
}

void HelloTypeRdbSave(ValkeyModuleIO *rdb, void *value) {
    struct HelloTypeObject *hto = value;
    struct HelloTypeNode *node = hto->head;
    ValkeyModule_SaveUnsigned(rdb, hto->len);
    while (node) {
        ValkeyModule_SaveSigned(rdb, node->value);
        node = node->next;
    }
}
```

Pattern: save element count first, then each element. On load, read count, then loop to restore.

## See Also

- [registration.md](registration.md) - CreateDataType and ValkeyModuleTypeMethods struct
- [io-context.md](io-context.md) - GetKeyNameFromIO, aux data callbacks, and IO error handling details
- [aof-rewrite.md](aof-rewrite.md) - AOF rewrite as an alternative persistence path
- [rdb-stream.md](rdb-stream.md) - Full-file RDB load/save API
- [../lifecycle/module-options.md](../lifecycle/module-options.md) - HANDLE_IO_ERRORS flag for diskless replication
- [../lifecycle/memory.md](../lifecycle/memory.md) - Memory allocation for objects created during rdb_load
