# Memory: Allocation, Eviction, Defrag, Expiry

All reclamation and allocation paths. Eviction and zmalloc are Redis-baseline; defrag, lazy-free defaults, and expiry diverge.

## zmalloc (`src/zmalloc.c`, `src/zmalloc.h`)

- `zmalloc` / `zcalloc` / `zrealloc` / `zfree` are `#define`d to `valkey_malloc` / `valkey_calloc` / `valkey_realloc` / `valkey_free` in the headers (renamed to avoid zlib symbol collisions). Source uses the `z*` names; stack traces, debuggers, and `nm` output show `valkey_*`. A rename PR with both sides is not a symbol change.

## Eviction (`src/evict.c`, `src/lrulfu.c`)

Sampling-based approximate LRU/LFU, 8 policies, 16-entry eviction pool, `performEvictions()` before any command that may allocate. Same algorithm as Redis.

- Per-field hash TTL does not go through eviction. Field reclaim is the expiry cycle (FIELDS job), not `performEvictions()`. Eviction sampling walks top-level keys only.
- `kvstoreHashtableSampleEntries` tolerates duplicates by design. Starting each sample from a random cursor keeps sparse/high-churn keyspaces off O(N) per eviction. Do not add a `seen` set to dedupe.

## Lazy free (`src/lazyfree.c`)

Background deallocation via BIO; threshold `LAZYFREE_THRESHOLD = 64` elements; `lazyfreeGetFreeEffort()` estimates cost per object type.

All five lazyfree defaults are `yes` in Valkey (Redis defaults are `no`):

```
lazyfree-lazy-eviction     yes
lazyfree-lazy-expire       yes
lazyfree-lazy-server-del   yes
lazyfree-lazy-user-del     yes
lazyfree-lazy-user-flush   yes
```

`DEL`, `FLUSH*`, eviction, expire, and server-side deletes all go to background free unless explicitly turned off. A lazyfree test that passes on Redis defaults is likely not exercising the background path - set the relevant `lazyfree-lazy-*` explicitly when porting.

- Lazyfree counter ordering: producer calls `atomic_fetch_add_explicit(&lazyfree_objects, ..., memory_order_relaxed)` before `bioCreateLazyFreeJob`; BIO worker does `atomic_fetch_sub_explicit(&lazyfree_objects, ...)` + `atomic_fetch_add_explicit(&lazyfreed_objects, ...)` after the actual free. Flipping the order leaks accounting.

## Active defragmentation (`src/defrag.c`, `src/allocator_defrag.c`)

Jemalloc-required (`HAVE_DEFRAG` needs `USE_JEMALLOC` + the experimental.utilization namespace). Valkey-specific:

- `active-defrag-cycle-us` (default **500**): base cycle duration in microseconds; `cycle-min`/`cycle-max` still bound CPU percentage.
- Defrag runs on its own timer event, not inside `serverCron`. Duty cycle `D = P * W / (100 - P)` where P = target CPU%, W = wait time.
- Stages iterate `db->keys`, `db->expires`, and `db->keys_with_volatile_items` (Valkey-only; hashes with per-field TTL).
- Defrag pauses during active child processes (RDB save, AOF rewrite, slot-migration snapshot); `hasActiveChildProcess()` gates in `defrag.c`.
- `DEBUG_FORCE_DEFRAG` build knob lets defrag run without the jemalloc mallctl - debug/tests only.

- Every user-data hashtable is in scope. Missing one (per-hash volatile set, `keys_with_volatile_items`, per-slot kvstores) causes permanent fragmentation visible only through `force-defrag`. Adding a new persistent hashtable = add a defrag stage.
- Type/encoding guards must be `serverAssert`, not silent early-return. The `robj *ob -> quicklist *ql = ob->ptr` cast is unconditional; silently no-oping on wrong-type masks the bug and leaves the cast live in release builds.
- Per-hit time budget, not per-N scans. Check the time budget after every hit. The old per-512-defrag / per-64-scan asymmetry was a latency-target bug.
- Allocator-slab defrag trigger is dual: slab utilization below 1.125x global-average **OR** the small-slab rescue (slab less than 1/8 full even if above threshold) - covers slabs held open by a few immovable allocations.
- Defrag callbacks cannot bypass the supplied `defragfn`. Calling `activeDefragAlloc` directly strips threading and accounting.
- Defrag the stringRef container itself, not only its buffer. Skipping the ref wrapper leaks fragmentation on the metadata even when the underlying value is relocated.
- A new defrag stage without a `hasActiveChildProcess()` pause gate competes with RDB/AOF fork for CoW pages and inflates RSS.

## Expiry (`src/expire.c`, `src/db.c`)

Lazy (`expireIfNeeded` on access) + active (`activeExpireCycle`). Diverges from Redis:

- Two job types in `activeExpireCycle`: per-field TTL on hashes adds a **FIELDS** job alongside the standard **KEYS** job. The cycle alternates priority each tick so neither starves.
- `dbReclaimExpiredFields()` (`src/db.c`) removes expired fields, propagates `HDEL`, fires `hexpired`, and deletes the parent key if the hash becomes empty.
- `db->keys_with_volatile_items` kvstore is the field-expiry candidate pool; keys enter/exit via `dbTrackKeyWithVolatileItems` / `dbUntrackKeyWithVolatileItems`.
- `active-expire-effort` (1-10) scales `keys_per_loop`, `ACTIVE_EXPIRE_CYCLE_ACCEPTABLE_STALE` (default 10%), and cycle time budget.

### Read-path discipline

- Read paths don't reclaim hash fields. HGET, HRANDFIELD, HGETALL, HSCAN, HEXISTS, HLEN, HKEYS, HVALS never call `dbReclaimExpiredFields`, never propagate HDEL, never fire `hexpired`. They skip expired fields via the hashtable's `validateEntry` callback. Hash-field expiry is owned by the active expire cycle. If a read handler appears to need cleanup, raise the random-probe cap or add a bounded validated-scan fallback - do not mutate.
- Active expire runs only when `!server.import_mode && iAmPrimary()` (grep this gate in `expire.c`). Replicas apply HDEL / `hexpired` strictly from the replication stream; a replica-side expiry side-effect is a correctness bug.
- `validateEntry` / `hashHashtableTypeValidate` callbacks are pure predicates. True = include, false = skip. They cannot mutate, propagate, or notify.
- Read commands against hashes with per-field TTLs (HRANDFIELD and similar) iterate in ignore-TTL mode with a bounded retry loop, then return empty if no live field is found. Filtering at probe time inside the random sampler risks infinite loops when most fields are expired.

### Write-path propagation

- TTL-setting commands rewrite relative to absolute PXAT before propagation. HEXPIRE / HPEXPIRE / HSETEX and SET EX/PX/EXAT all rewrite argv to absolute PXAT before AOF/replication so replica/AOF-replay lifetime matches primary regardless of application delay.
- `dbSetValue(overwrite=1)` on a hash with per-field TTL calls `dbUntrackKeyWithVolatileItems` on the old object before freeing, then `dbTrackKeyWithVolatileItems` on the new one. SET/HSET/BITOP-dst/RENAME/RESTORE/MOVE/SORT-STORE/*STORE/GETSET over an existing hash all go through this; missing the untrack leaves the active-expire cycle holding a stale pointer.
- Expired-in-past writes: primary propagates as UNLINK, not as the original command. No non-import-mode node ever stores a negative absolute expire. Import-mode must clamp to `[0, LLONG_MAX]`.
- HSET/HINCRBY over an expired-but-unreclaimed field: emit HDEL before the user write on the replication stream. Otherwise replicas and AOF-replay diverge.
- HSETEX KEEPTTL over an implicitly-expired field: suppress the KEEPTTL propagation and emit an explicit HDEL first. A replica whose field is not yet considered expired would otherwise keep the old TTL or reject the write on encoding mismatch.
- HSETEX FXX / FNX / NX / XX rejections do not propagate. HSETEX with zero fields written cannot leave an empty hash key behind.
- New write-path code that surfaces an expiry to replicas/AOF goes through `deleteExpiredKeyAndPropagate` (and its dict-index variant), not a bare `dbDelete` + notify.
- A single command may emit multiple KSN events (hset + hexpire + hexpired + del when HSET collapses a field into an immediate delete). Consumers cannot assume one event per command.

### Events, RDB, role transitions

- `expire` fires at set-time with a positive future timeout; `expired` fires when the key is actually removed. EXPIRE with a past-or-negative value goes through the expiration path (fires `expired`, increments `expired_keys`), not the DEL path.
- RDB type byte differs by TTL presence. `HSETEX`-loaded hashes serialize as `0x16` (RDB_TYPE_HASH_2); `HPERSIST` rewrites to `0x04`. DUMP/DEBUG OBJECT reflect the current form; `rdbSaveObject` byte counts must match on these transitions.
- RDB load of expired fields does not drop them silently. `valkey-check-rdb` and RESTORE pass `now=0` so the load materializes the field and lets active expire clean up downstream. When `rdbLoadObject` does drop already-expired fields, the primary must propagate an explicit HDEL so replicas and sub-replicas don't diverge. `RDB_LOAD_ERR_ALL_ITEMS_EXPIRED` is the dedicated error code - do not reuse `empty_keys_skipped`.
- RDB / RESTORE loaders defensively reject negative or implausible expire timestamps on any new expiry-bearing payload (hash field TTL, etc.). The historical RDB load path does not guard this.
- Writable-replica expire tracking leaks on promotion. Keys a replica wrote acquire a TTL via `replicaKeysWithExpire`; cleanup happens in the active expire cycle after role transition, not via a config flag.
- Active expire cycles executed while `ProcessingEventsWhileBlocked` (RDB/AOF load, full sync loading, long scripts, long module commands) must not set `el_iteration_active` - the outer iteration already accounts that time.
- `server.current_client` is unreliable in write-path side effects triggered outside a client context: active expiry, `delKeysInSlot -> propagateDeletion`, module cron events, AOF load. Propagation code reaching for `current_client` to recompute slot/context must handle NULL or use a temp client.
