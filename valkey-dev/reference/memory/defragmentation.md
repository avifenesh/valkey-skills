# Active Defragmentation

Use when you need to understand how Valkey reduces external memory
fragmentation at runtime, or when investigating high `mem_fragmentation_ratio`
values.

Source: `src/defrag.c`, `src/allocator_defrag.c`, `src/allocator_defrag.h`

---

## Why Defragmentation Is Needed

Over time, allocations and frees create gaps in jemalloc's slab pages. A slab
may have only a few live objects but cannot be returned to the OS. This
"external fragmentation" causes RSS to grow far beyond actual data size.
Active defrag relocates live objects from sparse slabs into denser ones,
allowing jemalloc to reclaim empty slabs.

Active defrag only works with jemalloc (the vendored version with
`experimental.utilization` support). The `HAVE_DEFRAG` macro gates all defrag
code.

---

## Architecture: Two Layers

```
Application code
   /       \
allocation   defrag
  /           \
zmalloc    allocator_defrag
 /  |   \       /     \
libc  tcmalloc  jemalloc  other
```

- `defrag.c` - orchestrates the scan over all Valkey data structures, decides
  what to defrag, runs in time-bounded cycles
- `allocator_defrag.c` - interfaces with jemalloc to query slab utilization and
  perform defrag-aware allocation/deallocation

---

## allocator_defrag.c - jemalloc Interface

### Initialization

`allocatorDefragInit()` runs once at startup. It:

1. Precomputes MIB (Management Information Base) keys for fast `mallctl` queries
2. Reads the number of bins and per-bin metadata (region size, regions per slab)
3. Validates the reverse mapping from region size to bin index

Key structures:

```c
typedef struct jeBinInfo {
    size_t reg_size;         // Size of each region in the bin
    uint32_t nregs;          // Total regions per slab
    jeBinInfoKeys info_keys; // Precomputed mallctl keys
} jeBinInfo;

typedef struct jemallocBinUsageData {
    size_t curr_slabs;         // Current slab count
    size_t curr_nonfull_slabs; // Non-full slab count
    size_t curr_regs;          // Current live regions
} jemallocBinUsageData;
```

### Should This Pointer Be Defragged?

```c
int allocatorShouldDefrag(void *ptr);
```

Queries jemalloc's `experimental.utilization.batch_query` to get the slab
stats for the pointer's allocation: number of free slots, total slots, and
slab size. Then calls `makeDefragDecision()`:

The decision follows these rules:

- Full slab (`nalloced == nregs`) -> no defrag needed
- Fewer than 2 nonfull slabs -> no defrag needed
- Less than 1/8 full (`1000 * nalloced < nregs * 125`) -> yes, defrag

Otherwise, the decision uses a weighted average across nonfull slabs:

    1000 * nalloced * curr_nonfull_slabs > (1000 + 125) * allocated_nonfull

This checks whether a bin's allocation density is below 87.5% of the average across nonfull slabs (the 125/1000 = 12.5% threshold).

### Defrag-Aware Allocation

```c
void *allocatorDefragAlloc(size_t size);      // je_mallocx with TCACHE_NONE
void allocatorDefragFree(void *ptr, size_t size); // je_sdallocx with TCACHE_NONE
```

Both bypass the thread cache (`MALLOCX_TCACHE_NONE`). This is critical: the
thread cache would return recently freed pointers from the same sparse slab,
defeating defragmentation. Going directly to the arena ensures the new
allocation lands on a different (denser) slab.

### Fragmentation Measurement

```c
float getAllocatorFragmentation(size_t *out_frag_bytes);
```

Computes fragmentation as the percentage of wasted small-bin memory relative to
total allocated memory. This is the metric that drives the defrag cycle's CPU
budget.

---

## defrag.c - Defrag Orchestration

### Stage-Based Design

Defrag work is organized into stages. Each stage processes one target (a
database's keys, expires, pubsub channels, Lua scripts, etc.):

```c
typedef doneStatus (*defragStageFn)(monotime endtime, void *target,
                                    void *privdata);

typedef struct {
    defragStageFn stage_fn;
    void *target;
    void *privdata;
} StageDescriptor;
```

A full cycle adds stages for:
1. Each database's keys kvstore (main scan)
2. Each database's expires kvstore
3. Each database's keys_with_volatile_items kvstore
4. Pubsub channels and shard channels
5. Lua eval scripts
6. Module globals

### Time-Bounded Execution

Defrag runs as an independent timer event, not inside `serverCron`. The timer
fires frequently with short duty cycles:

```c
static long long activeDefragTimeProc(...) {
    int dutyCycleUs = computeDefragCycleUs();
    monotime endtime = starttime + dutyCycleUs;
    // Process stages until endtime
    do {
        status = defrag.current_stage->stage_fn(endtime, ...);
        // If stage finished early with time remaining, start next stage
    } while (haveMoreWork && getMonotonicUs() <= endtime - cycle_us);
    return computeDelayMs(endtime);
}
```

The CPU budget is adaptive. `computeDefragCycleUs()` calculates the duty cycle
from the target CPU percentage and actual wall-clock wait time between calls:

```
D = P * W / (100 - P)
```

Where D = duty time, W = wait time, P = target CPU percent. This provides
starvation protection: if defrag was delayed (e.g. by a slow command), it gets
a proportionally longer duty cycle to catch up.

### Core Defrag Operation

```c
void *activeDefragAlloc(void *ptr) {
    size_t allocation_size;
    void *newptr = activeDefragAllocWithoutFree(ptr, &allocation_size);
    if (newptr) allocatorDefragFree(ptr, allocation_size);
    return newptr;
}
```

The fundamental operation: (1) ask jemalloc if this pointer's slab is sparse,
(2) if yes, allocate a new block bypassing the thread cache, (3) memcpy the
data, (4) free the old block. The caller then updates all pointers that
reference the old location.

### Large Object Deferral

When scanning the main keyspace, large collections (those exceeding
`active_defrag_max_scan_fields`) are added to a `defrag_later` list rather
than being processed inline. This prevents latency spikes from a single
hashtable bucket containing a reference to a million-element hash:

```c
static void defragLater(robj *obj) {
    sds key = sdsdup(objectGetKey(obj));
    listAddNodeTail(defrag_later, key);
}
```

The `defragLaterStep()` function processes these deferred items between main
kvstore scan iterations, looking up the key by name (since the object may have
been modified or deleted in the meantime).

### Data Structure Defrag

Each data structure type has specialized defrag logic:

- **Strings** - defrag the robj and the sds value
- **Lists (quicklist)** - defrag each quicklistNode and its listpack entry
- **Sets (hashtable)** - defrag sds elements via hashtable scan
- **Sorted Sets** - defrag skiplist nodes (requires updating forward/backward
  pointers and the hashtable entry), defrag the hashtable
- **Hashes** - defrag via `hashTypeScanDefrag()`
- **Streams** - defrag the rax tree nodes and listpack data; consumer groups
  and PELs are walked recursively
- **Modules** - delegate to the module's defrag callback

---

## Configuration

| Config | Default | Description |
|--------|---------|-------------|
| `activedefrag` | no | Enable active defragmentation |
| `active-defrag-threshold-lower` | 10 | Min fragmentation % to start |
| `active-defrag-threshold-upper` | 100 | Fragmentation % for max CPU |
| `active-defrag-ignore-bytes` | 100mb | Min frag bytes to start |
| `active-defrag-cycle-min` | 1 | Min CPU % for defrag |
| `active-defrag-cycle-max` | 25 | Max CPU % for defrag |
| `active-defrag-cycle-us` | 500 | Base cycle duration in microseconds |
| `active-defrag-max-scan-fields` | 1000 | Threshold for deferring large keys |

CPU effort is interpolated between `cycle-min` and `cycle-max` based on where
the current fragmentation falls between `threshold-lower` and
`threshold-upper`.

---

## Statistics (INFO memory)

| Metric | Meaning |
|--------|---------|
| `active_defrag_hits` | Successful relocations |
| `active_defrag_misses` | Pointers checked but not relocated |
| `active_defrag_key_hits` | Keys with at least one relocation |
| `active_defrag_key_misses` | Keys scanned with no relocations |
| `total_active_defrag_time` | Cumulative defrag time (milliseconds) |
| `mem_fragmentation_ratio` | RSS / used_memory |

---

## Interaction with Child Processes

Defrag pauses when a child process is active (BGSAVE, BGREWRITEAOF). Moving
memory during fork+CoW would cause unnecessary page copies:

```c
if (hasActiveChildProcess()) {
    defrag.timeproc_end_time = 0;  // prevent starvation recovery
    return 100;                     // poll again in 100ms
}
```

---

## See Also

- [zmalloc](../memory/zmalloc.md) - allocator wrapper layer; `zmalloc_get_allocator_info()` provides the jemalloc stats (allocated, active, resident) used to compute `mem_fragmentation_ratio`
- [Lazy Freeing](../memory/lazy-free.md) - large object deletion that can contribute to fragmentation when the BIO thread frees many scattered allocations
- [Hashtable](../data-structures/hashtable.md) - defrag scans use `hashtableScanDefrag()` to relocate entries within hashtable-backed data structures
- [Latency Monitoring](../monitoring/latency.md) - the `active-defrag-cycle` latency event tracks defrag cycle duration
- [Building Valkey](../build/building.md) - active defrag requires the vendored jemalloc from `deps/jemalloc/` with custom patches for `experimental.utilization` support. Sanitizer builds use `MALLOC=libc` which disables defrag (`HAVE_DEFRAG` is not defined).
