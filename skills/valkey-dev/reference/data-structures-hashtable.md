# Hashtable - Open-Addressing Hash Table (8.1+)

Use when you need the primary key-value store or the backing structure for Hash, Set, and Sorted Set types. This replaced the legacy `dict` starting in Valkey 8.1.

Source: `src/hashtable.c`, `src/hashtable.h`

## Contents

- Overview (line 25)
- Bucket Layout (line 35)
- Secondary Hash (h2) (line 68)
- Bucket Chaining (line 80)
- Core Struct (line 97)
- Type Callbacks (line 114)
- Fill Factor and Resizing (line 135)
- Resize Policy (line 155)
- Incremental Rehashing (line 165)
- Key API (line 178)
- Hash Function (line 236)
- Differences from Legacy Dict (line 245)

---

## Overview

The new hashtable is a cache-friendly, open-addressing hash table designed by Viktor Soderqvist. It stores pointers to user-defined entries in 64-byte cache-line-aligned buckets. Each bucket holds up to 7 entries (on 64-bit systems) with per-entry metadata for fast mismatch elimination.

Key properties:
- 2 memory accesses per lookup (bucket + entry) vs 4 in old dict
- ~20 bytes saved per key-value pair without TTL, ~30 with TTL
- Supports incremental rehashing, SCAN iteration, random sampling
- SIMD-accelerated bucket scanning on x86 (SSE/AVX) and ARM (NEON)

## Bucket Layout

Each bucket is exactly 64 bytes (one cache line):

```
+------------------------------------------------------------------+
| Metadata | Entry | Entry | Entry | Entry | Entry | Entry | Entry |
+------------------------------------------------------------------+

64-bit system (7 entries per bucket):

  1 bit     7 bits    [1 byte] x 7    [8 bytes] x 7 = 64 bytes
  chained   presence  hashes           entries
```

```c
typedef struct hashtableBucket {
    BUCKET_BITS_TYPE chained : 1;
    BUCKET_BITS_TYPE presence : ENTRIES_PER_BUCKET;
    uint8_t hashes[ENTRIES_PER_BUCKET];
    void *entries[ENTRIES_PER_BUCKET];
} bucket;

static_assert(sizeof(bucket) == HASHTABLE_BUCKET_SIZE, "Bucket size mismatch");
```

| Field | Bits | Purpose |
|-------|------|---------|
| `chained` | 1 | If set, last entry slot is a pointer to a child bucket |
| `presence` | 7 | One bit per slot - indicates if occupied |
| `hashes[7]` | 56 (7 bytes) | One byte of secondary hash per slot |
| `entries[7]` | 448 (56 bytes) | Pointers to user-defined entry objects |

## Secondary Hash (h2)

The hash function produces a 64-bit value. The lower bits select the bucket index. The highest 8 bits are stored in the bucket metadata as a secondary hash:

```c
static inline uint8_t highBits(uint64_t hash) {
    return hash >> (CHAR_BIT * 7);
}
```

On lookup, the secondary hash is compared first. With 256 possible values per byte, ~99.6% of false positives are eliminated without ever comparing the actual key. This means most lookups touch only the bucket's cache line plus the one matching entry.

## Bucket Chaining

When a bucket fills (all 7 slots occupied), the last slot is converted to a pointer to a child bucket with identical layout:

```
     Bucket (table)
+---------------+
| x x x x x x p | ---> Child bucket
+-------------|-+    +---------------+
                     | x x x x x x p | ---> Child bucket
                     +-------------|-+    +---------------+
                                          | x x x x x x x |
                                          +---------------+
```

The `chained` bit indicates whether the last slot is an entry or a child-bucket pointer. When chained, the bucket holds 6 entries + 1 pointer.

## Core Struct

```c
struct hashtable {
    hashtableType *type;
    ssize_t rehash_idx;        /* -1 = not rehashing */
    bucket *tables[2];         /* 0 = main, 1 = rehash target */
    size_t used[2];            /* Entry count per table */
    int8_t bucket_exp[2];      /* Exponent (num_buckets = 1 << exp) */
    int16_t pause_rehash;
    int16_t pause_auto_shrink;
    size_t child_buckets[2];   /* Allocated child buckets per table */
    iter *safe_iterators;      /* Linked list of active safe iterators */
    void *metadata[];
};
```

## Type Callbacks

```c
typedef struct {
    const void *(*entryGetKey)(const void *entry);
    uint64_t (*hashFunction)(const void *key);
    int (*keyCompare)(const void *key1, const void *key2);
    bool (*validateEntry)(hashtable *ht, void *entry);
    void (*entryDestructor)(void *entry);
    void (*entryPrefetchValue)(const void *entry);
    int (*resizeAllowed)(size_t moreMem, double usedRatio);
    void (*rehashingStarted)(hashtable *ht);
    void (*rehashingCompleted)(hashtable *ht);
    void (*trackMemUsage)(hashtable *ht, ssize_t delta);
    size_t (*getMetadataSize)(void);
    unsigned instant_rehashing : 1;   /* Complete rehashing in one step rather than incrementally */
} hashtableType;
```

All callbacks are optional. With none set, the table acts as a set of pointer-sized integers.

## Fill Factor and Resizing

```c
#define MAX_FILL_PERCENT_SOFT 100
#define MAX_FILL_PERCENT_HARD 500
#define MIN_FILL_PERCENT_SOFT 13
#define MIN_FILL_PERCENT_HARD 3
```

Bucket count is computed without expensive division:

```c
#define BUCKET_FACTOR 5
#define BUCKET_DIVISOR 32
// num_buckets = ceil(num_entries * BUCKET_FACTOR / BUCKET_DIVISOR)
// Max fill after resize: 32 / 5 / 7 = 91.43%
```

The soft limits apply under normal operation. Hard limits apply when resizing should be avoided (e.g., during fork for persistence - copy-on-write concerns).

## Resize Policy

Three global policies controlled by `hashtableSetResizePolicy()`:

| Policy | Behavior |
|--------|----------|
| `HASHTABLE_RESIZE_ALLOW` | Rehash as needed for optimal performance |
| `HASHTABLE_RESIZE_AVOID` | Avoid rehashing during fork (COW protection) |
| `HASHTABLE_RESIZE_FORBID` | No rehashing at all (child process) |

## Incremental Rehashing

Like the old dict, rehashing uses two tables. Entries migrate from `tables[0]` to `tables[1]` incrementally:

1. A new table is allocated at the target size
2. On each insert/lookup/delete, entries from one bucket chain are migrated
3. `rehash_idx` tracks progress through the old table
4. When `used[0] == 0`, the old table is freed and tables are swapped

During rehashing, lookups check both tables. New inserts go to `tables[1]`.

Batch rehashing (`rehashEntry`) processes entries in groups of `FETCH_BUCKET_COUNT_WHEN_EXPAND` (4) buckets for better cache behavior during expansion.

## Key API

### Lifecycle

```c
hashtable *hashtableCreate(hashtableType *type);
void hashtableRelease(hashtable *ht);
void hashtableEmpty(hashtable *ht, void(callback)(hashtable *));
```

### Entry Operations

```c
bool hashtableFind(hashtable *ht, const void *key, void **found);
bool hashtableAdd(hashtable *ht, void *entry);
bool hashtableAddOrFind(hashtable *ht, void *entry, void **existing);
bool hashtableDelete(hashtable *ht, const void *key);
bool hashtablePop(hashtable *ht, const void *key, void **popped);
```

### Two-Phase Insert (for callers needing atomic find-or-insert)

```c
bool hashtableFindPositionForInsert(hashtable *ht, void *key,
                                     hashtablePosition *position, void **existing);
void hashtableInsertAtPosition(hashtable *ht, void *entry,
                               hashtablePosition *position);
```

### Incremental Find (spread lookup cost across event loop iterations)

```c
void hashtableIncrementalFindInit(hashtableIncrementalFindState *state,
                                  hashtable *ht, const void *key);
bool hashtableIncrementalFindStep(hashtableIncrementalFindState *state);
bool hashtableIncrementalFindGetResult(hashtableIncrementalFindState *state,
                                       void **found);
```

### Iteration

```c
void hashtableInitIterator(hashtableIterator *iter, hashtable *ht, uint8_t flags);
bool hashtableNext(hashtableIterator *iter, void **elemptr);
size_t hashtableScan(hashtable *ht, size_t cursor, hashtableScanFunction fn,
                     void *privdata);
```

Iterator flags: `HASHTABLE_ITER_SAFE` (allows mutations), `HASHTABLE_ITER_PREFETCH_VALUES` (prefetch entry values for better cache behavior).

### Random Sampling

```c
bool hashtableRandomEntry(hashtable *ht, void **found);
bool hashtableFairRandomEntry(hashtable *ht, void **found);
unsigned hashtableSampleEntries(hashtable *ht, void **dst, unsigned count);
```

## Hash Function

The default hash function is SipHash with a 16-byte random seed set at startup:

```c
uint64_t hashtableGenHashFunction(const char *buf, size_t len);
uint64_t hashtableGenCaseHashFunction(const char *buf, size_t len);
```

## Differences from Legacy Dict

| Aspect | dict (legacy) | hashtable (8.1+) |
|--------|--------------|------------------|
| Collision handling | Chained linked list | Open addressing with bucket chaining |
| Memory per entry | ~56-72 bytes (dictEntry + pointers) | ~20-30 bytes (entry in bucket slot) |
| Cache behavior | Poor (pointer chasing) | Excellent (64-byte aligned buckets) |
| Lookup cost | 4+ memory accesses | 2 memory accesses |
| Secondary hash | None | 1-byte h2 per slot (99.6% mismatch filter) |
| SIMD | None | Optional x86 SSE/AVX and ARM NEON |
| Separate dictEntry | Yes (key + value + next) | No (user provides entry object) |
