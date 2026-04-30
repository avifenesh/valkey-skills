# Data Structures

All internal storage primitives and the keyspace shape. Listpack, quicklist, rax, sds, intset, and the skiplist algorithm are unchanged from Redis - read the source. Everything below is Valkey-specific divergence.

## Iterator-invariant taxonomy (read before matching individual rules)

Five distinct UAF/corruption windows. The rule lists below cover the obvious cases; these are the bug classes they miss. If your change widens any of these, prove the window is closed before enumerating rules.

1. **Rehash cursor direction.** `rehash_idx` advances 0 upward. `idx < rehash_idx` has migrated to `tables[1]`; `idx >= rehash_idx` still lives in `tables[0]`. Any "skip already-rehashed" helper uses `<`, not `<=`, not `>`. `findBucket`, `hashtableReplaceReallocatedEntry`, and safe-iterator init share this pattern. Inverting compiles, tests pass on unmirrored data, and silently corrupts under rehash.
2. **Scan + shrink race.** `hashtableTwoPhasePopDelete` reserves a position during begin; a shrink between begin and finalize invalidates it. Pause auto-shrink across the pair or defer shrink until after finalize.
3. **Safe-iterator lifetime.** Safe iterators pause incremental rehash for their lifetime; `hashtableRelease` may run while an iterator is still registered, so `hashtableCleanupIterator` MUST unregister from `ht->safe_iterators` before the table is freed - otherwise a later release walks dangling `next_safe_iter`. Canonical UAF path for hashtable changes.
4. **stringRef ownership (entries).** `entryUpdateAsStringRef` points at a caller-owned buffer; if the caller frees or reuses it before the entry is freed or re-updated, the hash read path UAFs.
5. **Two-phase insert reservation.** `hashtableInsertAtPosition` commits what `hashtableFindPositionForInsert` reserved; any realloc, rehash, or shrink in between invalidates the reservation. Treat the pair as atomic - no allocations, no scans, no callback re-entry between them.

## Keyspace: kvstore per DB

Three kvstores per DB move in lockstep (`keys`, `expires`, `keys_with_volatile_items`). Any RDB/replication/defrag path that touches one must consider the other two.

- Keyspace is a `kvstore`, not `dict`. Cluster mode: 16,384 hashtables per kvstore (one per slot); standalone: one. `getKVStoreIndexForKey()` routes.
- Databases allocated lazily. `server.db[]` is `serverDb *`; `createDatabaseIfNeeded(id)` allocates on first use. `kvstoreCreate()` allocates non-trivial baseline even at zero hashtables, so memory accounting that skips "no allocated hashtables" DBs under-counts; only `db == NULL` is the genuine skip.
- `db->keys_with_volatile_items` holds hash keys carrying any per-field TTL, kept in sync via `dbTrackKeyWithVolatileItems()` / `dbUntrackKeyWithVolatileItems()`. Active hash-field expiration must register with the kvstore's incremental-rehashing hook or expiration halts mid-rehash and the vset leaks phantom bookkeeping.

## kvstore (`src/kvstore.c`, `src/kvstore.h`)

Valkey-only. Wraps an array of `hashtable *` behind one API. Used by: main keyspace, `expires`, `keys_with_volatile_items`, `pubsub_channels`, `pubsubshard_channels`.

- `num_hashtables_bits`: log2 of array size. 4 = 16 (multi-DB standalone). 14 = 16,384 (cluster slots). Max = 16 (65,536).
- `kvstoreCreate(type, bits, flags)`. `type` MUST wire four callbacks (asserted): `rehashingStarted`, `rehashingCompleted`, `trackMemUsage`, `getMetadataSize`.
- Flags: `KVSTORE_ALLOCATE_HASHTABLES_ON_DEMAND` (cluster - most slots empty), `KVSTORE_FREE_EMPTY_HASHTABLES`.
- `hashtable_size_index` (Fenwick tree) tracks cumulative counts, allocated only when `num_hashtables > 1`. Powers `kvstoreFindHashtableIndexByKeyIndex` and `kvstoreGetFairRandomHashtableIndex`. Single-db mode short-circuits.
- `kvstoreScan` cursor packs `<upper 48: pos>|<lower: hashtable index>`; returning to position 0 auto-advances to the next non-empty index. `onlydidx >= 0` restricts to one index, `-1` scans all.
- Iterators: `kvstoreIterator` (all non-empty), `kvstoreHashtableIterator` (one index). Both safe for in-iteration deletion.

### Invariants

- Size hints are per-slot. `kvstoreHashtableExpand(kvs, slot, size)` pre-sizes the per-slot hashtable; sizing the top-level kvstore is not meaningful. RDB slot-info AUX sends one hint per `(slot, keys, expires, keys_with_volatile_items)` - all three kvstores need pre-sizing on load.
- `kvstoreExpand(size=0)` is a no-op returning `true`; the inner per-hashtable `TryExpand(0)` returns `false`. Layer-different semantics - do not conflate.
- Cluster slot migration: `importing` is a hashtable of slot indexes being imported. Excluded from Fenwick counts and fair random selection (`kvstoreGetFairRandomHashtableIndex` may return `KVSTORE_INDEX_NOT_FOUND`). `DBSIZE` differs from `COUNTKEYSINSLOT` during migration by design. Use `HASHTABLE_ITER_INCLUDE_IMPORTING` for full-scan consumers (RDB, replication); client-facing reads (SCAN, KEYS, RANDOMKEY, eviction, expiry) MUST NOT set it.
- kvstore iteration advances via `next_didx`, not `didx`, when filtering - applying the predicate to the already-consumed index skips entries silently.
- `kvstoreIteratorNext` must reset the previous hashtable's iterator before re-initializing onto the next, gated on `kvs_it->didx != -1 AND kvstoreGetHashtable(kvs, didx) != NULL` (the table may have been deleted mid-iteration). Missing reset leaves rehashing paused forever on the abandoned table.
- `bucket_count` accounting includes `rehashing->to` during rehash. `freeHashtableIfNeeded` mid-rehash without this leaves a count stuck on the freed primary.
- `kvstore` must not `#include "server.h"`. One-way layering; `valkey-cli` and `valkey-benchmark` reuse data-structure modules.

## Hashtable (`src/hashtable.c`, `src/hashtable.h`)

Bucket chaining on cache-line (64-byte) buckets. Each bucket holds 7 entries inline; when full, the 8th slot becomes a pointer to the next bucket. Not open addressing, not Robin Hood, no probing.

- `h2` = high hash bits, SIMD-scanned (SSE/AVX/NEON) to reject misses without touching entry pointers.
- Consumers: main keyspace (via kvstore), Set, Hash, Sorted Set (paired with skiplist), `server.commands` / `server.orig_commands`.
- Incremental rehashing (two tables), three-phase resize policy (`ALLOW`/`AVOID`/`FORBID`), incremental find (`hashtableIncrementalFindInit/Step/GetResult`), two-phase insert (`hashtableFindPositionForInsert` + `hashtableInsertAtPosition`).

### Invariants

- `resize()` asserts `!hashtableIsRehashing(ht)`. Static API - callers must gate on `hashtableIsRehashing` or `hashtableIsRehashingPaused`. Three-gate incremental-rehash order: `MAX_FILL_PERCENT_HARD` -> `resize_policy` (`ALLOW`/`AVOID`/`FORBID`) -> `resizeAllowed` callback (expand only; shrink skips the callback). `AVOID` during fork; `FORBID` in child.
- Empty-bucket skipping lives in `rehashStepShrink` only. The grow path does not skip. Condition on `b->presence == 0 && !chained` (NOT `b == NULL` - array is contiguous). Cap is 10 empty visits per step (covers 70 dict-equivalent slots).
- Bucket density is arch-dependent: 7 on 64-bit, 12 on 32-bit. Tests asserting against `hashtableGetRehashingIndex()` must guard on `arch_bits` or accept the `-1` (rehashing-complete) sentinel.
- Non-empty means `used[idx] > 0 OR child_buckets[idx] > 0`. Using `used == 0` alone leaks chained-but-empty buckets in shrink/scan/release paths (`hashtablePop` only compacts chains when `!hashtableIsRehashingPaused`).
- `pause_rehash` is correctness; `pause_auto_shrink` is performance. Scans and iterators pause rehash to stabilise bucket addressing - public code may pause auto-shrink to batch deletes but MUST NOT rely on auto-shrink pause for memory safety. Both must balance across all paths including early returns and `compactBucketChain` inside `hashtablePop`.
- Bulk-delete loops over hashtable-encoded sets/zsets MUST bracket with `hashtablePauseAutoShrink`/`hashtableResumeAutoShrink`. On resume, skip if the containing key was already deleted (`keyremoved`) - `dbDelete` freed the hashtable and touching it is a UAF. Gate resume on `keyremoved`, not by reordering `dbDelete` vs `notifyKeyspaceEvent`.
- `validateEntry` / `shouldSkip` callbacks are pure predicates on the read/sample path (HRANDFIELD, RANDOMKEY, expiry sampling). `true` = skip, `false` = include. They MAY trigger lazy-expire side effects via return value but MUST NOT mutate, propagate, or notify. Architectural seam between read sampling and write propagation - anything that AOFs or replicates belongs on the write path.
- `HASHTABLE_ITER_SKIP_VALIDATION` opts into iterating invalid/expired entries (defrag, RDB save, some tests). Default iteration filters via `validateEntry`. `randomEntry` must use skip-validation or it loops forever when no valid entries exist.
- When the hashtable stores DB value objects (robj carrying embedded key via `objectSetKeyAndExpire`), `hashtableType.hashFunction` and `keyCompare` MUST derive the name from `objectGetKey(o)`, never `dictEncObjHash`/`hashtableEncObjKeyCompare` on the raw robj - those hash `objectGetVal(o)`, so writes silently collide.
- `lookupKeyRead`'s key argument is a key-name robj. Passing a DB value robj makes it read `objectGetVal` as the name and miss valid keys, tripping `serverAssert(found)` downstream. Unwrap with `objectGetKey(keys[i])` before lookup.
- Shrink-in-progress must be abortable: if an insert pushes `used` above current capacity during shrink rehash, abort-shrink and switch to expand, unless a safe iterator pins the table or abort-shrink is disabled.
- Fair-random sampling picks a fresh cursor per sample; iterating in scan order from a single seed biases toward dense runs once the table is sparse (500x slowdown reproduced). Duplicates across samples are acceptable (distinct from SCAN semantics).
- `hashtableScan` reads `rehash_idx` as authoritative for "source-table indexes already migrated"; skipping those in table 0 prevents double-visit during rehash.
- `iter->num_of_active_buckets` is monotonically non-increasing and `num_of_buckets` is pinned for the iterator's lifetime. Any change that mutates `num_of_buckets` mid-iteration, or lets active grow, breaks exhaustion logic and double-processes.
- Hot callbacks (`validateEntry`, `keyCompare`, `hash`) live in the first cache line of `hashtableType`; cold ones (`rehashingStarted/Completed`, `trackMemUsage`) after. Reordering measurably regresses throughput.
- Do NOT add `__attribute__((hot))` / `always_inline)` to hashtable helpers - overrides PGO data, measurably regresses the find path. Project policy: no optimizer attributes without measured improvement.
- Iterator bucket prefetch is opt-in (`HASHTABLE_ITER_PREFETCH_VALUES`), must respect `entryPrefetchValue`, must skip `OBJ_ENCODING_INT` (pointer is not an address) and NULL. Prefetch pattern: bucket at `i+2`, entries at `i+1`, consume at `i`. Assert misconfig (flag set but callback NULL).

### Grep hazards

- `findBucket` is internal - not public API. Public surface is `hashtable{Find,Insert,Delete,TwoPhase*}`.
- "Next bucket" is ambiguous. `getChildBucket` = intra-chain pointer (within one top-level slot). `getNextBucket` / pointer arithmetic = next top-level INDEX. A single `bucketNext` helper conflating them either skips chained children or walks off the table.
- Stored items are **entries**, not "elements". Callbacks/params reflect it (`fn(void *privdata, void *entry)`). Old dict-era "element" comments in new code are likely bugs.
- During rehash, `bucket_exp[hashtableIsRehashing(ht) ? 1 : 0]` reads the OLD table size. Refactoring the `hashtableIsRehashing` check site must update this ternary or it becomes dead/wrong.
- `hashTypeEntry` is opaque behind `hashTypeEntryGetField`/`GetValue`/`ReplaceValue`. Only `t_hash.c` touches the layout; defrag and other consumers go through accessors.
- `dict` is now `typedef hashtable dict;` in `src/dict.h` (and `src/dict.c` is gone). Callers not yet migrated still use `dict*`/`dictEntry*`: Sentinel, `cluster_legacy.c`, pub/sub patterns, latency, scripting, functions, blocked clients, `subcommands_ht`. `dictEntry->next` and old chaining fields are gone; code casting through them will not compile.

## Object lifecycle (`src/object.c`, `struct serverObject`)

The robj contract (types, encodings, refcount, `OBJ_SHARED_INTEGERS = 10000`, `tryObjectEncoding`, `dismissObject` for CoW) mostly matches Redis. Layout diverges: three bit-flags gate optional fields after the base struct and let one allocation carry expire + key + value, so `objectSet*` may reallocate.

- `hasexpire` - `long long expire` in the allocation (no separate `expires` dict entry).
- `hasembkey` - key SDS in the allocation.
- `hasembval` - value SDS in the allocation (replaces `val_ptr`; base size = `sizeof(robj) - sizeof(void *)`).

Embed budget: `shouldEmbedStringObject` returns true when total size <= **128 bytes** (2 cache lines) counting base + optional expire + optional key SDS + value SDS. The old `OBJ_ENCODING_EMBSTR_SIZE_LIMIT 44` is gone. `KEY_SIZE_TO_INCLUDE_EXPIRE_THRESHOLD = 128`: keys >= 128 bytes pre-reserve expire space even without TTL, avoiding realloc on later `EXPIRE`.

### Invariants

- `objectSetKeyAndExpire(o, key, expire)` and `objectSetExpire(o, expire)` MAY reallocate. Always use the returned pointer; holding the old one is UAF.
- Never dereference `val_ptr` directly when `hasembval` might be set. Use `objectGetVal(o)`.
- `OBJ_ENCODING_EMBSTR` values are logically immutable. Write paths (APPEND, INCR, SETRANGE, bit ops, module StringDMA) MUST allocate a new unembedded copy rather than mutate. The get/set pair is asymmetric: get works on embedded, set does not - any new write helper calling `objectSetVal` on an embstr is a bug class. Use `objectUnembedVal(o)` to convert EMBSTR -> RAW in place.
- Secondary indexes keyed by a DB robj hash via `objectGetKey()`, never `objectGetVal()`. The value payload is mutable and collides across keys with the same value.
- Encoding numbers (for `OBJECT ENCODING`): String `RAW=0`, `INT=1`, `EMBSTR=8`. Hash/Set/ZSet `HASHTABLE=2`, `INTSET=6`, `SKIPLIST=7`, `LISTPACK=11`. List `QUICKLIST=9`, `LISTPACK=11`. Stream `STREAM=10`. Values 3-5 reserved for legacy-RDB compat only; not produced at runtime.

## Encoding transitions

Defaults diverge from Redis and transitions are bidirectional. Do not assume Redis-baseline fill-factor math.

| Config | Valkey default | Redis 7.x default |
|--------|----------------|-------------------|
| `hash-max-listpack-entries` | **512** | 128 |
| `set-max-listpack-entries` | 128 | 128 |
| `zset-max-listpack-entries` | 128 | 128 |
| `set-max-intset-entries` | 512 | 512 |
| listpack-value caps | 64 bytes | 64 bytes |

- Full encoding uses `hashtable` (not `dict`). Sorted Set also keeps a paired skiplist.
- Transitions are bidirectional. Valkey adds `zsetConvertToListpackIfNeeded` (`src/t_zset.c`) and `listTypeTryConvertListpack` (`src/t_list.c` - demotes quicklist -> listpack below half the threshold to avoid oscillation). Do NOT hardcode "listpack -> hashtable" as one-way in variable names or enum values.
- Defrag callbacks (`activeDefragSdsHashtableCallback`, quicklist defrag) ASSERT `ob->type`/`ob->encoding` - they immediately cast `ob->ptr` to a type-specific pointer, so a wrong-type object is a memory-safety issue, not recoverable.
- Intset -> listpack/hashtable gated by `set-max-intset-entries` (default 512).

## Skiplist (`src/t_zset.c`)

Max level 32, p=0.25. Algorithm standard. Layout optimizations:

- SDS element embedded directly after the level array in `zskiplistNode` - single allocation instead of node + sds pointer.
- Header node reuses slots via unions: `score`/`length` and `backward`/`tail` share storage. List `length` and `tail` live **inside the header node**, not in a separate `zskiplist`.
- Level-0 `span` on the header stores max level.
- Grep hazard: `zskiplist` is essentially just the header pointer. Code assuming Redis's separate `length`/`tail` fields reads wrong values.

## vset (`src/vset.c`, `src/vset.h`)

Valkey-only. **Not a user-facing "vector set" command** - internal adaptive container for tracking entries with expiry. Used by hash field expiry (`volatile_fields` inside hash objects), `db->keys_with_volatile_items` bookkeeping, `vsetRemoveExpired(...)` in `src/t_hash.c`. vset is a tagged pointer with four backing shapes that change under you: any code storing a vset reference across a mutation must re-read through `vsetResolve`.

Low 3 bits encode bucket type: `VSET_BUCKET_NONE` (-1), `VSET_BUCKET_SINGLE` (0x1, raw tagged pointer - **entry must be odd-aligned**), `VSET_BUCKET_VECTOR` (0x2, sorted custom SIMD vector), `VSET_BUCKET_HT` (0x4), `VSET_BUCKET_RAX` (0x6). Masks: `VSET_TAG_MASK=0x7`, `VSET_PTR_MASK=~0x7`.

- Anything stored in a vset MUST have LSB available for tagging (odd pointer).
- Growth path: `NONE -> SINGLE -> VECTOR (<=127, sorted by expiry) -> RAX (time-bucket VECTORs) or HT (clustered expiry)`. RAX key = 8-byte big-endian timestamp of bucket end; entries expire strictly before that. Adaptive widths: `VOLATILESET_BUCKET_INTERVAL_MIN=16ms`, `_MAX=8192ms`. On VECTOR overflow (>127): sort, find split between adjacent entries in different time buckets, re-align to finer granularity, else convert to HT.
- `vsetInitIterator` / `vsetNext` are NOT safe - no mutations during iteration. Use `vsetRemoveExpired(max_count, ctx)` for bulk reclaim.
- Sort path stores `vsetGetExpiryFunc` in `_Thread_local current_getter_func` because `qsort_r` is not portable. Each thread owns its own; do not assume cross-thread validity.
- Grep hazard: `pVector` is vset-only (`{len:30, alloc:34, data[]}`, ARM NEON `pvFind` processes 4 pointers/iter). Distinct from the generic `vector` primitive.

## Hash field entry (`src/entry.c`, `src/entry.h`)

Valkey-only. Runtime representation of one hash field/value pair with optional per-field TTL. Used by `t_hash.c` when hash values are stored in the `hashtable` encoding (above the listpack threshold). The stringRef window (taxonomy item 4) lives here.

- Type 1: field is `SDS_TYPE_5` (tiny). Field and value both embedded; expiry NOT supported (SDS_TYPE_5 has no aux bits).
- Type 2+: field is larger SDS. Aux bit on field SDS encodes expiry presence - this is the mechanism for "entry has TTL metadata", read/written via `sdsGetAuxBit` / `sdsSetAuxBit`. Value embedded inline or externalized via `entryUpdateAsStringRef`.
- `EMBED_VALUE_MAX_ALLOC_SIZE = 128` - max allocation to try embedding inline.

### Invariants

- Entries live inside the hash's `hashtable` as the entry pointer; `t_hash.c` wires them via the hashtable's `entryGetKey` callback returning the field SDS.
- `entryUpdateAsStringRef` borrows a caller-owned buffer - callers MUST keep the buffer alive until the entry is freed or re-updated. Use `entryHasStringRef` before assuming ownership on defrag/dismiss paths.
- Read paths MUST NOT lazily reclaim expired fields. Field TTL is filtered by `validateEntry` without deleting; active expire cycle owns reclamation, AOF/replication propagation, and keyspace notifications. Calling `dbReclaimExpiredFields` from HRANDFIELD/HGETALL is a bug.
- Access via `entryGetField`, `entryGetValue(*len)`, `entryGetExpiry`, `entryHasExpiry`, `entryHasStringRef`, `entryIsExpired(against commandTimeSnapshot)`, `entryMemUsage`, `entryDefrag(defragfn, sdsdefragfn)`, `entryDismissMemory`.
