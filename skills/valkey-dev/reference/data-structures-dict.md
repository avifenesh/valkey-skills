# Dict - Legacy Chained Hash Table

Use when working with code that still uses the dict API - primarily Lua scripting, sentinel, cluster legacy, pub/sub, latency tracking, and some configuration internals. New code should use `hashtable.c` instead.

Source: `src/dict.c`, `src/dict.h`

## Contents

- Overview (line 20)
- Core Structs (line 24)
- Incremental Rehashing (line 100)
- Key API (line 123)
- Utility Macros (line 183)
- Where Dict Is Still Used (post-8.1) (line 192)
- Hash Function (line 209)

---

## Overview

The legacy `dict` is a chained hash table with power-of-two sizing and incremental rehashing. It was the original hash table implementation in Redis/Valkey, used for everything from the main keyspace to internal indexes. Starting in Valkey 8.1, the new open-addressing `hashtable` replaced `dict` for the main key-value store and for Hash, Set, and Sorted Set backing structures.

## Core Structs

### dictEntry (opaque, defined in dict.c)

```c
struct dictEntry {
    void *key;
    union {
        void *val;
        uint64_t u64;
        int64_t s64;
        double d;
    } v;
    struct dictEntry *next; /* Next entry in the same hash bucket. */
};
```

Each entry is a separately allocated 24-byte struct (on 64-bit) containing the key pointer, a value union, and a next pointer for chaining. This is the primary source of memory overhead compared to the new hashtable.

### dict

```c
struct dict {
    dictType *type;

    dictEntry **ht_table[2];
    unsigned long ht_used[2];

    long rehashidx; /* rehashing not in progress if rehashidx == -1 */

    int16_t pauserehash;
    signed char ht_size_exp[2]; /* exponent of size. (size = 1<<exp) */
    int16_t pauseAutoResize;
    void *metadata[];
};
```

| Field | Purpose |
|-------|---------|
| `ht_table[2]` | Two hash tables - [0] is main, [1] is rehash target |
| `ht_used[2]` | Number of entries in each table |
| `ht_size_exp[2]` | Exponent (num_buckets = 1 << exp) |
| `rehashidx` | Current rehash bucket index, -1 if idle |
| `pauserehash` | Counter to pause rehashing (e.g., during iteration) |
| `pauseAutoResize` | Counter to pause automatic resize |

### dictType (callbacks)

```c
typedef struct dictType {
    uint64_t (*hashFunction)(const void *key);
    void *(*keyDup)(const void *key);
    int (*keyCompare)(const void *key1, const void *key2);
    void (*keyDestructor)(void *key);
    void (*valDestructor)(void *obj);
    int (*resizeAllowed)(size_t moreMem, double usedRatio);
    void (*rehashingStarted)(dict *d);
    void (*rehashingCompleted)(dict *d);
    size_t (*dictMetadataBytes)(dict *d);
} dictType;
```

### dictIterator

```c
typedef struct dictIterator {
    dict *d;
    long index;
    int table, safe;
    dictEntry *entry, *nextEntry;
    unsigned long long fingerprint;
} dictIterator;
```

Safe iterators allow mutations during iteration. Unsafe iterators use a fingerprint to detect misuse (mutations while iterating).

## Incremental Rehashing

When the load factor exceeds the threshold, a second table is allocated at double the size. Entries migrate one bucket at a time:

1. `dictRehash(d, n)` moves entries from `n` buckets of `ht_table[0]` to `ht_table[1]`
2. Each regular operation (find, add, delete) calls `dictRehashStep()` which does `dictRehash(d, 1)` if not paused
3. `serverCron` calls `dictRehashMicroseconds()` to do timed bursts
4. When `ht_used[0]` reaches 0, table[0] is freed and table[1] becomes table[0]

During rehashing:
- Lookups check both tables (table[0] first, then table[1])
- New inserts go directly to table[1]
- The resize policy can be set to AVOID during fork (copy-on-write protection)

### Resize Thresholds

```c
#define HASHTABLE_MIN_FILL 8  /* Shrink when fill < 12.5% (100/8) */
static unsigned int dict_force_resize_ratio = 4; /* Force expand at 400% fill */
```

The initial table size is 4 buckets (`DICT_HT_INITIAL_EXP = 2`, so `1 << 2 = 4`).

## Key API

### Lifecycle

```c
dict *dictCreate(dictType *type);
void dictRelease(dict *d);
void dictEmpty(dict *d, void(callback)(dict *));
```

### Entry Operations

```c
int dictAdd(dict *d, void *key, void *val);
dictEntry *dictAddRaw(dict *d, void *key, dictEntry **existing);
dictEntry *dictAddOrFind(dict *d, void *key);
int dictReplace(dict *d, void *key, void *val);
int dictDelete(dict *d, const void *key);
dictEntry *dictUnlink(dict *d, const void *key);  /* Remove without free */
dictEntry *dictFind(dict *d, const void *key);
void *dictFetchValue(dict *d, const void *key);
```

### Value Access

```c
void *dictGetKey(const dictEntry *de);
void *dictGetVal(const dictEntry *de);
int64_t dictGetSignedIntegerVal(const dictEntry *de);
uint64_t dictGetUnsignedIntegerVal(const dictEntry *de);
double dictGetDoubleVal(const dictEntry *de);
```

The value union allows storing pointers, 64-bit integers, or doubles without separate allocation.

### Iteration

```c
dictIterator *dictGetIterator(dict *d);        /* Unsafe iterator */
dictIterator *dictGetSafeIterator(dict *d);    /* Safe - allows mutations */
dictEntry *dictNext(dictIterator *iter);
void dictReleaseIterator(dictIterator *iter);
```

### Scan (cursor-based, stateless)

```c
unsigned long dictScan(dict *d, unsigned long v, dictScanFunction *fn, void *privdata);
```

Uses Pieter Noordhuis's reverse-binary-increment algorithm to guarantee all elements are visited even during rehashing, though some may be visited more than once.

### Random Access

```c
dictEntry *dictGetRandomKey(dict *d);
dictEntry *dictGetFairRandomKey(dict *d);
unsigned int dictGetSomeKeys(dict *d, dictEntry **des, unsigned int count);
```

## Utility Macros

```c
#define dictSize(d)          ((d)->ht_used[0] + (d)->ht_used[1])
#define dictIsRehashing(d)   ((d)->rehashidx != -1)
#define dictPauseRehashing(d)  ((d)->pauserehash++)
#define dictResumeRehashing(d) ((d)->pauserehash--)
```

## Where Dict Is Still Used (post-8.1)

The dict is retained in subsystems that haven't migrated to the new hashtable:

| Subsystem | Files | Purpose |
|-----------|-------|---------|
| Lua scripting | `scripting_engine.c`, `eval.c` | Script caches |
| Sentinel | `sentinel.c` | Instance tracking |
| Cluster (legacy) | `cluster_legacy.c` | Node and slot maps |
| Pub/Sub | `pubsub.c` | Channel subscriptions |
| Latency | `latency.c` | Event tracking |
| Config | `config.c` | Configuration maps |
| Functions | `functions.c` | Function libraries |
| Blocked clients | `blocked.c` | Blocking key tracking |

The main keyspace, Hash type, Set type, and Sorted Set type all use `hashtable` now.

## Hash Function

Same as the new hashtable - SipHash with a 16-byte seed:

```c
uint64_t dictGenHashFunction(const void *key, size_t len);
uint64_t dictGenCaseHashFunction(const unsigned char *buf, size_t len);
```
