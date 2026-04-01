# Eviction Subsystem

Use when working on eviction policies, LRU/LFU approximation algorithms, maxmemory
enforcement, or understanding how Valkey selects and removes keys under memory pressure.

Source: `src/evict.c`, `src/lrulfu.c`, `src/lrulfu.h`

## Contents

- Overview (line 24)
- Eviction Policies (line 38)
- The Eviction Pool (line 62)
- evictionPoolPopulate() (line 90)
- LRU Clock (line 119)
- LFU Frequency Counter (line 136)
- performEvictions() (line 157)
- Memory Accounting (line 189)
- Eviction Time Limit (line 203)
- Call Graph Summary (line 222)
- Configuration Reference (line 245)

---

## Overview

When `maxmemory` is set and memory usage exceeds the limit, Valkey evicts keys
according to the configured `maxmemory-policy`. The eviction subsystem uses a
sampling-based approximation rather than maintaining a full sorted data structure,
giving O(1) memory overhead with configurable accuracy.

The core loop runs inside `processCommand()` - before every write command, Valkey
checks memory and evicts keys until usage drops below `maxmemory` or the time limit
is reached. If eviction cannot complete immediately, an async time event continues
the work between commands.

---

## Eviction Policies

Eight policies defined in `server.h` as bitmask combinations of `MAXMEMORY_FLAG_LRU`,
`MAXMEMORY_FLAG_LFU`, and `MAXMEMORY_FLAG_ALLKEYS`:

| Policy | Scope | Strategy |
|--------|-------|----------|
| `volatile-lru` | Keys with TTL | Approximate LRU - evict least recently used |
| `volatile-lfu` | Keys with TTL | Approximate LFU - evict least frequently used |
| `volatile-ttl` | Keys with TTL | Evict keys closest to expiration |
| `volatile-random` | Keys with TTL | Random eviction |
| `allkeys-lru` | All keys | Approximate LRU |
| `allkeys-lfu` | All keys | Approximate LFU |
| `allkeys-random` | All keys | Random eviction |
| `noeviction` | N/A | Return OOM error, never evict |

The `volatile-*` policies sample from `db->expires` (keys with TTL set). The
`allkeys-*` policies sample from `db->keys` (all keys). The `MAXMEMORY_FLAG_ALLKEYS`
bit controls this selection.

Default policy is `noeviction`. Default sample size is 5 (`maxmemory-samples`).

---

## The Eviction Pool

The pool makes approximate LRU/LFU work in constant memory, holding the best
eviction candidates found across multiple sampling rounds.

```c
#define EVPOOL_SIZE 16
#define EVPOOL_CACHED_SDS_SIZE 255

struct evictionPoolEntry {
    unsigned long long idle;   /* Idle time (or inverse frequency for LFU) */
    sds key;                   /* Key name */
    sds cached;                /* Pre-allocated SDS buffer for key reuse */
    int dbid;                  /* Database number */
    int slot;                  /* Hash table slot */
};

static struct evictionPoolEntry *EvictionPoolLRU;
```

Sorted array of 16 entries in ascending order by `idle`. Higher `idle` = better
eviction candidate. The `idle` field holds different values depending on policy:
LRU uses seconds since last access, LFU uses `255 - frequency`, and `volatile-ttl`
uses `ULLONG_MAX - expire_time`. Each entry pre-allocates a 255-byte SDS buffer
to avoid repeated allocation for short key names.

---

## evictionPoolPopulate()

```c
int evictionPoolPopulate(serverDb *db, kvstore *samplekvs,
                         struct evictionPoolEntry *pool);
```

Called repeatedly during eviction to feed candidates into the pool. On each call:

1. Selects a random hash table slot via `kvstoreGetFairRandomHashtableIndex()`
2. Samples `server.maxmemory_samples` entries from that slot using
   `kvstoreHashtableSampleEntries()`
3. For each sampled key, computes the idle/score value:
   - LRU/LFU policies: calls `objectGetIdleness(o)` to get idle seconds or inverse
     frequency
   - `volatile-ttl`: computes `ULLONG_MAX - objectGetExpire(o)` so nearer expiry
     scores higher
4. Inserts the entry into the sorted pool if it scores higher than an existing entry
   or if there is an empty slot

The insertion maintains ascending sort order. When the pool is full and the new entry
scores lower than all existing entries, it is discarded. When inserting in the middle,
existing entries are shifted left (discarding the lowest-scoring entry) or right
(into an empty slot).

Returns the number of keys sampled.

---

## LRU Clock

LRU uses a 24-bit timestamp in seconds stored in `robj.lru` (`LRULFU_BITS = 24`).
The clock wraps after 2^24 seconds (approximately 194 days) - if a key is not
accessed for that long, its idle time appears to reset to zero.

Key functions in `lrulfu.c`:

- `lru_import(idle_secs)` - converts idle duration to LRU timestamp relative to now
- `lru_getIdleSecs(lru)` - computes idle seconds by subtracting from current clock
  (unsigned wraparound is intentional)
- `lrulfu_updateClockAndPolicy()` - updates the cached clock from `mstime / 1000`

Resolution is 1000ms. The static `lru_clock` caches current time to avoid syscalls.

---

## LFU Frequency Counter

LFU splits the same 24-bit field into 16 bits (last access in minutes) and 8 bits
(`LOG_C` frequency counter). New keys start at `LFU_INIT_VAL` (5), not zero, so
they survive a few eviction rounds.

Key functions in `lrulfu.c`:

- `LFULogIncr(freq)` - probabilistic increment: `p = 1.0 / (baseval * lfu_log_factor + 1)`
  where `baseval = max(0, freq - LFU_INIT_VAL)`. At 255, never increments.
  `lfu-log-factor` (default 10) controls saturation speed.
- `LFUDecay(lfu)` - decreases frequency by `elapsed_minutes / lfu_decay_time` (one
  step per `lfu-decay-time` minutes, default 1)
- `lfu_touch(lfu)` - decays then increments via `LFUDecay()` + `LFULogIncr()`
- `lfu_getFrequency(lfu, &freq)` - decays and returns frequency without touching

For eviction scoring, `lrulfu_getIdleness()` returns `255 - freq` so less frequently
accessed keys score higher (better eviction candidates).

---

## performEvictions()

```c
int performEvictions(void);
```

Returns: `EVICT_OK` (0), `EVICT_RUNNING` (1), or `EVICT_FAIL` (2).

Called from `processCommand()` in `server.c` before executing write commands when
`server.maxmemory` is set. The full flow:

1. **Safety check** - `isSafeToPerformEvictions()` returns false during script timeout,
   loading, on replicas with `repl-replica-ignore-maxmemory`, or when eviction is
   paused (`PAUSE_ACTION_EVICT`)
2. **Memory check** - `getMaxmemoryState()` calculates how much memory to free. If
   already under the limit, returns `EVICT_OK`
3. **Policy check** - if `noeviction` or import mode, returns `EVICT_FAIL` immediately
4. **Eviction loop** - runs until `mem_freed >= mem_tofree`:
   - For LRU/LFU/TTL policies: populates the eviction pool from all databases, then
     picks the best candidate (highest idle score) from the pool
   - For random policies: picks a random key from a round-robin database scan
   - Deletes the selected key via `dbGenericDelete()`, propagates DEL to AOF and
     replicas, fires keyspace notification
   - Every 16 keys: flushes replica buffers, checks lazy-free progress, checks time
     limit
5. **Time limit** - if eviction exceeds `evictionTimeLimitUs()`, starts an async
   time event via `startEvictionTimeProc()` and returns `EVICT_RUNNING`
6. **Lazy-free wait** - if nothing left to evict but lazy-free jobs are pending, waits
   briefly for background threads to release memory

---

## Memory Accounting

`getMaxmemoryState(total, logical, tofree, level)` computes whether memory exceeds
`maxmemory`. Returns `C_OK` if under, `C_ERR` if over. The `logical` value excludes
replication and AOF buffers (via `freeMemoryGetNotCountedMemory()`) to prevent
feedback loops where eviction-generated DELs grow these buffers.

`freeMemoryGetNotCountedMemory()` returns memory excluded from eviction accounting:
replication buffer excess beyond `repl-backlog-size`, AOF buffer, and slot export
buffers during cluster migration. This prevents resonance where freeing keys
consumes more buffer memory than it releases.

---

## Eviction Time Limit

```c
static unsigned long evictionTimeLimitUs(void);
```

Converts `maxmemory-eviction-tenacity` (0-100) to a microsecond time limit:

- Tenacity 0-10: linear from 0 to 500us (`50 * tenacity`)
- Tenacity 11-99: geometric (15% progression), reaching approximately 2 minutes at 99
- Tenacity 100: unlimited (`ULONG_MAX`)

When the time limit is reached mid-eviction, `startEvictionTimeProc()` schedules an
`aeTimeEvent` that continues eviction in the next event loop iteration. The
`evictionTimeProc()` callback returns 0 to re-fire immediately while
`performEvictions()` returns `EVICT_RUNNING`, or `AE_NOMORE` to stop.

---

## Call Graph Summary

```
processCommand()  [server.c]
  -> performEvictions()  [evict.c]
       -> isSafeToPerformEvictions()
       -> getMaxmemoryState()
            -> freeMemoryGetNotCountedMemory()
       -> evictionPoolPopulate()  (LRU/LFU/TTL policies)
            -> kvstoreGetFairRandomHashtableIndex()
            -> kvstoreHashtableSampleEntries()
            -> objectGetIdleness()  [object.c]
                 -> lrulfu_getIdleness()  [lrulfu.c]
            -> objectGetExpire()  (volatile-ttl only)
       -> dbGenericDelete()
       -> propagateDeletion()
       -> startEvictionTimeProc()  (if time limit reached)
            -> evictionTimeProc()
                 -> performEvictions()  (re-entrant)
```

---

## Configuration Reference

| Config | Default | Description |
|--------|---------|-------------|
| `maxmemory` | 0 (no limit) | Memory limit in bytes |
| `maxmemory-policy` | `noeviction` | Eviction policy selection |
| `maxmemory-samples` | 5 | Keys sampled per eviction round (1-64) |
| `maxmemory-eviction-tenacity` | 10 | Time budget aggressiveness (0-100) |
| `lazyfree-lazy-eviction` | no | Async delete for evicted keys |
| `lfu-log-factor` | 10 | LFU counter logarithmic factor |
| `lfu-decay-time` | 1 | LFU decay period in minutes |
