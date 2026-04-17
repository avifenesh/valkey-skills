# Memory: Allocation, Eviction, Defrag, Expiry

All reclamation and allocation paths. Eviction and zmalloc are mostly Redis-baseline; defrag, lazy-free defaults, and expiry diverge.

## zmalloc (`src/zmalloc.c`, `src/zmalloc.h`)

Standard allocator wrapper over jemalloc / tcmalloc / libc.

**Grep hazard**: `zmalloc` / `zcalloc` / `zrealloc` / `zfree` are `#define`d to `valkey_malloc` / `valkey_calloc` / `valkey_realloc` / `valkey_free` in the headers (renamed to avoid zlib symbol collisions). Source code uses the `z*` names; stack traces, debuggers, and `nm` output show `valkey_*`.

`zmalloc_used_memory()` backs the `used_memory` INFO counter.

## Eviction (`src/evict.c`, `src/lrulfu.c`)

Sampling-based approximate LRU/LFU with 8 policies (volatile|allkeys × LRU|LFU|TTL|random + noeviction), 16-entry eviction pool, `performEvictions()` before any command that may allocate. Same algorithm as Redis.

Nothing Valkey-specific at the eviction algorithm level. Per-field TTL on hashes does **not** go through eviction - field reclaim is the expiry cycle, not eviction.

## Lazy free (`src/lazyfree.c`)

Background deallocation via BIO; threshold `LAZYFREE_THRESHOLD = 64` elements; `lazyfreeGetFreeEffort()` estimates cost per object type. Mechanism same as Redis.

**All five lazyfree defaults are `yes` in Valkey** (Redis defaults are `no`):

```
lazyfree-lazy-eviction     yes
lazyfree-lazy-expire       yes
lazyfree-lazy-server-del   yes
lazyfree-lazy-user-del     yes
lazyfree-lazy-user-flush   yes
```

All flipped in one commit (8.0.0). Testing memory-bound flows in a Valkey environment behaves differently than a Redis-defaults one - `DEL`, `FLUSH*`, eviction, expire, and server-side deletes all go to background free unless explicitly turned off.

## Active defragmentation (`src/defrag.c`, `src/allocator_defrag.c`)

Jemalloc-required (`HAVE_DEFRAG` gate needs `USE_JEMALLOC` + the experimental.utilization namespace). Base model - relocate live objects from sparse slabs into denser ones - matches Redis.

Valkey-specific:

- **`active-defrag-cycle-us`** config (Valkey-only, default **500**): base cycle duration in microseconds. Controls the granularity of time slices; `cycle-min`/`cycle-max` still bound CPU percentage.
- **Defrag runs on its own timer event**, not inside `serverCron`. Duty cycle is adaptive: `D = P * W / (100 - P)` where P = target CPU%, W = wait time.
- **Kvstore-aware scanning**: stages iterate `db->keys`, `db->expires`, and `db->keys_with_volatile_items` - the last one is Valkey-only (hashes with per-field TTL).
- **Defrag pauses during active child processes** (RDB save, AOF rewrite, slot-migration snapshot). Check `hasActiveChildProcess()` gates in `defrag.c`.

Build knob: `DEBUG_FORCE_DEFRAG` lets defrag run without the jemalloc mallctl - debug builds / tests only.

## Expiry (`src/expire.c`, `src/db.c`)

Lazy (`expireIfNeeded` on access) + active (`activeExpireCycle`) follows the Redis model. Diverges:

- **Two job types in `activeExpireCycle`**: per-field TTL on hashes adds a **FIELDS** job alongside the standard **KEYS** job. The cycle alternates priority each tick so neither starves.
- **Field-level reclaim**: `dbReclaimExpiredFields()` (`src/db.c`) removes expired fields, propagates `HDEL` to replicas/AOF, fires the `hexpired` keyspace notification, and deletes the parent key if the hash becomes empty.
- **Candidate pool**: `db->keys_with_volatile_items` kvstore is what the field-expiry job samples. Keys enter/exit via `dbTrackKeyWithVolatileItems` / `dbUntrackKeyWithVolatileItems`.
- **Effort knob**: `active-expire-effort` (1-10) scales `keys_per_loop`, `ACTIVE_EXPIRE_CYCLE_ACCEPTABLE_STALE` (default 10%), and cycle time budget.
