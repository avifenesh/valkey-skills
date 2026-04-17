# Data Structures

All internal storage primitives and the keyspace shape. Listpack, quicklist, rax, sds, and the skiplist algorithm itself are unchanged from Redis and only listed briefly. Everything else is Valkey-specific divergence.

## Keyspace: kvstore per DB

Standard `lookupKey` / `dbAdd` / `setKey` / `dbDelete` / SCAN / FLUSH in `src/db.c`. Divergence:

- **Keyspace is a `kvstore`, not `dict`.** Each DB's keys, expires, and hash-field-expiry tracking are separate kvstores. In cluster mode, each kvstore holds 16,384 hashtables (one per slot); standalone holds one. `getKVStoreIndexForKey()` routes.
- **Databases allocated lazily.** `server.db[]` is an array of `serverDb *`; `createDatabaseIfNeeded(id)` allocates on first use.
- **Second kvstore for hash field TTL**: `db->keys_with_volatile_items` holds hash keys that carry any per-field TTL, kept in sync via `dbTrackKeyWithVolatileItems()` / `dbUntrackKeyWithVolatileItems()`.

## kvstore (`src/kvstore.c`, `src/kvstore.h`)

Valkey-only. Wraps an array of `hashtable *` behind one API. Used by: main keyspace, `expires`, `keys_with_volatile_items`, `pubsub_channels`, `pubsubshard_channels`.

### Shape

- `num_hashtables_bits`: log2 of array size. 4 → 16 (multi-DB standalone). 14 → 16,384 (cluster slots). Max bits = 16 (65,536).
- `kvstoreCreate(type, bits, flags)`. `type` is a `hashtableType *` that MUST wire up four callbacks (asserted at creation): `rehashingStarted`, `rehashingCompleted`, `trackMemUsage`, `getMetadataSize`.

### Flags

- `KVSTORE_ALLOCATE_HASHTABLES_ON_DEMAND` - create a hashtable only on first insert. Needed for cluster (most slots empty).
- `KVSTORE_FREE_EMPTY_HASHTABLES` - release when last key is removed.

### Fenwick tree for O(log N) indexing

`hashtable_size_index` tracks cumulative key counts; allocated only when `num_hashtables > 1`. Enables:

- `kvstoreFindHashtableIndexByKeyIndex` - locate which hashtable holds the Nth overall key.
- `kvstoreGetFairRandomHashtableIndex` - random selection weighted by per-hashtable key count.

Single-db mode short-circuits these paths.

### Scan cursor encoding

`kvstoreScan` packs `<upper 48 bits: position within hashtable>|<lower bits: hashtable index>` into one cursor. Finishing a hashtable (position cursor returns to 0) auto-advances to the next non-empty one. Pass `onlydidx >= 0` to restrict to a single index, `-1` for all.

### Cluster slot migration support

`importing` is a hashtable of slot indexes currently being imported. **Excluded** from Fenwick counts and from random hashtable selection (prevents double-counting mid-migration). API: `kvstoreSetIsImporting(kvs, didx, is_importing)`, `kvstoreImportingSize(kvs)`.

### Iterator types

- `kvstoreIterator` - walks all non-empty hashtables in sequence.
- `kvstoreHashtableIterator` - walks one hashtable index.

Both support deletion during iteration (safe mode).

### Rehashing

`rehashing` list tracks in-progress rehashes; `resize_cursor` walks the array for incremental resize during cron. `kvstoreIncrementallyRehash(kvs, threshold_us)` is time-bounded, called from cron.

## Hashtable (`src/hashtable.c`, `src/hashtable.h`)

Designed by Viktor Söderqvist; bucket chaining contributed by Madelyn Olson; cache-line bucket layout inspired by Swiss tables.

### What it actually is

**Bucket chaining on cache-line (64-byte) buckets.** Each bucket holds **7 entries** inline; when full, the 8th slot becomes a pointer to the next bucket in the chain. Not open addressing. Not Robin Hood. No probing.

Bucket layout (64 bytes):

```
[1-bit chained][7-bit presence][7 x 1-byte h2 hash][7 x 8-byte entry pointer]
```

- `h2` = high bits of the entry's hash; scanned with SIMD (x86 SSE/AVX, ARM NEON) to reject misses without touching the entry pointer.
- `chained = 1` means the last pointer-slot is the next-bucket pointer.

### Properties

- **Incremental rehashing** via two tables, same conceptual pattern as dict.
- **Resize policies** (`hashtableResizeAllow`): `ALLOW` (default), `AVOID` (during fork - don't grow), `FORBID` (in child - refuse any resize).
- **Incremental find**: `hashtableIncrementalFindInit` → `hashtableIncrementalFindStep` → `hashtableIncrementalFindGetResult`. Used by prefetching to spread lookup cost across event-loop iterations.
- **Two-phase insert**: `hashtableFindPositionForInsert` + `hashtableInsertAtPosition` lets callers allocate the entry with the right shape (embedded key, expire, etc.) before committing.

### Consumers

Main keyspace (via `kvstore`), Set, Hash, Sorted Set (paired with skiplist), `server.commands` / `server.orig_commands`.

## Object lifecycle (`src/object.c`, `struct serverObject`)

The robj contract (types, encodings, refcount, `OBJ_SHARED_INTEGERS = 10000`, `tryObjectEncoding`, `dismissObject` for CoW reduction) mostly matches Redis. Layout diverges.

### Variable-length robj with embedded key/expire/value

Three bit-flags on `robj` control which optional fields follow the base struct:

- `hasexpire` - `long long expire` stored in the allocation (no separate `expires` dict entry needed).
- `hasembkey` - key SDS stored in the allocation.
- `hasembval` - value SDS stored in the allocation (replaces `val_ptr`; base size becomes `sizeof(robj) - sizeof(void *)`).

Layout (embedded value):
```
[robj base (no val_ptr)][expire?][key_header_size][key sds][value sds]
```

Layout (not embedded, possibly with embedded key+expire):
```
[robj base (val_ptr)][expire?][key_header_size][key sds]
```

### Embed budget

`shouldEmbedStringObject` returns true when total size ≤ **128 bytes** (2 cache lines) - counting robj base + optional expire + optional key SDS + value SDS. The old Redis `OBJ_ENCODING_EMBSTR_SIZE_LIMIT 44` is gone.

`KEY_SIZE_TO_INCLUDE_EXPIRE_THRESHOLD = 128`: for keys ≥ 128 bytes, space for a future expire is pre-reserved even without a TTL - avoids reallocation on later `EXPIRE`.

### Lifecycle functions agents misuse

- `objectSetKeyAndExpire(o, key, expire)` and `objectSetExpire(o, expire)` **may reallocate**. Always use the returned pointer. Holding the old one is a use-after-free.
- `objectGetVal(o)` - never dereference `val_ptr` directly when `hasembval` might be set; the accessor walks the embedded fields.
- `objectUnembedVal(o)` - convert EMBSTR → RAW in place when you need to mutate.

### Encoding numbers (for `OBJECT ENCODING` debugging)

String: `RAW=0`, `INT=1`, `EMBSTR=8`. Hash/Set/ZSet: `HASHTABLE=2`, `INTSET=6`, `SKIPLIST=7`, `LISTPACK=11`. List: `QUICKLIST=9`, `LISTPACK=11`. Stream: `STREAM=10`. Values 3-5 (`ZIPMAP`, `LINKEDLIST`, `ZIPLIST`) reserved for legacy RDB compat only; not produced at runtime.

## Encoding transitions

### Defaults diverged from Redis

| Config | Valkey default | Redis 7.x default |
|--------|----------------|-------------------|
| `hash-max-listpack-entries` | **512** | 128 |
| `set-max-listpack-entries` | 128 | 128 |
| `zset-max-listpack-entries` | 128 | 128 |
| `set-max-intset-entries` | 512 | 512 |
| listpack-value caps | 64 bytes | 64 bytes |

Redis-baseline assumptions about when hashes convert to hashtable are wrong on Valkey - the `hash-max-listpack-entries` bump is the one to remember.

### Full encoding uses `hashtable` (not `dict`)

Hash / Set / Sorted Set past listpack thresholds use `hashtable`. Sorted Set also keeps a paired skiplist.

### Downgrade paths (Valkey-only)

Redis transitions are one-way. Valkey adds:

- `zsetConvertToListpackIfNeeded` (`src/t_zset.c`) - sorted set returns to listpack after bulk deletes from set ops (geo, zset).
- `listTypeTryConvertListpack` (`src/t_list.c`) - quicklist-backed list demotes to listpack when below half the threshold (half-threshold avoids oscillation).

## Skiplist (`src/t_zset.c`)

Max level 32, p=0.25 per level. Algorithm is standard. Layout optimizations in Valkey:

- SDS element embedded directly after the level array in `zskiplistNode` - single allocation per node instead of node + sds pointer.
- Header node reuses slots via unions: `score`/`length` and `backward`/`tail` share storage. The list's `length` and `tail` live **inside the header node** instead of in a separate `zskiplist` struct.
- Level-0 `span` on the header is repurposed to store the list's max level.

Net effect: `zskiplist` is essentially just the header node pointer. Code that assumes Redis's separate `length`/`tail` fields will read wrong values.

## vset (`src/vset.c`, `src/vset.h`)

Valkey-only. **Not a user-facing "vector set" command** - internal adaptive container for tracking entries with expiry.

Used by:
- Hash field expiry (`volatile_fields` inside hash objects).
- `db->keys_with_volatile_items` bookkeeping.
- Call site: `vsetRemoveExpired(...)` in `src/t_hash.c` drives batch field reclamation.

### Pointer tagging

`vset` is a tagged pointer - low 3 bits encode the bucket type:

| Tag | Meaning | Value |
|-----|---------|-------|
| `VSET_BUCKET_NONE` | empty | -1 |
| `VSET_BUCKET_SINGLE` | single entry (raw tagged pointer - **entry pointer must be odd-aligned**) | `0x1` |
| `VSET_BUCKET_VECTOR` | `pVector` (sorted custom SIMD vector) | `0x2` |
| `VSET_BUCKET_HT` | hashtable | `0x4` |
| `VSET_BUCKET_RAX` | radix tree of time buckets | `0x6` |

Mask: `VSET_TAG_MASK = 0x7`, `VSET_PTR_MASK = ~0x7`. Anything stored in a vset must have LSB available for tagging (odd pointer) - hard constraint.

### Growth path

`NONE → SINGLE (1 entry) → VECTOR (≤ 127, sorted by expiry) → RAX (multiple time-bucket VECTORs, or HT for clustered expiry)`.

### Time-bucket RAX

RAX key = 8-byte big-endian timestamp of the bucket's end; entries expire strictly before that. Adaptive bucket width: `VOLATILESET_BUCKET_INTERVAL_MIN = 16 ms`, `VOLATILESET_BUCKET_INTERVAL_MAX = 8192 ms`.

When a VECTOR exceeds `VOLATILESET_VECTOR_BUCKET_MAX_SIZE = 127`:

1. Sort by expiry.
2. Find a split point between adjacent entries in different time buckets.
3. If no split (all in same window) re-align to a finer granularity.
4. If that also fails, convert to HT bucket.

### pVector (vset-only, distinct from general `vector`)

`{len:30, alloc:34, data[]}`. ARM NEON SIMD path in `pvFind` processes 4 pointers per iteration. Don't reuse outside vset.

### Thread-safety

Sort path stores the current `vsetGetExpiryFunc` in a `_Thread_local` (`current_getter_func`) because `qsort_r` isn't portable. Each thread keeps its own; don't assume cross-thread validity.

### Iteration

`vsetInitIterator` / `vsetNext` are **NOT safe** - no mutations during iteration. For bulk reclaim use `vsetRemoveExpired(max_count, ctx)`.

## Hash field entry (`src/entry.c`, `src/entry.h`)

Valkey-only. Runtime representation of a single hash field/value pair with optional per-field TTL. Used by `t_hash.c` when hash values are stored in the `hashtable` encoding (above the listpack threshold).

### Layout

Multiple variants depending on field size + expiry presence. Field sds is always embedded; value may be embedded or externalized:

- **Type 1** - field is `SDS_TYPE_5` (tiny). Field and value both embedded; expiry NOT supported (SDS_TYPE_5 has no aux bits to encode expiry).
- **Type 2+** - field is larger SDS type (8/16/32/64). Aux bit on field SDS encodes expiry presence. Value embedded inline or stored as a string-reference (`entryUpdateAsStringRef`) when the caller owns the underlying buffer.
- **`EMBED_VALUE_MAX_ALLOC_SIZE = 128`** - max allocation to try embedding the value inline; above that value is externalized.

### API surface

- `entryCreate(field, value, expiry)`, `entryFree`, `entryUpdate`, `entrySetExpiry`, `entryUpdateAsStringRef` (for zero-copy).
- `entryGetField`, `entryGetValue(*len)`, `entryGetExpiry`, `entryHasExpiry`, `entryHasStringRef`, `entryIsExpired(against commandTimeSnapshot)`.
- `entryMemUsage`, `entryDefrag(defragfn, sdsdefragfn)`, `entryDismissMemory` - defrag/CoW integration.

Entries live inside the hash's `hashtable` as the entry pointer; `t_hash.c` wires them in via the hashtable's `entryGetKey` callback returning the field SDS.

## Dict (thin wrapper around hashtable)

`src/dict.h` only - **`src/dict.c` is gone**. The `dict` API is now a header-only wrapper over `hashtable`: `typedef hashtable dict;`, `typedef hashtableType dictType;`, `typedef hashtableIterator dictIterator;`. `dictEntry` is the only real struct (a `{key, union v}` pair) - the old `next` pointer is gone because the underlying hashtable handles chaining.

Macros delegate: `dictSize` → `hashtableSize`, `dictCreate` → `hashtableCreate`, etc. Call-site code still reads `dict*` and `dictEntry*`, but under the hood every operation goes through `hashtable`.

Grep impact:
- Searching for `dict.c` returns nothing; implementation is in `hashtable.c`.
- `dictEntry->next` and old chaining fields are gone - code that cast through them won't compile.
- Callers not yet migrated still use `dict*`/`dictEntry*` (Sentinel, `cluster_legacy.c`, pub/sub patterns, latency, scripting, functions, blocked clients, `subcommands_ht` inside command entries). That's fine - they're running on the hashtable engine now.

## Unchanged from Redis (quick reference only)

- **Listpack** (`src/listpack.c`): 6-byte header, integers 2-10 bytes, strings with backlen for reverse walk, O(1) length when count ≤ 65535.
- **Quicklist** (`src/quicklist.c`): doubly-linked list of listpack nodes (or PLAIN for oversized entries), interior LZF compression. Configs: `list-max-listpack-size`, `list-compress-depth`. The `listTypeTryConvertListpack` demote path *is* Valkey-specific (see encoding transitions above).
- **Rax** (`src/rax.c`): radix tree. Used by Streams (stream ID index, consumer groups, PEL) and cluster `fail_reports`.
- **SDS** (`src/sds.c`): 5 header types (`SDS_TYPE_5` / `8` / `16` / `32` / `64`); type tag in 3 low bits of `s[-1]`. Remaining aux bits via `sdsGetAuxBit` / `sdsSetAuxBit` (hashtable uses one for "entry has TTL metadata" - see `t_hash.c`).
- **Intset** (`src/intset.c`): sorted integer set; `set-max-intset-entries` (default 512) gates the switch to listpack/hashtable.
