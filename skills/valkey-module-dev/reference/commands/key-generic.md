# Key Generic Operations - OpenKey, KeyType, Expire, Delete

Use when opening keys for reading or writing, checking key types, managing TTL/expiry, or performing generic key operations.

Source: `src/module.c` (lines 3779-4500), `src/valkeymodule.h`

## Contents

- [Opening and Closing Keys](#opening-and-closing-keys) (line 18)
- [Open Key Modes](#open-key-modes) (line 43)
- [Key Type and Length](#key-type-and-length) (line 66)
- [Delete and Unlink](#delete-and-unlink) (line 97)
- [Expiry Management](#expiry-management) (line 111)
- [Database Operations](#database-operations) (line 143)

---

## Opening and Closing Keys

```c
ValkeyModuleKey *ValkeyModule_OpenKey(ValkeyModuleCtx *ctx,
                                      ValkeyModuleString *keyname, int mode);
void ValkeyModule_CloseKey(ValkeyModuleKey *key);
int ValkeyModule_KeyExists(ValkeyModuleCtx *ctx, ValkeyModuleString *keyname);
```

`OpenKey` returns a handle for key operations. Behavior varies by mode:

- **Read-only** (`VALKEYMODULE_READ`): Returns `NULL` if the key does not exist
- **Write** (`VALKEYMODULE_WRITE`): Always returns a handle, even for non-existent keys (they get created on first write)

`CloseKey` is safe to call on NULL. With automatic memory, keys are closed at callback end, but explicit close is recommended for write keys to trigger notifications.

`KeyExists` checks existence without affecting LRU/LFU. Equivalent to opening with `READ | NOTOUCH` and checking for NULL.

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1],
    VALKEYMODULE_READ | VALKEYMODULE_WRITE);
/* ... operations ... */
ValkeyModule_CloseKey(key);
```

## Open Key Modes

Combine with bitwise OR:

| Flag | Value | Effect |
|------|-------|--------|
| `VALKEYMODULE_READ` | `1<<0` | Open for reading |
| `VALKEYMODULE_WRITE` | `1<<1` | Open for writing |
| `VALKEYMODULE_OPEN_KEY_NOTOUCH` | `1<<16` | Don't update LRU/LFU |
| `VALKEYMODULE_OPEN_KEY_NONOTIFY` | `1<<17` | Don't trigger keyspace event on miss |
| `VALKEYMODULE_OPEN_KEY_NOSTATS` | `1<<18` | Don't update hits/misses counters |
| `VALKEYMODULE_OPEN_KEY_NOEXPIRE` | `1<<19` | Don't delete lazy-expired keys |
| `VALKEYMODULE_OPEN_KEY_NOEFFECTS` | `1<<20` | No side effects from fetching |

Check supported modes at runtime:

```c
int supported = ValkeyModule_GetOpenKeyModesAll();
if (supported & VALKEYMODULE_OPEN_KEY_NOTOUCH) {
    /* NOTOUCH is supported */
}
```

## Key Type and Length

```c
int ValkeyModule_KeyType(ValkeyModuleKey *key);
size_t ValkeyModule_ValueLength(ValkeyModuleKey *key);
```

`KeyType` returns one of:

| Constant | Value |
|----------|-------|
| `VALKEYMODULE_KEYTYPE_EMPTY` | 0 |
| `VALKEYMODULE_KEYTYPE_STRING` | 1 |
| `VALKEYMODULE_KEYTYPE_LIST` | 2 |
| `VALKEYMODULE_KEYTYPE_HASH` | 3 |
| `VALKEYMODULE_KEYTYPE_SET` | 4 |
| `VALKEYMODULE_KEYTYPE_ZSET` | 5 |
| `VALKEYMODULE_KEYTYPE_MODULE` | 6 |
| `VALKEYMODULE_KEYTYPE_STREAM` | 7 |

Both are safe to call on NULL keys (returns `EMPTY` / 0).

`ValueLength` returns: string byte length, list/set/zset/stream element count, or hash field count.

```c
if (ValkeyModule_KeyType(key) != VALKEYMODULE_KEYTYPE_STRING) {
    ValkeyModule_CloseKey(key);
    return ValkeyModule_ReplyWithError(ctx, VALKEYMODULE_ERRORMSG_WRONGTYPE);
}
```

## Delete and Unlink

```c
int ValkeyModule_DeleteKey(ValkeyModuleKey *key);
int ValkeyModule_UnlinkKey(ValkeyModuleKey *key);
```

Both require `VALKEYMODULE_WRITE` mode. After deletion, the key handle remains valid and accepts new writes (key is recreated on demand).

- `DeleteKey` - synchronous, reclaims memory immediately
- `UnlinkKey` - asynchronous, reclaims memory in background (non-blocking)

Returns `VALKEYMODULE_ERR` if the key is not open for writing.

## Expiry Management

```c
/* Relative TTL (milliseconds remaining) */
mstime_t ValkeyModule_GetExpire(ValkeyModuleKey *key);
int ValkeyModule_SetExpire(ValkeyModuleKey *key, mstime_t expire);

/* Absolute Unix timestamp (milliseconds) */
mstime_t ValkeyModule_GetAbsExpire(ValkeyModuleKey *key);
int ValkeyModule_SetAbsExpire(ValkeyModuleKey *key, mstime_t expire);
```

Special value `VALKEYMODULE_NO_EXPIRE` (-1):
- Returned by `GetExpire`/`GetAbsExpire` when no TTL is set or key is empty
- Pass to `SetExpire`/`SetAbsExpire` to remove TTL (like PERSIST command)

`SetExpire` and `SetAbsExpire` return `VALKEYMODULE_ERR` if the key is not open for writing or is empty.

```c
/* Set 60-second TTL */
ValkeyModule_SetExpire(key, 60000);

/* Remove TTL */
ValkeyModule_SetExpire(key, VALKEYMODULE_NO_EXPIRE);

/* Check remaining TTL */
mstime_t ttl = ValkeyModule_GetExpire(key);
if (ttl == VALKEYMODULE_NO_EXPIRE) {
    /* No expiry set */
}
```

## Database Operations

```c
int ValkeyModule_GetSelectedDb(ValkeyModuleCtx *ctx);
int ValkeyModule_SelectDb(ValkeyModuleCtx *ctx, int newid);
unsigned long long ValkeyModule_DbSize(ValkeyModuleCtx *ctx);
ValkeyModuleString *ValkeyModule_RandomKey(ValkeyModuleCtx *ctx);
```

`SelectDb` changes the current DB. The client retains the selected DB after the command returns. Save and restore the DB if you only need temporary access:

```c
int olddb = ValkeyModule_GetSelectedDb(ctx);
ValkeyModule_SelectDb(ctx, 1);
/* ... work in DB 1 ... */
ValkeyModule_SelectDb(ctx, olddb);
```

`RandomKey` returns a random key name from the current DB, or NULL if empty. The string is auto-managed.

Key name and DB ID from a `ValkeyModuleKey` handle:

```c
const ValkeyModuleString *ValkeyModule_GetKeyNameFromModuleKey(ValkeyModuleKey *key);
int ValkeyModule_GetDbIdFromModuleKey(ValkeyModuleKey *key);
```

`GetKeyNameFromModuleKey` returns the key name as a `ValkeyModuleString`, or NULL if `key` is NULL. `GetDbIdFromModuleKey` returns the database ID, or -1 if `key` is NULL. Use these to inspect a key handle obtained from `OpenKey`.

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_READ);
const ValkeyModuleString *name = ValkeyModule_GetKeyNameFromModuleKey(key);
int dbid = ValkeyModule_GetDbIdFromModuleKey(key);
```

Key context helpers (for module type callbacks like `copy` or `defrag`):

```c
const ValkeyModuleString *ValkeyModule_GetKeyNameFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
const ValkeyModuleString *ValkeyModule_GetToKeyNameFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
int ValkeyModule_GetDbIdFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
int ValkeyModule_GetToDbIdFromOptCtx(ValkeyModuleKeyOptCtx *ctx);
```
