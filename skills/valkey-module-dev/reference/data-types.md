# Custom Data Types

Use when implementing a custom data type with RDB persistence, AOF rewrite, memory reporting, lazy-free, defrag, or auxiliary data. Source: `src/valkeymodule.h`, `src/module.c`

---

## Registration

Register during `ValkeyModule_OnLoad`:

```c
static ValkeyModuleType *MyType;

ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load = MyType_RdbLoad,
    .rdb_save = MyType_RdbSave,
    .aof_rewrite = MyType_AofRewrite,
    .free = MyType_Free,
    .mem_usage = MyType_MemUsage,
};
MyType = ValkeyModule_CreateDataType(ctx, "mytree--x", 0, &tm);
if (MyType == NULL) return VALKEYMODULE_ERR;
```

**Name**: exactly 9 characters from `A-Z a-z 0-9 _ -`. Convention: `<type>-<vendor>` (e.g., `"graph-MyC"`). The name is encoded into a 64-bit RDB signature.

**Encoding version**: 0-1023. Increment when changing the RDB format. The old `encver` is passed to `rdb_load` so you can handle migrations.

Store the returned `ValkeyModuleType*` in a global - you need it for all key operations on your type.

---

## Required Callbacks

### rdb_load - deserialize from RDB

```c
void *MyType_RdbLoad(ValkeyModuleIO *rdb, int encver) {
    if (encver != 0) return NULL;  // reject unknown versions
    MyData *d = ValkeyModule_Alloc(sizeof(*d));
    d->count = ValkeyModule_LoadUnsigned(rdb);
    d->name = ValkeyModule_LoadString(rdb);
    if (ValkeyModule_IsIOError(rdb)) { ValkeyModule_Free(d); return NULL; }
    return d;
}
```

Enable IO error handling with `ValkeyModule_SetModuleOptions(ctx, VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS)` in `OnLoad`. Without it, load errors crash the server.

### rdb_save - serialize to RDB

```c
void MyType_RdbSave(ValkeyModuleIO *rdb, void *value) {
    MyData *d = value;
    ValkeyModule_SaveUnsigned(rdb, d->count);
    ValkeyModule_SaveString(rdb, d->name);
}
```

### free - release all memory

```c
void MyType_Free(void *value) {
    MyData *d = value;
    ValkeyModule_FreeString(NULL, d->name);
    ValkeyModule_Free(d);
}
```

---

## RDB Serialization Primitives

| Save | Load | Type |
|------|------|------|
| `SaveUnsigned(io, val)` | `LoadUnsigned(io)` | `uint64_t` |
| `SaveSigned(io, val)` | `LoadSigned(io)` | `int64_t` |
| `SaveDouble(io, val)` | `LoadDouble(io)` | `double` |
| `SaveFloat(io, val)` | `LoadFloat(io)` | `float` |
| `SaveLongDouble(io, val)` | `LoadLongDouble(io)` | `long double` |
| `SaveString(io, str)` | `LoadString(io)` | `ValkeyModuleString*` |
| `SaveStringBuffer(io, buf, len)` | `LoadStringBuffer(io, &len)` | raw bytes |

Always check `ValkeyModule_IsIOError(io)` after load operations.

---

## AOF Rewrite

Emit commands that reconstruct the value when the AOF is rewritten:

```c
void MyType_AofRewrite(ValkeyModuleIO *aof, ValkeyModuleString *key, void *value) {
    MyData *d = value;
    ValkeyModule_EmitAOF(aof, "MYMOD.SET", "sls", key, d->count, d->name);
}
```

Format specifiers for `EmitAOF`: `s` (ValkeyModuleString), `c` (C string), `l` (long long), `b` (buffer + length).

The emitted command must be one your module handles. If the value is complex, emit multiple commands or a single bulk-restore command.

---

## Optional Callbacks

Set `version = VALKEYMODULE_TYPE_METHOD_VERSION` to use all available fields. Unset fields default to NULL.

### mem_usage - memory reporting

```c
size_t MyType_MemUsage(const void *value) {
    MyData *d = (MyData *)value;
    size_t name_len;
    ValkeyModule_StringPtrLen(d->name, &name_len);
    return sizeof(*d) + name_len;
}
```

Called by `MEMORY USAGE <key>`. Return the total bytes including nested allocations.

### free_effort - lazy free hint (v3+)

```c
size_t MyType_FreeEffort(ValkeyModuleString *key, const void *value) {
    MyData *d = (MyData *)value;
    return d->num_elements;  // higher = more likely to async-free
}
```

When a key is deleted with `UNLINK` or evicted, Valkey checks if the effort is high enough to justify background freeing.

### unlink - key removed notification (v3+)

```c
void MyType_Unlink(ValkeyModuleString *key, const void *value) {
    // Release external resources, remove from indexes
    // Do NOT free the value itself - free() handles that
}
```

### copy - COPY command support (v3+)

```c
void *MyType_Copy(ValkeyModuleString *fromkey, ValkeyModuleString *tokey, const void *value) {
    MyData *src = (MyData *)value;
    MyData *dst = ValkeyModule_Alloc(sizeof(*dst));
    dst->count = src->count;
    dst->name = ValkeyModule_CreateStringFromString(NULL, src->name);
    return dst;  // NULL on failure
}
```

### defrag - active defragmentation (v3+)

```c
int MyType_Defrag(ValkeyModuleDefragCtx *ctx, ValkeyModuleString *key, void **value) {
    MyData *d = *value;
    MyData *newptr = ValkeyModule_DefragAlloc(d);
    if (newptr) { *value = newptr; d = newptr; }
    // Also defrag nested pointers
    return 0;  // 0 = done, non-zero = more work needed
}
```

### "2" variants (v4+)

`mem_usage2`, `free_effort2`, `unlink2`, `copy2` receive `ValkeyModuleKeyOptCtx*` providing key name and db ID via `GetKeyNameFromOptCtx`/`GetDbIdFromOptCtx`. Prefer these when you need context about which key is being operated on.

---

## Auxiliary Data

For module-global data not attached to any key, set `aux_load`, `aux_save`, and `aux_save_triggers` (`VALKEYMODULE_AUX_BEFORE_RDB`, `VALKEYMODULE_AUX_AFTER_RDB`, or both) in the type methods struct. Callback signatures: `int aux_load(ValkeyModuleIO *rdb, int encver, int when)` and `void aux_save(ValkeyModuleIO *rdb, int when)`.

**aux_save2** (v5+): If the callback writes nothing, no RDB entry is created - the RDB can load without the module present.

---

## Setting Values on Keys

```c
// Open key for writing
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ | VALKEYMODULE_WRITE);

// Check key is empty or already our type
int type = ValkeyModule_KeyType(key);
if (type != VALKEYMODULE_KEYTYPE_EMPTY && type != VALKEYMODULE_KEYTYPE_MODULE)
    return ValkeyModule_ReplyWithError(ctx, VALKEYMODULE_ERRORMSG_WRONGTYPE);
if (type == VALKEYMODULE_KEYTYPE_MODULE && ValkeyModule_ModuleTypeGetType(key) != MyType)
    return ValkeyModule_ReplyWithError(ctx, VALKEYMODULE_ERRORMSG_WRONGTYPE);

// Set or get
ValkeyModule_ModuleTypeSetValue(key, MyType, mydata);
MyData *d = ValkeyModule_ModuleTypeGetValue(key);
```

Replace a value and get the old one back with `ValkeyModule_ModuleTypeReplaceValue(key, MyType, new_val, &old_val)`.

In-memory serialization (no RDB): `SaveDataTypeToString(ctx, data, MyType)` and `LoadDataTypeFromString(str, MyType)`.
