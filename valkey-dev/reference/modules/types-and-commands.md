# Custom Types and Advanced Commands

Use when implementing a custom data type with RDB persistence, building blocking commands, or working with the low-level key access API.

Source: `src/valkeymodule.h` (lines 1413-1433), `src/module.h` (lines 28-76), `src/module.c` (lines 7088-7290, 8053-8672)

---

## Custom Data Types

### Registration

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

### Type name encoding

The 9-character name is encoded into a 64-bit signature: 54 bits for the name (6 bits per character) and 10 bits for the encoding version. This signature is stored in RDB files, allowing the server to dispatch loading to the correct module regardless of encoding version.

Convention for collision avoidance: `<typename>-<vendor>`. For example, `"tree-AntZ"` or `"graph-MyC"`.

### ValkeyModuleTypeMethods

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

### Callback signatures

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
// Return 0 to always use async free.
size_t MyType_FreeEffort(ValkeyModuleString *key, const void *value);

// Defrag: iterate pointers and call VM_DefragAlloc(). Return 0 if done, non-zero if more work.
int MyType_Defrag(ValkeyModuleDefragCtx *ctx, ValkeyModuleString *key, void **value);
```

The "2" variants (`mem_usage2`, `free_effort2`, `unlink2`, `copy2`) receive a `ValkeyModuleKeyOptCtx*` instead of separate key/fromkey/tokey parameters, providing access to key name and database ID via:
- `ValkeyModule_GetKeyNameFromOptCtx(ctx)`
- `ValkeyModule_GetDbIdFromOptCtx(ctx)`
- `ValkeyModule_GetToKeyNameFromOptCtx(ctx)` (for copy)
- `ValkeyModule_GetToDbIdFromOptCtx(ctx)` (for copy)

### Auxiliary data (aux_load / aux_save)

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

### AOF rewrite

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

## Key Access API

### Opening and closing keys

```c
ValkeyModuleKey *ValkeyModule_OpenKey(ValkeyModuleCtx *ctx, ValkeyModuleString *keyname, int mode);
void ValkeyModule_CloseKey(ValkeyModuleKey *kp);
```

Mode flags:

| Flag | Value | Meaning |
|------|-------|---------|
| `VALKEYMODULE_READ` | `1 << 0` | Read access |
| `VALKEYMODULE_WRITE` | `1 << 1` | Write access (creates key if absent) |
| `VALKEYMODULE_OPEN_KEY_NOTOUCH` | `1 << 16` | Do not update LRU/LFU |
| `VALKEYMODULE_OPEN_KEY_NONOTIFY` | `1 << 17` | Do not trigger keyspace miss events |
| `VALKEYMODULE_OPEN_KEY_NOSTATS` | `1 << 18` | Do not update hit/miss counters |
| `VALKEYMODULE_OPEN_KEY_NOEXPIRE` | `1 << 19` | Do not delete lazy-expired keys |
| `VALKEYMODULE_OPEN_KEY_NOEFFECTS` | `1 << 20` | Combination of all "no" flags |

When opened with `VALKEYMODULE_READ` only and the key does not exist, `OpenKey` returns `NULL`. When opened with `VALKEYMODULE_WRITE`, a handle is always returned (the key may not exist yet, but you can create it).

### Key type inspection

```c
int ValkeyModule_KeyType(ValkeyModuleKey *kp);
```

Returns one of:
- `VALKEYMODULE_KEYTYPE_EMPTY` (0) - Key does not exist
- `VALKEYMODULE_KEYTYPE_STRING` (1)
- `VALKEYMODULE_KEYTYPE_LIST` (2)
- `VALKEYMODULE_KEYTYPE_HASH` (3)
- `VALKEYMODULE_KEYTYPE_SET` (4)
- `VALKEYMODULE_KEYTYPE_ZSET` (5)
- `VALKEYMODULE_KEYTYPE_MODULE` (6) - Custom module type
- `VALKEYMODULE_KEYTYPE_STREAM` (7)

### String operations on keys

```c
int ValkeyModule_StringSet(ValkeyModuleKey *key, ValkeyModuleString *str);
char *ValkeyModule_StringDMA(ValkeyModuleKey *key, size_t *len, int mode);  // Direct memory access
int ValkeyModule_StringTruncate(ValkeyModuleKey *key, size_t newlen);
```

### Expiry

```c
mstime_t ValkeyModule_GetExpire(ValkeyModuleKey *key);       // Relative TTL in ms
int ValkeyModule_SetExpire(ValkeyModuleKey *key, mstime_t expire);
mstime_t ValkeyModule_GetAbsExpire(ValkeyModuleKey *key);    // Absolute Unix time ms
int ValkeyModule_SetAbsExpire(ValkeyModuleKey *key, mstime_t expire);
```

`VALKEYMODULE_NO_EXPIRE` (-1) means no expiry.

### High-level command call

```c
ValkeyModuleCallReply *ValkeyModule_Call(ValkeyModuleCtx *ctx, const char *cmdname,
                                          const char *fmt, ...);
```

Format specifiers for arguments: `c` (C string), `s` (ValkeyModuleString), `l` (long long), `b` (buffer + length), `v` (vector of ValkeyModuleString).

Behavior flags: `!` (replicate to AOF and replicas), `A` (suppress AOF propagation, requires `!`), `R` (suppress replica propagation, requires `!`), `C` (run as context user with ACL check), `S` (script mode), `W` (no write commands), `M` (respect deny-oom flag), `E` (return errors as CallReply), `D` (dry run), `K` (allow blocking), `0` (auto RESP mode), `3` (force RESP3), `X` (exact reply types).

---

## Blocking Commands

### Basic blocking pattern

```c
ValkeyModuleBlockedClient *ValkeyModule_BlockClient(
    ValkeyModuleCtx *ctx,
    ValkeyModuleCmdFunc reply_callback,      // Called when unblocked
    ValkeyModuleCmdFunc timeout_callback,    // Called on timeout
    void (*free_privdata)(ValkeyModuleCtx *, void *),  // Free private data
    long long timeout_ms                     // 0 = no timeout
);
```

Returns `NULL` if blocking is not possible (client is a temp client, already blocked, in script, or in MULTI). Check `errno` for the specific reason:
- `EINVAL` - Temp/new client, or keyspace notification during MULTI
- `ENOTSUP` - Client already blocked

### Unblocking

From any thread:

```c
int ValkeyModule_UnblockClient(ValkeyModuleBlockedClient *bc, void *privdata);
```

The `privdata` is passed to the `reply_callback`. Returns `VALKEYMODULE_ERR` if `bc` is NULL (`errno = EINVAL`) or if blocked-on-keys without timeout callback (`errno = ENOTSUP`).

`ValkeyModule_UnblockClient` must be called for every blocked client, even if the client was killed, timed out, or disconnected. Failure to do so causes memory leaks.

### Blocking on keys

`ValkeyModule_BlockClientOnKeys` takes the same parameters plus `keys`, `numkeys`, and `privdata`. The `reply_callback` fires every time a watched key is signaled as ready - check if the key contains what you need and return `VALKEYMODULE_ERR` to keep waiting. Use `ValkeyModule_SignalKeyAsReady(ctx, key)` from write commands on your custom type to wake blocked clients.

### Thread-safe contexts

For background threads: `ValkeyModule_GetThreadSafeContext(bc)` returns a context you must lock/unlock with `ThreadSafeContextLock`/`ThreadSafeContextUnlock` and free with `FreeThreadSafeContext`. For detached contexts not tied to a blocked client, use `ValkeyModule_GetDetachedThreadSafeContext`.

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

- [Module API Overview](../modules/api-overview.md) - Core module lifecycle, command registration, context object, memory management, and reply helpers.
- [Rust SDK for Valkey Modules](../modules/rust-sdk.md) - Rust bindings for custom types and blocking commands. The Rust `ValkeyType::new()` wraps `ValkeyModule_CreateDataType`; blocking uses `Context::block_client()`.
- [Blocking Operations](../transactions/blocking.md) - Server-side blocking infrastructure. Module-blocked clients use the `BLOCKED_MODULE` type and integrate with the same key-readiness notification system (`signalKeyAsReady`).
- [ACL Subsystem](../security/acl.md) - Module commands are subject to ACL enforcement. Key access permissions (read/write) are checked against ACL key patterns.
- [Tcl Integration Tests](../testing/tcl-tests.md) - Module API tests live in `tests/unit/moduleapi/` and are run via `./runtest-moduleapi`. Test modules (C source in `tests/modules/`) are compiled automatically by the test runner.
