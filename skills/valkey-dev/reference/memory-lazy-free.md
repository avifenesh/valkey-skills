# Lazy Freeing

Use when you need to understand how Valkey avoids blocking the main thread
when deleting large objects, or when investigating UNLINK vs DEL behavior.

Source: `src/lazyfree.c`

## Contents

- Why Lazy Freeing Exists (line 22)
- Threshold Decision: LAZYFREE_THRESHOLD (line 38)
- Free Effort Estimation (line 50)
- Core Functions (line 89)
- Background Free Callbacks (line 145)
- Statistics (line 173)
- Configuration Options (line 189)
- Integration with BIO (line 208)

---

## Why Lazy Freeing Exists

Deleting a key that holds millions of elements (a large hash, sorted set, or
list) requires freeing millions of individual allocations. If done synchronously
in the main thread, this blocks all clients for the duration. Lazy freeing
moves the deallocation work to a background BIO thread.

The user-facing distinction:
- `DEL key` - synchronous free, blocks until complete
- `UNLINK key` - removes the key from the keyspace synchronously, then queues
  the value for background deallocation
- `FLUSHDB ASYNC` / `FLUSHALL ASYNC` - replaces the entire database structure
  and queues the old one for background free

---

## Threshold Decision: LAZYFREE_THRESHOLD

Not every deletion is worth offloading to a background thread. For small
objects, the overhead of creating a BIO job exceeds the cost of freeing inline.
The threshold is 64 elements:

```c
#define LAZYFREE_THRESHOLD 64
```

---

## Free Effort Estimation

Before deciding sync vs async, `lazyfreeGetFreeEffort()` estimates the cost of
freeing an object. It returns a number proportional to the number of internal
allocations:

```c
size_t lazyfreeGetFreeEffort(robj *key, robj *obj, int dbid) {
    if (obj->type == OBJ_LIST && obj->encoding == OBJ_ENCODING_QUICKLIST) {
        quicklist *ql = objectGetVal(obj);
        return ql->len;
    } else if (obj->type == OBJ_SET && obj->encoding == OBJ_ENCODING_HASHTABLE) {
        hashtable *ht = objectGetVal(obj);
        return hashtableSize(ht);
    } else if (obj->type == OBJ_ZSET && obj->encoding == OBJ_ENCODING_SKIPLIST) {
        zset *zs = objectGetVal(obj);
        return zslGetLength(zs->zsl);
    } else if (obj->type == OBJ_HASH && obj->encoding == OBJ_ENCODING_HASHTABLE) {
        hashtable *ht = objectGetVal(obj);
        return hashtableSize(ht);
    } else if (obj->type == OBJ_STREAM) {
        // Counts rax nodes + consumer groups * PEL size
        ...
    } else if (obj->type == OBJ_MODULE) {
        size_t effort = moduleGetFreeEffort(key, obj, dbid);
        return effort == 0 ? ULONG_MAX : effort;
    } else {
        return 1; // Single allocation (small string, intset, listpack, etc.)
    }
}
```

Compact encodings (listpack, intset, embstr) are always a single allocation
and return effort 1 - they are freed synchronously. Only large hashtable-backed,
skiplist-backed, quicklist, or stream objects with many nodes cross the
threshold.

---

## Core Functions

### freeObjAsync - Single Key Async Delete

```c
void freeObjAsync(robj *key, robj *obj, int dbid) {
    size_t free_effort = lazyfreeGetFreeEffort(key, obj, dbid);
    if (free_effort > LAZYFREE_THRESHOLD && obj->refcount == 1) {
        atomic_fetch_add_explicit(&lazyfree_objects, 1, memory_order_relaxed);
        bioCreateLazyFreeJob(lazyfreeFreeObject, 1, obj);
    } else {
        decrRefCount(obj);
    }
}
```

This is the entry point for `UNLINK` and `dbAsyncDelete`. If the effort exceeds
64 and the object has no other references, it is submitted to the BIO lazy-free
thread. Otherwise, it is freed synchronously via `decrRefCount()`.

### emptyDbAsync - Async Database Flush

```c
void emptyDbAsync(serverDb *db) {
    kvstore *oldkeys = db->keys, *oldexpires = db->expires,
            *oldkeyswithexpires = db->keys_with_volatile_items;
    db->keys = kvstoreCreate(...);
    db->expires = kvstoreCreate(...);
    db->keys_with_volatile_items = kvstoreCreate(...);
    atomic_fetch_add_explicit(&lazyfree_objects, kvstoreSize(oldkeys), ...);
    bioCreateLazyFreeJob(lazyfreeFreeDatabase, 3, oldkeys, oldexpires,
                         oldkeyswithexpires);
}
```

Replaces the database's kvstores with fresh empty ones. The old kvstores
(potentially containing millions of keys) are freed in the background. The main
thread returns immediately.

### Other Async Free Functions

All follow the same pattern: check size against `LAZYFREE_THRESHOLD`, submit a
BIO job if large, free synchronously if small.

| Function | What it frees |
|----------|--------------|
| `freeTrackingRadixTreeAsync()` | Client tracking radix tree |
| `freeErrorsRadixTreeAsync()` | Error stats radix tree |
| `freeEvalScriptsAsync()` | Lua eval scripts dict + LRU list |
| `freeFunctionsAsync()` | Functions library context |
| `freeReplicationBacklogRefMemAsync()` | Replication backlog blocks + index |
| `freeReplicaKeysWithExpireAsync()` | Replica keys-with-expire dict |
| `freePendingReplDataBufAsync()` | Pending replication data blocks |

---

## Background Free Callbacks

When the BIO thread picks up a lazy-free job, it calls the registered callback.
Each callback does the actual freeing and updates the atomic counters:

```c
void lazyfreeFreeObject(void *args[]) {
    robj *o = (robj *)args[0];
    decrRefCount(o);
    atomic_fetch_sub_explicit(&lazyfree_objects, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&lazyfreed_objects, 1, memory_order_relaxed);
}

void lazyfreeFreeDatabase(void *args[]) {
    kvstore *da1 = args[0];
    kvstore *da2 = args[1];
    kvstore *da3 = args[2];
    size_t numkeys = kvstoreSize(da1);
    kvstoreRelease(da1);
    kvstoreRelease(da2);
    kvstoreRelease(da3);
    atomic_fetch_sub_explicit(&lazyfree_objects, numkeys, ...);
    atomic_fetch_add_explicit(&lazyfreed_objects, numkeys, ...);
}
```

---

## Statistics

Two atomic counters track lazy-free progress:

```c
static _Atomic size_t lazyfree_objects = 0;   // Currently pending
static _Atomic size_t lazyfreed_objects = 0;  // Total freed since last reset
```

Exposed via:
- `lazyfreeGetPendingObjectsCount()` - reported in `INFO stats` as
  `lazyfree_pending_objects`
- `lazyfreeGetFreedObjectsCount()` - reported as `lazyfreed_objects`

---

## Configuration Options

These server config options control when Valkey uses lazy freeing
automatically (without the user specifying `ASYNC`):

| Config | Default | Effect |
|--------|---------|--------|
| `lazyfree-lazy-eviction` | yes | Lazy-free on maxmemory eviction |
| `lazyfree-lazy-expire` | yes | Lazy-free on key expiration |
| `lazyfree-lazy-server-del` | yes | Lazy-free on implicit deletes (e.g. RENAME target) |
| `lazyfree-lazy-user-del` | yes | Make DEL behave like UNLINK |
| `lazyfree-lazy-user-flush` | yes | Make FLUSHDB/FLUSHALL behave as ASYNC |

When any of these are enabled, the corresponding code path calls
`freeObjAsync()` instead of `decrRefCount()`, letting the threshold logic
decide whether to actually defer the free.

---

## Integration with BIO

Lazy-free jobs are submitted via `bioCreateLazyFreeJob()`, which allocates a
`bio_job` with a variable-length args array and submits it to the
`BIO_LAZY_FREE` queue. The BIO thread for lazy-free (worker index 2) processes
jobs sequentially, calling `job->free_args.free_fn(job->free_args.free_args)`.

---
