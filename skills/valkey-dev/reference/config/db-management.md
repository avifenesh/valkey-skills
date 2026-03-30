# Database Management

Use when understanding how Valkey stores, retrieves, modifies, and iterates keys across its database layer.

Source: `src/db.c` (3,054 lines)

---

## The serverDb Struct

Each logical database is represented by a `serverDb`:

```c
typedef struct serverDb {
    kvstore *keys;                        /* The keyspace for this DB */
    kvstore *expires;                     /* Timeout of keys with a timeout set */
    kvstore *keys_with_volatile_items;    /* Keys with volatile items (hash field TTL) */
    dict *blocking_keys;                  /* Keys with clients waiting for data (BLPOP) */
    dict *blocking_keys_unblock_on_nokey; /* Keys waiting, unblock if key deleted (XREADGROUP) */
    dict *ready_keys;                     /* Blocked keys that received a PUSH */
    dict *watched_keys;                   /* WATCHED keys for MULTI/EXEC CAS */
    int id;                               /* Database ID */
    struct {
        long long avg_ttl;    /* Average TTL, just for stats */
        unsigned long cursor; /* Cursor of the active expire cycle */
    } expiry[ACTIVE_EXPIRY_TYPE_COUNT];   /* Per-type expiry state: [KEYS, FIELDS] */
} serverDb;
```

The server maintains `server.db[]` - an array of `serverDb*` pointers, sized by the `databases` config (default 16). Databases are **lazily allocated** via `createDatabaseIfNeeded()` - unused databases remain NULL.

The three kvstore members use the same key (the SDS key string) but serve different purposes:
- `keys` - maps key names to `robj` value objects (the main keyspace)
- `expires` - subset of `keys` that have a TTL set; same `robj` pointers, indexed by key name
- `keys_with_volatile_items` - subset of `keys` that are hashes with field-level TTLs (Valkey-specific)

In cluster mode, each kvstore is partitioned into 16,384 hashtables (one per slot). In standalone mode, there is a single hashtable per kvstore (slot 0).

## Key-Value Slot Mapping

```c
int getKVStoreIndexForKey(sds key) {
    return server.cluster_enabled ? getKeySlot(key) : 0;
}
```

Every key operation first computes a `dict_index` - the kvstore hashtable index. In standalone mode this is always 0. In cluster mode it is the CRC16 hash slot, often cached on the client to avoid recomputation.

## Key Lookup

```c
robj *lookupKey(serverDb *db, robj *key, int flags);
```

The central lookup function. Side effects on a successful lookup:

1. Checks expiration via `expireIfNeededWithDictIndex()` - may delete the key
2. Updates the LRU/LFU access time (unless `LOOKUP_NOTOUCH` or child process active)
3. Increments `server.stat_keyspace_hits` (unless `LOOKUP_NOSTATS`)

On a miss:
1. Fires a `keymiss` keyspace notification (unless `LOOKUP_NONOTIFY`)
2. Increments `server.stat_keyspace_misses`

Lookup flags:

| Flag | Effect |
|------|--------|
| `LOOKUP_NONE` | Default behavior |
| `LOOKUP_NOTOUCH` | Skip LRU/LFU update |
| `LOOKUP_NONOTIFY` | Skip keymiss notification |
| `LOOKUP_NOSTATS` | Skip hits/misses counters |
| `LOOKUP_WRITE` | Force-delete expired keys even on replicas |
| `LOOKUP_NOEXPIRE` | Check expiry but do not delete |

Convenience wrappers:

```c
robj *lookupKeyRead(serverDb *db, robj *key);           /* LOOKUP_NONE */
robj *lookupKeyWrite(serverDb *db, robj *key);           /* LOOKUP_WRITE */
robj *lookupKeyReadOrReply(client *c, robj *key, robj *reply);  /* Reply on miss */
robj *lookupKeyWriteOrReply(client *c, robj *key, robj *reply);
```

## Key Storage: dbAdd, dbOverwrite, setKey

### dbAdd

```c
void dbAdd(serverDb *db, robj *key, robj **valref);
```

Adds a new key. Aborts if the key already exists. Internally calls `dbAddInternal()` which:

1. Converts the value to a full valkey object with key and expire metadata via `objectSetKeyAndExpire(val, key, -1)`
2. Tracks volatile hash fields via `dbTrackKeyWithVolatileItems()`
3. Initializes LRU/LFU via `initObjectLRUOrLFU()`
4. Inserts into `db->keys` kvstore
5. Fires `signalKeyAsReady()` (for blocked clients) and `new` keyspace notification

Note: the `valref` pointer may be updated - the value can be reallocated during insertion. The caller must not hold stale pointers.

### dbSetValue (overwrite)

```c
static void dbSetValue(serverDb *db, robj *key, robj **valref, int overwrite, void **oldref);
```

Replaces the value of an existing key. When `overwrite=1`, it:

1. Notifies modules of the unlink
2. Signals blocked clients of the deleted type
3. Performs an optimized in-place swap when both old and new values have `refcount==1` and non-EMBSTR encoding - swaps type, encoding, and ptr fields without reallocation
4. Otherwise, creates a new object preserving the old key name, expire, and LRU
5. Updates `db->expires` pointer if key has a TTL
6. Manages volatile items tracking for hash objects

### setKey (high-level)

```c
void setKey(client *c, serverDb *db, robj *key, robj **valref, int flags);
```

The primary interface for all key writes. Behavior:

1. Determines if key exists (unless caller passes `SETKEY_ALREADY_EXIST` or `SETKEY_DOESNT_EXIST`)
2. Calls `dbAdd()` for new keys or `dbSetValue()` for existing
3. Removes expire unless `SETKEY_KEEPTTL`
4. Signals modified key unless `SETKEY_NO_SIGNAL`

The `SETKEY_ADD_OR_UPDATE` flag uses `dbAddInternal(db, key, valref, 1)` which tries to add but falls back to overwrite.

## Key Deletion

```c
int dbDelete(serverDb *db, robj *key);       /* sync or async per lazyfree config */
int dbSyncDelete(serverDb *db, robj *key);   /* always synchronous */
int dbAsyncDelete(serverDb *db, robj *key);  /* always asynchronous */
```

All call `dbGenericDelete()` which:

1. Finds the entry in `db->keys` using two-phase pop (find ref, then delete)
2. Notifies modules and signals blocked clients
3. Removes from `db->expires` if the key has a TTL
4. Untracks volatile hash items
5. Frees the object (sync or async depending on parameter)

Returns 1 if key was deleted, 0 if not found.

## Database Selection

```c
int selectDb(client *c, int id);
```

Sets `c->db` to the database at the given index. Returns `C_ERR` if out of range. Calls `createDatabaseIfNeeded(id)` to lazily allocate the database if it has never been used.

```c
void selectCommand(client *c);  /* SELECT command */
```

Parses the integer argument, calls `selectDb()`. If the client is in a MULTI transaction, records the DB switch in the transaction state.

## RANDOMKEY

```c
robj *dbRandomKey(serverDb *db);
```

Uses `kvstoreGetFairRandomHashtableIndex()` to pick a random slot, then `kvstoreHashtableFairRandomEntry()` for a random entry. Skips expired keys (checking with `objectIsExpired()` and calling `expireIfNeeded()` for actual deletion). Has a safety valve: if all keys are volatile and we are a replica (where expiry is primary-driven), stops after 100 attempts to avoid infinite loops.

## DBSIZE

```c
void dbsizeCommand(client *c);
```

Returns `kvstoreSize(c->db->keys)` - the total number of keys in the selected database.

## SCAN Implementation

```c
void scanGenericCommand(client *c, robj *o, unsigned long long cursor,
                        int slot, sds cursor_prefix, sds finished_cursor_prefix);
```

Implements SCAN, HSCAN, SSCAN, ZSCAN, and CLUSTERSCAN. The algorithm:

### Step 1: Parse Options

- `COUNT n` - hint for how many elements to return (default 10)
- `MATCH pattern` - glob pattern filter
- `TYPE typename` - filter by value type (SCAN only, not sub-commands)
- `NOVALUES` - return only keys (HSCAN only)
- `NOSCORES` - return only members (ZSCAN only)

### Step 2: Iterate

For kvstore or hashtable-backed data structures, the scan loop:

```c
do {
    if (o == NULL) {
        cursor = kvstoreScan(c->db->keys, cursor, onlydidx, keysScanCallback, NULL, &data);
    } else {
        cursor = hashtableScan(ht, cursor, hashtableScanCallback, &data);
    }
} while (cursor && maxiterations-- && data.sampled < count);
```

- `maxiterations` is `count * 10` to prevent blocking on sparse hashtables
- For cluster mode, if the pattern maps to a single slot, only that slot is scanned
- The `keysScanCallback` filters by type, pattern, and expiration status
- For listpack/intset-encoded data structures (small collections), the entire collection is returned in one call with cursor set to 0

### Step 3: Reply

Returns a two-element array: `[next_cursor, [elements...]]`. A cursor of `"0"` signals completion.

## Database Flushing

### FLUSHDB

```c
void flushdbCommand(client *c);
```

Flushes the currently selected database. Accepts `SYNC` or `ASYNC` argument. Without arguments, uses `lazyfree-lazy-user-flush` config to decide. Calls `emptyData(c->db->id, flags | EMPTYDB_NOFUNCTIONS, NULL)`.

### FLUSHALL

```c
void flushallCommand(client *c);
```

Flushes all databases. Calls `flushAllDataAndResetRDB()` which:

1. Empties all databases via `emptyData(-1, flags, NULL)`
2. Kills any running RDB child or slot migration child
3. Triggers a new RDB save if save params are configured

### emptyData / emptyDbStructure

```c
long long emptyData(int dbnum, int flags, void(callback)(hashtable *));
long long emptyDbStructure(serverDb **dbarray, int dbnum, int async, void(callback)(hashtable *));
```

`emptyData()` is the core flush implementation:

1. Fires `VALKEYMODULE_EVENT_FLUSHDB` start event
2. Signals all WATCH keys as modified (invalidates transactions)
3. Cancels in-progress slot migrations if any
4. Empties all three kvstores (`keys`, `expires`, `keys_with_volatile_items`) per database - synchronously or asynchronously
5. Resets expiry state (avg_ttl, cursors)
6. Flushes replica keys with expire list (for FLUSHALL)
7. Optionally resets functions
8. Fires end event

## Key Space Change Hooks

```c
void signalModifiedKey(client *c, serverDb *db, robj *key);
```

Called after every key modification. Triggers:
- `touchWatchedKey()` - invalidates MULTI/EXEC transactions watching this key
- `trackingInvalidateKey()` - sends invalidation messages to client-side caching subscribers

```c
void signalFlushedDb(int dbid, int async);
```

Called on FLUSHDB/FLUSHALL. Invalidates all watched keys and tracking for the flushed databases.

---

## See Also

- [kvstore](../valkey-specific/kvstore.md) - the slot-partitioned hash table structure underlying `db->keys`, `db->expires`, and `db->keys_with_volatile_items`
- [Lazy Freeing](../memory/lazy-free.md) - `dbAsyncDelete()` and `emptyDbAsync()` submit background free jobs for large keys and full database flushes
- [Key Expiration](../config/expiry.md) - lazy and active expiration strategies that call `deleteExpiredKeyAndPropagate()` through the database layer
- [Client Tracking](../monitoring/tracking.md) - `signalModifiedKey()` triggers `trackingInvalidateKey()` for server-assisted client-side caching
- [MULTI/EXEC Transactions](../transactions/multi-exec.md) - `touchWatchedKey()` called from `signalModifiedKey()` to invalidate optimistic locks
- [Batch Key Prefetching](../threading/prefetch.md) - prefetches `lookupKey()` hashtable accesses to reduce cache miss stalls
