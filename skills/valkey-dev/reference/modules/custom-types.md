# Custom Data Types and RDB Serialization

Use when implementing a custom data type with RDB persistence, AOF rewrite callbacks, or working with the ValkeyModuleTypeMethods struct and encoding version system.

Source: `src/valkeymodule.h` (lines 1413-1433), `src/module.c` (lines 7088-7290)

## Contents

- Registration (line 17)
- Type Name Encoding (line 39)
- ValkeyModuleTypeMethods (line 46)
- Callback Signatures (line 73)
- Auxiliary Data (line 114)
- RDB Serialization Primitives (line 126)
- Setting and Getting Module Type Values on Keys (line 165)
- Quick Reference: Custom Type Skeleton (line 186)
- See Also (line 212)

---

## Registration

Register during `ValkeyModule_OnLoad` with `ValkeyModule_CreateDataType`:

```c
ValkeyModuleType *ValkeyModule_CreateDataType(
    ValkeyModuleCtx *ctx,
    const char *name,      // Exactly 9 characters: A-Z a-z 0-9 _ -
    int encver,            // Encoding version (0-1023)
    ValkeyModuleTypeMethods *typemethods
);
```

Returns a `ValkeyModuleType*` handle on success, `NULL` on failure. Store this in a global variable - you need it to set/get values on keys.

Failure cases:
- Called outside `ValkeyModule_OnLoad`
- A type with the same name already exists
- Name is not exactly 9 characters from the valid charset
- Encoding version is outside 0-1023
- The reserved name "AAAAAAAAA" is used

## Type Name Encoding

The 9-character name is encoded into a 64-bit signature: 54 bits for the name (6 bits per character) and 10 bits for the encoding version. This signature is stored in RDB files, allowing the server to dispatch loading to the correct module regardless of encoding version.

Convention for collision avoidance: `<typename>-<vendor>`. For example, `"tree-AntZ"` or `"graph-MyC"`.

## ValkeyModuleTypeMethods

```c
typedef struct ValkeyModuleTypeMethods {
    uint64_t version;                          // VALKEYMODULE_TYPE_METHOD_VERSION (currently 5)
    ValkeyModuleTypeLoadFunc rdb_load;          // Load value from RDB
    ValkeyModuleTypeSaveFunc rdb_save;          // Save value to RDB
    ValkeyModuleTypeRewriteFunc aof_rewrite;    // Rewrite as commands for AOF
    ValkeyModuleTypeMemUsageFunc mem_usage;     // Report memory usage
    ValkeyModuleTypeDigestFunc digest;          // DEBUG DIGEST support
    ValkeyModuleTypeFreeFunc free;              // Free the value
    ValkeyModuleTypeAuxLoadFunc aux_load;       // Load auxiliary data (v2+)
    ValkeyModuleTypeAuxSaveFunc aux_save;       // Save auxiliary data (v2+)
    int aux_save_triggers;                      // BEFORE_RDB, AFTER_RDB, or both (v2+)
    ValkeyModuleTypeFreeEffortFunc free_effort;  // Lazy free complexity hint (v3+)
    ValkeyModuleTypeUnlinkFunc unlink;          // Key removed from DB (v3+)
    ValkeyModuleTypeCopyFunc copy;              // COPY command support (v3+)
    ValkeyModuleTypeDefragFunc defrag;          // Active defrag support (v3+)
    ValkeyModuleTypeMemUsageFunc2 mem_usage2;   // mem_usage with key context (v4+)
    ValkeyModuleTypeFreeEffortFunc2 free_effort2; // free_effort with key context (v4+)
    ValkeyModuleTypeUnlinkFunc2 unlink2;        // unlink with key context (v4+)
    ValkeyModuleTypeCopyFunc2 copy2;            // copy with key context (v4+)
    ValkeyModuleTypeAuxSaveFunc aux_save2;      // aux_save that writes nothing = no RDB data (v5+)
} ValkeyModuleTypeMethods;
```

The version field controls which callbacks the server reads. Set it to `VALKEYMODULE_TYPE_METHOD_VERSION` to use all available fields. Unset fields default to NULL via designated initializer zeroing.

## Callback Signatures

```c
// RDB load: deserialize value from RDB. encver is the encoding version from the RDB file.
void *MyType_RdbLoad(ValkeyModuleIO *rdb, int encver);

// RDB save: serialize value to RDB.
void MyType_RdbSave(ValkeyModuleIO *rdb, void *value);

// AOF rewrite: emit commands that reconstruct the value.
void MyType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value);

// Free: release all memory for the value.
void MyType_Free(void *value);

// Digest: produce a deterministic hash for DEBUG DIGEST.
void MyType_Digest(ValkeyModuleDigest *digest, void *value);

// Memory usage: return approximate bytes used by the value.
size_t MyType_MemUsage(const void *value);

// Copy: deep-copy the value for the COPY command. Return NULL on failure.
void *MyType_Copy(ValkeyModuleString *fromkey, ValkeyModuleString *tokey, const void *value);

// Unlink: notification that key was removed (may be freed by background thread).
void MyType_Unlink(ValkeyModuleString *key, const void *value);

// Free effort: return complexity of freeing (higher = more likely to use lazy free).
size_t MyType_FreeEffort(ValkeyModuleString *key, const void *value);

// Defrag: iterate pointers and call VM_DefragAlloc(). Return 0 if done, non-zero if more work.
int MyType_Defrag(ValkeyModuleDefragCtx *ctx, ValkeyModuleString *key, void **value);
```

The "2" variants (`mem_usage2`, `free_effort2`, `unlink2`, `copy2`) receive a `ValkeyModuleKeyOptCtx*` instead of separate key/fromkey/tokey parameters, providing access to key name and database ID via:
- `ValkeyModule_GetKeyNameFromOptCtx(ctx)`
- `ValkeyModule_GetDbIdFromOptCtx(ctx)`
- `ValkeyModule_GetToKeyNameFromOptCtx(ctx)` (for copy)
- `ValkeyModule_GetToDbIdFromOptCtx(ctx)` (for copy)

## Auxiliary Data

For data that is not key-bound but must persist across restarts. The `aux_save_triggers` bitmask controls when the callback fires:

```c
#define VALKEYMODULE_AUX_BEFORE_RDB (1 << 0)
#define VALKEYMODULE_AUX_AFTER_RDB  (1 << 1)
```

`aux_save2` (v5): If the callback writes nothing, no aux field entry is created in the RDB. This means the RDB can load even without the module present - useful for optional metadata.

---

## RDB Serialization Primitives

Used inside `rdb_load` and `rdb_save` callbacks:

| Save function | Load function | Data type |
|--------------|---------------|-----------|
| `ValkeyModule_SaveUnsigned(io, val)` | `ValkeyModule_LoadUnsigned(io)` | `uint64_t` |
| `ValkeyModule_SaveSigned(io, val)` | `ValkeyModule_LoadSigned(io)` | `int64_t` |
| `ValkeyModule_SaveDouble(io, val)` | `ValkeyModule_LoadDouble(io)` | `double` |
| `ValkeyModule_SaveFloat(io, val)` | `ValkeyModule_LoadFloat(io)` | `float` |
| `ValkeyModule_SaveLongDouble(io, val)` | `ValkeyModule_LoadLongDouble(io)` | `long double` |
| `ValkeyModule_SaveString(io, str)` | `ValkeyModule_LoadString(io)` | `ValkeyModuleString*` |
| `ValkeyModule_SaveStringBuffer(io, buf, len)` | `ValkeyModule_LoadStringBuffer(io, &len)` | raw bytes |

Error handling: check `ValkeyModule_IsIOError(io)` after load operations. Enable error handling with `ValkeyModule_SetModuleOptions(ctx, VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS)`.

### Serialization to/from strings (in-memory)

```c
ValkeyModuleString *str = ValkeyModule_SaveDataTypeToString(ctx, data, mt);
void *data = ValkeyModule_LoadDataTypeFromString(str, mt);
void *data = ValkeyModule_LoadDataTypeFromStringEncver(str, mt, encver);
```

### AOF Rewrite

Inside the `aof_rewrite` callback, emit commands that reconstruct the value:

```c
void MyType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    MyData *data = value;
    ValkeyModule_EmitAOF(aof, "MYTYPE.SET", "sl", key, data->counter);
}
```

Format specifiers for `ValkeyModule_EmitAOF`: same as `ValkeyModule_Call` - `s` (ValkeyModuleString), `c` (C string), `l` (long long), `b` (buffer + length).

---

## Setting and Getting Module Type Values on Keys

```c
// Set a module-type value on a key (overwrites existing value)
int ValkeyModule_ModuleTypeSetValue(ValkeyModuleKey *key, ValkeyModuleType *mt, void *value);

// Replace value, returning the old one (caller must free it)
int ValkeyModule_ModuleTypeReplaceValue(ValkeyModuleKey *key, ValkeyModuleType *mt,
                                         void *new_value, void **old_value);

// Get the type handle for a module-type key
ValkeyModuleType *ValkeyModule_ModuleTypeGetType(ValkeyModuleKey *key);

// Get the raw value pointer
void *ValkeyModule_ModuleTypeGetValue(ValkeyModuleKey *key);
```

---

## Quick Reference: Custom Type Skeleton

```c
static ValkeyModuleType *MyType;
typedef struct { int64_t value; } MyData;

void *MyData_RdbLoad(ValkeyModuleIO *rdb, int encver) {
    MyData *d = ValkeyModule_Alloc(sizeof(*d));
    d->value = ValkeyModule_LoadSigned(rdb);
    return d;
}
void MyData_RdbSave(ValkeyModuleIO *rdb, void *value) {
    ValkeyModule_SaveSigned(rdb, ((MyData*)value)->value);
}
void MyData_Free(void *value) { ValkeyModule_Free(value); }

// In OnLoad:
ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load = MyData_RdbLoad, .rdb_save = MyData_RdbSave, .free = MyData_Free,
};
MyType = ValkeyModule_CreateDataType(ctx, "mydata--x", 0, &tm);
```

---

## See Also

- [key-api-and-blocking](key-api-and-blocking.md) - key access API, blocking commands
- [module-lifecycle](module-lifecycle.md) - module lifecycle, command registration
