# vset - Volatile Set (Adaptive, Expiry-Aware Set Structure)

Use when you need to understand how Valkey tracks keys with TTLs internally,
or when working on expiry-related code paths. This is NOT a user-facing
"vector set" command - it is an internal data structure for managing entries
with expiry semantics.

Source: `src/vset.c` (2,446 lines), `src/vset.h`

## What This Is

The `vset` (volatile set) is a Valkey-specific adaptive container for managing
entries that expire. It groups entries into time buckets and dynamically
switches internal representation as the set grows. Redis used a flat dict for
expires; Valkey replaces this with a structure that enables efficient
batch expiry and earliest-expiry estimation.

The name "vset" comes from "volatile set" - tracking volatile (expiring) keys.

## Public API

```c
// Lifecycle
void vsetInit(vset *set);
void vsetClear(vset *set);
void vsetRelease(vset *set);

// Mutation
bool vsetAddEntry(vset *set, vsetGetExpiryFunc getExpiry, void *entry);
bool vsetRemoveEntry(vset *set, vsetGetExpiryFunc getExpiry, void *entry);
bool vsetUpdateEntry(vset *set, vsetGetExpiryFunc getExpiry,
                     void *old_entry, void *new_entry,
                     long long old_expiry, long long new_expiry);

// Expiry operations
long long vsetEstimatedEarliestExpiry(vset *set, vsetGetExpiryFunc getExpiry);
size_t vsetRemoveExpired(vset *set, vsetGetExpiryFunc getExpiry,
                         vsetExpiryFunc expiryFunc, mstime_t now,
                         size_t max_count, void *ctx);

// Iteration (NOT safe - no modifications during iteration)
void vsetInitIterator(vset *set, vsetIterator *it);
bool vsetNext(vsetIterator *it, void **entryptr);
void vsetResetIterator(vsetIterator *it);

// Utilities
bool vsetIsEmpty(vset *set);
size_t vsetMemUsage(vset *set);
```

## Key Types

```c
typedef void *vset;  // Just a tagged pointer to a bucket
typedef long long (*vsetGetExpiryFunc)(const void *entry);
typedef int (*vsetExpiryFunc)(void *entry, void *ctx);
```

The `vset` itself is just a pointer. The type of the underlying structure is
encoded in the pointer's lowest 3 bits via pointer tagging.

## Pointer Tagging Scheme

```c
#define VSET_BUCKET_NONE   -1     // Empty
#define VSET_BUCKET_SINGLE 0x1UL  // xx1 - pointer to single entry (odd ptr)
#define VSET_BUCKET_VECTOR 0x2UL  // 010 - pointer to pVector
#define VSET_BUCKET_HT     0x4UL  // 100 - pointer to hashtable
#define VSET_BUCKET_RAX    0x6UL  // 110 - pointer to radix tree

#define VSET_TAG_MASK      0x7UL
#define VSET_PTR_MASK      (~VSET_TAG_MASK)
```

IMPORTANT: All entries stored in the vset must have their LSB set (odd-aligned
pointers) to be compatible with the SINGLE bucket tag.

## Bucket Lifecycle

```
NONE -> SINGLE (1 entry) -> VECTOR (sorted, up to 127) -> RAX (multiple buckets)
```

1. First entry: becomes SINGLE bucket (just the tagged pointer itself).
2. Second entry: promoted to VECTOR (sorted by expiry time).
3. More than 127 entries: promoted to RAX (radix tree of time buckets).

## Time Bucket Organization

Entries are grouped into time windows based on their expiry timestamp:

```c
#define VOLATILESET_BUCKET_INTERVAL_MIN  (1 << 4)   // 16ms
#define VOLATILESET_BUCKET_INTERVAL_MAX  (1 << 13)  // 8192ms
```

Each RAX key is a big-endian 8-byte timestamp representing the END of that
bucket's time window. All entries in a bucket expire BEFORE the bucket
timestamp.

```
Timeline:     ----------> increasing time ----------->
              +--------------+-------------+---------+
              | B0           | B1          |   B2    |
              | ts=32        | ts=128      | ts=2048 |
              +--------------+-------------+---------+
              ^              ^             ^
    [E1,E2] in B0     [E3..E7] in B1    [E8..E15] in B2
```

## pVector - Custom Pointer Vector

The vset uses `pVector`, a custom SIMD-accelerated vector of pointers, distinct
from the general-purpose `vector` type:

```c
typedef struct {
    uint64_t len : 30;     // Number of elements
    uint64_t alloc : 34;   // Allocated bytes
    void *data[];          // Flexible array of pointers
} pVector;
```

Key operations: `pvNew`, `pvPush`, `pvPop`, `pvFind` (with ARM NEON SIMD
acceleration), `pvInsertAt`, `pvRemoveAt`, `pvSplit`, `pvSort`.

The SIMD path in `pvFind` processes 4 pointers per iteration using NEON
64-bit comparison instructions on ARM64.

## Bucket Splitting Strategy

When a VECTOR bucket in the RAX exceeds `VOLATILESET_VECTOR_BUCKET_MAX_SIZE`
(127), the vset attempts to split it:

1. Sort the vector by expiry time.
2. Find a split position where `get_bucket_ts()` transitions between adjacent
   entries, searching outward from the middle for balanced splits.
3. If a split point exists: create two vectors in separate RAX entries.
4. If all entries map to the same bucket timestamp: try re-aligning to a
   finer granularity (smaller time window).
5. If neither works: convert the vector to a hashtable bucket (O(1) lookups
   for clustered expiry values).

## Usage in the Codebase

The vset is used for:

- Hash field expiry tracking: `vset *volatile_fields` embedded in the hash
  table metadata of `OBJ_HASH` objects
- Keys-with-volatile-items tracking in `serverDb.keys_with_volatile_items`

The `vsetRemoveExpired` function enables batch removal of expired entries up
to a count limit, which the active-expiry cron uses to efficiently purge
expired hash fields without scanning the entire hash.

## Thread Safety

The expiry getter function is stored in a `_Thread_local` variable
(`current_getter_func`) to work around the lack of `qsort_r` on all
platforms. This means vset sort operations are safe across threads but the
getter must be set/unset around each sort call.
