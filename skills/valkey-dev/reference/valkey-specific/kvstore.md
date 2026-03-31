# kvstore - Multi-Index KV Store Abstraction

Use when you need to understand how Valkey organizes keys across multiple
hash tables - for multi-database support (16 DBs) or cluster slot isolation
(16384 slots).

Source: `src/kvstore.c`, `src/kvstore.h`

## Contents

- What This Is (line 26)
- Core Struct (line 38)
- Flags (line 61)
- Creation (line 73)
- Usage in the Server (line 91)
- Fenwick Tree for Key Lookup (line 109)
- Scanning (line 122)
- Rehashing (line 139)
- Key API Functions (line 150)
- Cluster Migration Support (line 167)
- Iterator Types (line 179)
- See Also (line 188)

---

## What This Is

kvstore is a Valkey-specific abstraction that wraps an array of hash tables
behind a unified API. Redis historically used a flat `dict` per database.
Valkey replaces this with kvstore, which maps each logical partition (database
index or cluster hash slot) to its own hashtable while exposing aggregate
operations across all of them.

The key innovation: efficient O(log N) lookups by cumulative key count using
a Fenwick tree (binary indexed tree), plus on-demand hashtable allocation to
avoid wasting memory on empty slots.

## Core Struct

```c
struct _kvstore {
    int flags;
    hashtableType *dtype;
    hashtable **hashtables;             // Array of hash table pointers
    int num_hashtables;                 // Total count (e.g. 16 or 16384)
    int num_hashtables_bits;            // log2 of num_hashtables
    list *rehashing;                    // Hash tables currently rehashing
    int resize_cursor;                  // Gradual resize position
    int allocated_hashtables;           // Actually allocated (vs NULL slots)
    int non_empty_hashtables;           // Non-empty count
    unsigned long long key_count;       // Total keys across all tables
    unsigned long long bucket_count;    // Total buckets across all tables
    unsigned long long *hashtable_size_index;  // Fenwick tree for cumulative counts
    size_t overhead_hashtable_lut;      // Memory overhead tracking
    size_t overhead_hashtable_rehashing;
    hashtable *importing;               // Set of hashtable indexes being imported
    unsigned long long importing_key_count;
};
```

## Flags

```c
#define KVSTORE_ALLOCATE_HASHTABLES_ON_DEMAND (1 << 0)
#define KVSTORE_FREE_EMPTY_HASHTABLES         (1 << 1)
```

When `ALLOCATE_HASHTABLES_ON_DEMAND` is set, hashtables are created only when
the first key is inserted into that index. When `FREE_EMPTY_HASHTABLES` is set,
a hashtable is freed when its last key is removed. Both flags are critical for
cluster mode where 16384 slots exist but most are empty on any given node.

## Creation

```c
kvstore *kvstoreCreate(hashtableType *type, int num_hashtables_bits, int flags);
```

`num_hashtables_bits` is the log2 of the desired count. For 16 databases,
pass 4. For 16384 cluster slots, pass 14. Maximum is 16 (65536 tables).

The hashtableType must wire up four kvstore-specific callbacks:

- `rehashingStarted` -> `kvstoreHashtableRehashingStarted`
- `rehashingCompleted` -> `kvstoreHashtableRehashingCompleted`
- `trackMemUsage` -> `kvstoreHashtableTrackMemUsage`
- `getMetadataSize` -> `kvstoreHashtableMetadataSize`

These are asserted at creation time - no silent misconfiguration.

## Usage in the Server

```c
typedef struct serverDb {
    kvstore *keys;                      // The keyspace for this DB
    kvstore *expires;                   // Keys with TTL
    kvstore *keys_with_volatile_items;  // Keys with volatile items
    // ...
};
```

Also used for pubsub channels:

```c
kvstore *pubsub_channels;
kvstore *pubsubshard_channels;
```

## Fenwick Tree for Key Lookup

The `hashtable_size_index` is a binary indexed tree (Fenwick tree) that tracks
cumulative key counts per hashtable. This enables:

- `kvstoreFindHashtableIndexByKeyIndex(kvs, target)` - find which hashtable
  contains the Nth key overall, in O(log N) time
- `kvstoreGetFairRandomHashtableIndex(kvs)` - weighted random selection
  proportional to key count per hashtable

The Fenwick tree is only allocated when `num_hashtables > 1`. For single-db
mode, all these functions short-circuit.

## Scanning

```c
unsigned long long kvstoreScan(kvstore *kvs, unsigned long long cursor,
                               int onlydidx,
                               kvstoreScanFunction scan_cb,
                               kvstoreScanShouldSkipHashtable *skip_cb,
                               void *privdata);
```

The cursor encodes both the hashtable index (lower bits) and the position
within the hashtable (upper 48 bits). When a hashtable scan completes
(cursor reaches 0), the next non-empty hashtable is found automatically.

Pass `onlydidx >= 0` to restrict scanning to a single hashtable index.
Pass `-1` to scan across all.

## Rehashing

```c
void kvstoreTryResizeHashtables(kvstore *kvs, int limit);
uint64_t kvstoreIncrementallyRehash(kvstore *kvs, uint64_t threshold_us);
```

The `rehashing` list tracks which hashtables are mid-rehash. The
`resize_cursor` enables gradual resize across the full array during cron.
Bucket counts are maintained incrementally as rehashing starts and completes.

## Key API Functions

| Function | Purpose |
|----------|---------|
| `kvstoreCreate` | Allocate a new kvstore |
| `kvstoreRelease` | Free all resources |
| `kvstoreEmpty` | Clear all hashtables |
| `kvstoreSize` | Total key count |
| `kvstoreScan` | Cursor-based iteration across tables |
| `kvstoreHashtableAdd` | Insert into a specific index |
| `kvstoreHashtableDelete` | Remove from a specific index |
| `kvstoreHashtableFind` | Lookup in a specific index |
| `kvstoreGetFairRandomHashtableIndex` | Weighted random selection |
| `kvstoreHashtableRandomEntry` | Random entry from one table |
| `kvstoreIncrementallyRehash` | Time-bounded rehashing |
| `kvstoreSetIsImporting` | Mark a slot as being imported (cluster migration) |

## Cluster Migration Support

The `importing` field is a hashtable of slot indexes currently being imported
during cluster slot migration. Importing slots are excluded from the Fenwick
tree counts and from random hashtable selection, preventing double-counting
during migration.

```c
void kvstoreSetIsImporting(kvstore *kvs, int didx, int is_importing);
unsigned long long kvstoreImportingSize(kvstore *kvs);
```

## Iterator Types

Two iterator types exist:

- `kvstoreIterator` - iterates across all non-empty hashtables in sequence
- `kvstoreHashtableIterator` - iterates within a single hashtable index

Both support safe iteration (allowing deletions during traversal).

## See Also

- [../data-structures/hashtable.md](../data-structures/hashtable.md) - The open-addressing hash table wrapped by kvstore
- [object-lifecycle.md](object-lifecycle.md) - The `robj` entries stored as values in the keyspace hashtables
- [../architecture/overview.md](../architecture/overview.md) - The `serverDb` struct that uses kvstore for `keys`, `expires`, and `keys_with_volatile_items`
- [../cluster/overview.md](../cluster/overview.md) - In cluster mode, kvstore is created with `num_hashtables_bits=14` (16,384 hash tables), one per cluster hash slot. The `KVSTORE_ALLOCATE_HASHTABLES_ON_DEMAND` and `FREE_EMPTY_HASHTABLES` flags keep memory usage proportional to the slots actually owned by this node.
- [../cluster/slot-migration.md](../cluster/slot-migration.md) - The `importing` field and `kvstoreSetIsImporting()` support atomic slot migration by excluding importing slots from Fenwick tree counts and random selection
