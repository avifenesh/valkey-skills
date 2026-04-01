# LRU/LFU Eviction - SetLRU, GetLRU, SetLFU, GetLFU, mem_usage Callback

Use when controlling how module keys participate in memory eviction - setting idle time for LRU policies, access frequency for LFU policies, or reporting memory usage for maxmemory enforcement.

Source: `src/module.c` (lines 14009-14052), `src/valkeymodule.h` (lines 70, 1360-1361, 1418, 1428, 1888-1891)

## Contents

- [Eviction Policy Context](#eviction-policy-context)
- [ValkeyModule_SetLRU](#valkeymodule_setlru)
- [ValkeyModule_GetLRU](#valkeymodule_getlru)
- [ValkeyModule_SetLFU](#valkeymodule_setlfu)
- [ValkeyModule_GetLFU](#valkeymodule_getlfu)
- [NOTOUCH Flag](#notouch-flag)
- [mem_usage Callback](#mem_usage-callback)
- [mem_usage2 Callback](#mem_usage2-callback)
- [Practical Patterns](#practical-patterns)

---

## Eviction Policy Context

These APIs only matter when `maxmemory-policy` is set to an LRU or LFU variant:

| Policy | Flag | APIs to Use |
|--------|------|-------------|
| `volatile-lru` | `MAXMEMORY_FLAG_LRU` | SetLRU / GetLRU |
| `allkeys-lru` | `MAXMEMORY_FLAG_LRU` | SetLRU / GetLRU |
| `volatile-lfu` | `MAXMEMORY_FLAG_LFU` | SetLFU / GetLFU |
| `allkeys-lfu` | `MAXMEMORY_FLAG_LFU` | SetLFU / GetLFU |
| `volatile-ttl`, `*-random`, `noeviction` | - | Neither (TTL, random, or no eviction) |

Calling SetLRU under an LFU policy (or vice versa) has no effect - the internal `objectSetLRUOrLFU` checks the active policy and ignores mismatched updates.

## ValkeyModule_SetLRU

```c
int ValkeyModule_SetLRU(ValkeyModuleKey *key, mstime_t lru_idle);
```

Sets the last access time for a key using LRU-based eviction. The `lru_idle` value is idle time in milliseconds - how long ago the key was last accessed.

Returns `VALKEYMODULE_OK` if the LRU was updated, `VALKEYMODULE_ERR` if the key has no value. Not relevant when the server's maxmemory policy is LFU-based.

```c
/* Mark a key as accessed 30 seconds ago */
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_WRITE);
ValkeyModule_SetLRU(key, 30000);
ValkeyModule_CloseKey(key);
```

Internally the value is scaled by 1000 (`lru_idle * 1000`) before being passed to `objectSetLRUOrLFU`, which converts it to the LRU clock resolution used by the eviction algorithm. Setting `lru_idle` to 0 marks the key as just accessed. Higher values make the key more likely to be evicted.

## ValkeyModule_GetLRU

```c
int ValkeyModule_GetLRU(ValkeyModuleKey *key, mstime_t *lru_idle);
```

Gets the key idle time in milliseconds. The output parameter `lru_idle` is set to -1 if the server's eviction policy is LFU-based (not an error - the function still returns `VALKEYMODULE_OK`).

Returns `VALKEYMODULE_ERR` only if the key has no value.

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ);
mstime_t idle;
if (ValkeyModule_GetLRU(key, &idle) == VALKEYMODULE_OK) {
    if (idle == -1) {
        /* Server is using LFU policy, idle time not available */
    } else {
        /* idle is in milliseconds */
    }
}
ValkeyModule_CloseKey(key);
```

## ValkeyModule_SetLFU

```c
int ValkeyModule_SetLFU(ValkeyModuleKey *key, long long lfu_freq);
```

Sets the access frequency counter for a key using LFU-based eviction. The `lfu_freq` value is a logarithmic counter (must be <= 255). Only relevant when the server's maxmemory policy is LFU-based.

Returns `VALKEYMODULE_OK` if the LFU was updated, `VALKEYMODULE_ERR` if the key has no value.

```c
/* Set high access frequency to protect a key from eviction */
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_WRITE);
ValkeyModule_SetLFU(key, 255);
ValkeyModule_CloseKey(key);
```

The frequency is logarithmic - a value of 255 represents the highest access frequency. The server decays this counter over time based on `lfu-decay-time`. A value of 0 makes the key an immediate eviction candidate.

## ValkeyModule_GetLFU

```c
int ValkeyModule_GetLFU(ValkeyModuleKey *key, long long *lfu_freq);
```

Gets the key access frequency. The output parameter `lfu_freq` is set to -1 if the server's eviction policy is not LFU-based.

Returns `VALKEYMODULE_ERR` only if the key has no value.

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ);
long long freq;
if (ValkeyModule_GetLFU(key, &freq) == VALKEYMODULE_OK && freq >= 0) {
    /* freq is 0-255 logarithmic counter */
}
ValkeyModule_CloseKey(key);
```

## NOTOUCH Flag

Opening a key with `ValkeyModule_OpenKey` normally updates its LRU/LFU metadata (treating it as an access). Use the `VALKEYMODULE_OPEN_KEY_NOTOUCH` flag to read or inspect a key without affecting eviction:

```c
#define VALKEYMODULE_OPEN_KEY_NOTOUCH (1 << 16)
```

```c
/* Inspect a key without updating its access time */
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname,
    VALKEYMODULE_READ | VALKEYMODULE_OPEN_KEY_NOTOUCH);
mstime_t idle;
ValkeyModule_GetLRU(key, &idle);
ValkeyModule_CloseKey(key);
```

This is important for background maintenance tasks, monitoring commands, or any operation that should not extend a key's life in the eviction pool.

## mem_usage Callback

```c
typedef size_t (*ValkeyModuleTypeMemUsageFunc)(const void *value);
```

Registered in the `ValkeyModuleTypeMethods` struct as the `mem_usage` field. The server calls this to determine how much memory a module key occupies - used for `MEMORY USAGE` command output and for maxmemory eviction decisions.

```c
size_t MyType_MemUsage(const void *value) {
    MyTypeObject *obj = (MyTypeObject *)value;
    size_t bytes = sizeof(*obj);
    bytes += obj->data_len;        /* heap-allocated data */
    bytes += obj->num_entries * sizeof(MyEntry);
    return bytes;
}
```

If this callback is not provided, the server cannot account for your module type's memory in eviction decisions. Keys of your type will still be evictable, but the server will underestimate their memory contribution.

## mem_usage2 Callback

```c
typedef size_t (*ValkeyModuleTypeMemUsageFunc2)(
    ValkeyModuleKeyOptCtx *ctx, const void *value, size_t sample_size);
```

Registered as the `mem_usage2` field (requires `VALKEYMODULE_TYPE_METHOD_VERSION` >= 4). This variant receives a `sample_size` hint for large data structures where exact counting is expensive. When `sample_size` is 0, return an exact count. When non-zero, sample that many elements and extrapolate.

```c
size_t MyType_MemUsage2(ValkeyModuleKeyOptCtx *ctx,
                        const void *value, size_t sample_size) {
    MyTypeObject *obj = (MyTypeObject *)value;
    size_t base = sizeof(*obj);
    if (sample_size == 0 || obj->num_entries <= sample_size) {
        /* Exact count */
        return base + exact_memory_sum(obj);
    }
    /* Sample and extrapolate */
    size_t sampled = sample_entries_memory(obj, sample_size);
    return base + (sampled / sample_size) * obj->num_entries;
}
```

If both `mem_usage` and `mem_usage2` are set, `mem_usage2` takes priority.

## Practical Patterns

**Register mem_usage at type creation** - always provide this callback so eviction and `MEMORY USAGE` work correctly:

```c
ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load = MyType_RdbLoad,
    .rdb_save = MyType_RdbSave,
    .free = MyType_Free,
    .mem_usage = MyType_MemUsage,
};
ValkeyModule_CreateDataType(ctx, "mytype---", 0, &tm);
```

**Protect hot keys from eviction** under LFU - call `ValkeyModule_SetLFU(key, 200)` after writes to boost the frequency counter.

**Background scan without disturbing eviction order** - open keys with `VALKEYMODULE_READ | VALKEYMODULE_OPEN_KEY_NOTOUCH` so inspection does not reset idle time or bump frequency.

## See Also

- [client-info.md](client-info.md) - GetUsedMemoryRatio for memory pressure monitoring
- [scan.md](scan.md) - NOTOUCH flag relevant for background scan operations
- [../data-types/registration.md](../data-types/registration.md) - ValkeyModuleTypeMethods struct and type registration
- [../commands/key-generic.md](../commands/key-generic.md) - Key open modes and generic key operations
- [../defrag.md](../defrag.md) - Active defragmentation for module data types
