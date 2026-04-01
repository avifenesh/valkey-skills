# Key Access API and Blocking Commands

Use when working with the low-level key access API (OpenKey/CloseKey, type inspection, string operations, expiry) or building blocking commands with ValkeyModule_BlockClient.

Source: `src/valkeymodule.h`, `src/module.c` (lines 8053-8672)

## Contents

- Opening and Closing Keys (line 17)
- Key Type Inspection (line 38)
- String Operations on Keys (line 52)
- Expiry (line 61)
- High-Level Command Call (line 72)
- Blocking Commands (line 84)
- Blocking on Keys (line 117)
- Thread-Safe Contexts (line 124)
- See Also (line 131)

---

## Opening and Closing Keys

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

## Key Type Inspection

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

## String Operations on Keys

```c
int ValkeyModule_StringSet(ValkeyModuleKey *key, ValkeyModuleString *str);
char *ValkeyModule_StringDMA(ValkeyModuleKey *key, size_t *len, int mode);  // Direct memory access
int ValkeyModule_StringTruncate(ValkeyModuleKey *key, size_t newlen);
```

## Expiry

```c
mstime_t ValkeyModule_GetExpire(ValkeyModuleKey *key);       // Relative TTL in ms
int ValkeyModule_SetExpire(ValkeyModuleKey *key, mstime_t expire);
mstime_t ValkeyModule_GetAbsExpire(ValkeyModuleKey *key);    // Absolute Unix time ms
int ValkeyModule_SetAbsExpire(ValkeyModuleKey *key, mstime_t expire);
```

`VALKEYMODULE_NO_EXPIRE` (-1) means no expiry.

## High-Level Command Call

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

## Blocking on Keys

`ValkeyModule_BlockClientOnKeys` takes the same parameters plus `keys`, `numkeys`, and `privdata`. The `reply_callback` fires every time a watched key is signaled as ready - check if the key contains what you need and return `VALKEYMODULE_ERR` to keep waiting. Use `ValkeyModule_SignalKeyAsReady(ctx, key)` from write commands on your custom type to wake blocked clients.

## Thread-Safe Contexts

For background threads: `ValkeyModule_GetThreadSafeContext(bc)` returns a context you must lock/unlock with `ThreadSafeContextLock`/`ThreadSafeContextUnlock` and free with `FreeThreadSafeContext`. For detached contexts not tied to a blocked client, use `ValkeyModule_GetDetachedThreadSafeContext`.

---

## See Also

- [custom-types](custom-types.md) - custom data type registration, RDB serialization, type methods
- [module-lifecycle](module-lifecycle.md) - module lifecycle, command registration
