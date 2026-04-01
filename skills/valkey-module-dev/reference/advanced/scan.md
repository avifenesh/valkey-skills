# Scan API - Keyspace and Key Element Scanning

Use when iterating over all keys in the database or scanning elements within a hash, set, or sorted set from module code.

Source: `src/module.c` (lines 11454-11734), `src/valkeymodule.h`

## Contents

- [Scan Cursor](#scan-cursor)
- [Keyspace Scan](#keyspace-scan)
- [Key Element Scan](#key-element-scan)
- [Thread-Safe Scanning](#thread-safe-scanning)
- [Safety and Guarantees](#safety-and-guarantees)

---

## Scan Cursor

```c
ValkeyModuleScanCursor *ValkeyModule_ScanCursorCreate(void);
void ValkeyModule_ScanCursorRestart(ValkeyModuleScanCursor *cursor);
void ValkeyModule_ScanCursorDestroy(ValkeyModuleScanCursor *cursor);
```

Create a cursor before scanning, destroy it when done. `Restart` resets the cursor to rescan from the beginning without reallocating.

## Keyspace Scan

```c
int ValkeyModule_Scan(ValkeyModuleCtx *ctx,
                      ValkeyModuleScanCursor *cursor,
                      ValkeyModuleScanCB fn,
                      void *privdata);
```

Scans all keys in the current database. Returns 1 if more elements remain, 0 when complete. On error, sets errno (`ENOENT` if cursor is already done).

Callback signature:

```c
void scan_callback(ValkeyModuleCtx *ctx,
                   ValkeyModuleString *keyname,
                   ValkeyModuleKey *key,
                   void *privdata);
```

- `keyname` - the key name, owned by the caller. Retain (copy) if needed after the callback returns
- `key` - a read-only key handle provided as best effort. May be NULL in some cases. If NULL, use `ValkeyModule_OpenKey` to access the key. Owned by the caller and freed after callback returns
- `privdata` - user data passed to `ValkeyModule_Scan`

Basic usage:

```c
void my_scan_cb(ValkeyModuleCtx *ctx, ValkeyModuleString *keyname,
                ValkeyModuleKey *key, void *privdata) {
    const char *name = ValkeyModule_StringPtrLen(keyname, NULL);
    /* Process each key */
}

ValkeyModuleScanCursor *cursor = ValkeyModule_ScanCursorCreate();
while (ValkeyModule_Scan(ctx, cursor, my_scan_cb, NULL))
    ;
ValkeyModule_ScanCursorDestroy(cursor);
```

## Key Element Scan

```c
int ValkeyModule_ScanKey(ValkeyModuleKey *key,
                         ValkeyModuleScanCursor *cursor,
                         ValkeyModuleScanKeyCB fn,
                         void *privdata);
```

Scans elements within a hash, set, or sorted set. The key must be opened with `ValkeyModule_OpenKey` first. Returns 1 if more elements remain, 0 when complete.

Sets errno to `EINVAL` if the key is NULL, has no value, or has an unsupported type. Sets `ENOENT` if the cursor is already done.

Callback signature:

```c
void scan_key_callback(ValkeyModuleKey *key,
                       ValkeyModuleString *field,
                       ValkeyModuleString *value,
                       void *privdata);
```

- `field` - field name (or set member). Owned by caller, retain if needed
- `value` - field value for hashes, score string for sorted sets, NULL for sets. Owned by caller

Supported types and their field/value semantics:

| Type | Field | Value |
|------|-------|-------|
| Hash | Field name | Field value |
| Set | Member | NULL |
| Sorted Set | Member | Score (as string) |

```c
void hash_scan_cb(ValkeyModuleKey *key, ValkeyModuleString *field,
                  ValkeyModuleString *value, void *privdata) {
    const char *f = ValkeyModule_StringPtrLen(field, NULL);
    const char *v = ValkeyModule_StringPtrLen(value, NULL);
    /* Process field-value pair */
}

ValkeyModuleScanCursor *cursor = ValkeyModule_ScanCursorCreate();
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ);
while (ValkeyModule_ScanKey(key, cursor, hash_scan_cb, NULL))
    ;
ValkeyModule_CloseKey(key);
ValkeyModule_ScanCursorDestroy(cursor);
```

## Thread-Safe Scanning

Both `Scan` and `ScanKey` can be used from background threads with the GIL locked during each call. This allows interleaving scans with background processing:

```c
/* Keyspace scan from background thread */
ValkeyModuleScanCursor *cursor = ValkeyModule_ScanCursorCreate();
ValkeyModule_ThreadSafeContextLock(ctx);
while (ValkeyModule_Scan(ctx, cursor, my_scan_cb, privdata)) {
    ValkeyModule_ThreadSafeContextUnlock(ctx);
    /* Do background work between batches */
    ValkeyModule_ThreadSafeContextLock(ctx);
}
ValkeyModule_ThreadSafeContextUnlock(ctx);
ValkeyModule_ScanCursorDestroy(cursor);
```

For `ScanKey` from a thread, re-open the key after each lock acquisition since the key handle is invalidated when the lock is released:

```c
ValkeyModuleScanCursor *cursor = ValkeyModule_ScanCursorCreate();
ValkeyModule_ThreadSafeContextLock(ctx);
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ);
while (ValkeyModule_ScanKey(key, cursor, my_cb, privdata)) {
    ValkeyModule_CloseKey(key);
    ValkeyModule_ThreadSafeContextUnlock(ctx);
    /* Background work */
    ValkeyModule_ThreadSafeContextLock(ctx);
    key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ);
}
ValkeyModule_CloseKey(key);
ValkeyModule_ThreadSafeContextUnlock(ctx);
ValkeyModule_ScanCursorDestroy(cursor);
```

## Safety and Guarantees

The scan API provides the same guarantees as the `SCAN` family of commands:

- Every key that exists from start to end of the scan is reported at least once
- Duplicates may occur, especially if the keyspace is modified during scanning
- No ordering guarantee

Safe operations during scanning:

- Deleting or modifying the current key
- Reading any key

Unsafe operations during scanning:

- Deleting keys other than the current one (may cause missed keys)
- Heavy keyspace modifications (increases duplicate reports)

A safe pattern for batch modifications is to collect key names during the scan and process them after iteration completes. For memory-constrained scenarios, operating on the current key during the callback is safe.

For compact-encoded data types (listpack-encoded hashes and sorted sets, listpack-encoded or setlistpack-encoded sets), the scan iterates all elements in one call and returns 0. For hashtable-backed encodings, it uses incremental cursor-based scanning.

## See Also

- [dictionary.md](dictionary.md) - Module-private dictionary with similar iteration patterns
- [threading.md](threading.md) - Thread-safe scanning with GIL lock/unlock interleaving
- [../data-types/registration.md](../data-types/registration.md) - Custom data types and key access
- [calling-commands.md](calling-commands.md) - Alternative: call SCAN/HSCAN via ValkeyModule_Call
