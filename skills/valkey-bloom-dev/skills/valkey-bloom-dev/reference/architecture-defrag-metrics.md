# Defragmentation and INFO metrics

Use when reasoning about active defrag callbacks, cursor-incremental defrag, `bloom-defrag-enabled`, INFO bf sections, or atomic counter tracking.

Source: `src/wrapper/bloom_callback.rs`, `src/metrics.rs`.

## Defrag callback

`bloom_defrag` is wired as the data type's defrag callback, invoked by Valkey's `activedefrag` path. Returns `0` complete, `1` incomplete (resume next call).

Gate: first check is `configs::BLOOM_DEFRAG.load(Relaxed)`. If false, returns 0 immediately. `activedefrag` server-wide must also be on.

## 5-layer defrag order

Per filter, in a loop (steps 1-3):

1. **`BloomFilter` box** - remove from vec, pass pointer to `defrag.alloc()`, re-box result.
2. **Inner `Box<Bloom<[u8]>>`** - swap out via `mem::replace` with a placeholder (see below), `defrag.alloc()`.
3. **Bit vector `Vec<u8>`** - via `realloc_large_heap_allocated_objects(external_vec_defrag)` on the inner `Bloom`.

After all filters (steps 4-5):

4. **`Vec<Box<BloomFilter>>` backing array** - convert to boxed slice, `defrag.alloc()`, reconstruct with `Vec::from_raw_parts` preserving length and capacity.
5. **`BloomObject` top-level** - `defrag.alloc()` via the `value` double pointer.

Each `defrag.alloc()` either returns a new pointer (moved) or null (already in good place).

**Known source bug**: the Vec defrag (step 4) increments `BLOOM_DEFRAG_HITS` in both branches - the null branch should increment `BLOOM_DEFRAG_MISSES`. Slightly inflates the hit counter.

## Cursor-incremental

Large objects yield mid-defrag to avoid blocking:

```rust
let mut cursor = defrag.get_cursor().unwrap_or(0);
while !defrag.should_stop_defrag() && cursor < num_filters as u64 {
    // defrag filter at `cursor`
    cursor += 1;
}
defrag.set_cursor(cursor);
if cursor < num_filters as u64 { return 1; }  // resume later
```

Steps 4-5 run only after all filters are processed.

## DEFRAG_BLOOM_FILTER swap placeholder

The inner `Bloom<[u8]>` must temporarily leave the `BloomFilter` during its own defrag. A global placeholder stands in:

```rust
lazy_static! {
    static ref DEFRAG_BLOOM_FILTER: Mutex<Option<Box<Bloom<[u8]>>>> =
        Mutex::new(Some(Box::new(Bloom::<[u8]>::new(1, 1).unwrap())));
}
```

Swap sequence per filter:

1. `temporary_bloom.take()` to extract placeholder.
2. `mem::replace` the real Bloom out, placeholder in.
3. `defrag.alloc()` on the real Bloom.
4. Vec-defrag via `realloc_large_heap_allocated_objects`.
5. Put real Bloom back.
6. Restore placeholder into the static.

Avoids leaving a null/invalid pointer visible. `Bloom::new(1, 1)` is minimal memory.

## `external_vec_defrag`

Passed as the callback to `realloc_large_heap_allocated_objects`. Pattern: take `Vec<u8>`, `into_boxed_slice` for a stable pointer, `defrag.alloc()`, then reconstruct via `Vec::from_raw_parts(ptr, len, capacity)` preserving original len/capacity. Non-null branch increments `BLOOM_DEFRAG_HITS`; null branch `BLOOM_DEFRAG_MISSES`.

## Config

`bloom-defrag-enabled` (bool, default `true`). Stored as `AtomicBool BLOOM_DEFRAG`. Runtime-toggleable via `CONFIG SET`.

## INFO bf sections

Emitted by `bloom_info_handler` in `src/metrics.rs` via `ctx.builder().add_section(...).field(...).build_section()`:

**`bloom_core_metrics`**

| Field | Counter |
|-------|---------|
| `bloom_total_memory_bytes` | `BLOOM_OBJECT_TOTAL_MEMORY_BYTES` |
| `bloom_num_objects` | `BLOOM_NUM_OBJECTS` |
| `bloom_num_filters_across_objects` | `BLOOM_NUM_FILTERS_ACROSS_OBJECTS` |
| `bloom_num_items_across_objects` | `BLOOM_NUM_ITEMS_ACROSS_OBJECTS` |
| `bloom_capacity_across_objects` | `BLOOM_CAPACITY_ACROSS_OBJECTS` |

**`bloom_defrag_metrics`**

| Field | Counter |
|-------|---------|
| `bloom_defrag_hits` | `BLOOM_DEFRAG_HITS` |
| `bloom_defrag_misses` | `BLOOM_DEFRAG_MISSES` |

## Atomic counter lifecycle

All seven counters are `AtomicU64`/`AtomicUsize` with `Ordering::Relaxed` (metrics don't need strict ordering).

| Event | Updates |
|-------|---------|
| `BloomObject` created | `BLOOM_NUM_OBJECTS +1`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES += object overhead` |
| `BloomFilter` created | `BLOOM_NUM_FILTERS_ACROSS_OBJECTS +1`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES += filter bytes`, `BLOOM_CAPACITY_ACROSS_OBJECTS += capacity` |
| Item added | `BLOOM_NUM_ITEMS_ACROSS_OBJECTS +1` |
| `BloomObject` dropped | `BLOOM_NUM_OBJECTS -1`, memory byte sub |
| `BloomFilter` dropped | filter count sub, memory sub, item sub, capacity sub |
| defrag alloc non-null | `BLOOM_DEFRAG_HITS +1` |
| defrag alloc null | `BLOOM_DEFRAG_MISSES +1` (except Vec step - see bug above) |

## Memory usage and free effort

- `bloom_mem_usage` -> `BloomObject::memory_usage()` - object overhead (incl. Vec capacity) + sum of each filter's `number_of_bytes`. Feeds `MEMORY USAGE`.
- `bloom_free_effort` -> `self.filters.len()`. Valkey uses this as a threshold for async free (higher = more likely async).
