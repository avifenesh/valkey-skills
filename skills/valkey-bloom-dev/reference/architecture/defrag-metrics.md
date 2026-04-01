# Defragmentation and INFO Metrics

Use when understanding bloom filter defragmentation callbacks, cursor-based incremental defrag, the DEFRAG_BLOOM_FILTER swap placeholder, bloom-defrag-enabled config, INFO bf sections, or atomic counter tracking.

Source: `src/wrapper/bloom_callback.rs`, `src/metrics.rs`

## Contents

- Defrag Overview (line 21)
- 5-Layer Defrag Order (line 37)
- Cursor-Based Incremental Defrag (line 59)
- DEFRAG_BLOOM_FILTER Swap Placeholder (line 88)
- Bit Vector Defrag Callback (line 110)
- bloom-defrag-enabled Config (line 133)
- INFO bf Sections (line 147)
- Atomic Counter Tracking (line 170)
- Memory Usage Callback (line 199)

---

## Defrag Overview

The `bloom_defrag` function (line 214 of `bloom_callback.rs`) is the data type defrag callback, invoked by Valkey's active defragmentation when `activedefrag yes` is set. It defragments every heap allocation owned by a BloomObject to reduce memory fragmentation.

The function signature:

```rust
pub unsafe extern "C" fn bloom_defrag(
    defrag_ctx: *mut RedisModuleDefragCtx,
    _from_key: *mut RedisModuleString,
    value: *mut *mut c_void,
) -> i32
```

Returns 0 for complete defragmentation, 1 for incomplete (will resume on next call).

## 5-Layer Defrag Order

Each BloomObject has five levels of heap allocation, defragmented in this order:

**Per filter (steps 1-3, in a loop):**

1. **BloomFilter struct** - The boxed `BloomFilter` allocation itself. Removed from the vec, passed to `defrag.alloc()`, re-boxed from the result.

2. **Inner Bloom struct** - The `Box<bloomfilter::Bloom<[u8]>>` inside each BloomFilter. Swapped out via `mem::replace` with a temporary placeholder, then passed to `defrag.alloc()`.

3. **Bit vector** - The `Vec<u8>` inside the crate's `Bloom` struct. Defragmented via the `realloc_large_heap_allocated_objects` callback pattern using `external_vec_defrag`.

**After all filters (steps 4-5):**

4. **Filters Vec** - The `Vec<Box<BloomFilter>>` itself (the backing array). Converted to a boxed slice, passed to `defrag.alloc()`, then reconstructed with `Vec::from_raw_parts` preserving the original length and capacity.

5. **BloomObject** - The top-level struct allocation. Passed to `defrag.alloc()` via the `value` double pointer.

Each `defrag.alloc()` call either returns a new pointer (the allocation was moved to reduce fragmentation) or null (the allocation was already in a good location). Both outcomes are tracked in metrics.

The Vec defrag in step 4 (line 308 of `bloom_callback.rs`) increments `BLOOM_DEFRAG_HITS` in both the hit and miss branches - the else branch should increment `BLOOM_DEFRAG_MISSES`. Known source bug that slightly inflates the hit counter.

## Cursor-Based Incremental Defrag

Large BloomObjects with many sub-filters could block the server if defragmented in one shot. The callback uses Valkey's cursor mechanism to yield between filters:

```rust
let mut cursor = defrag.get_cursor().unwrap_or(0);

while !defrag.should_stop_defrag() && cursor < num_filters as u64 {
    // Defrag filter at index `cursor`
    // ...
    cursor += 1;
}

defrag.set_cursor(cursor);

if cursor < num_filters as u64 {
    return 1;  // Incomplete - resume next time
}
```

The cursor tracks which filter index to resume from. On each invocation:
- If `get_cursor` returns a value, resume from that index
- If it returns `None` (first time or previously completed), start from 0
- `should_stop_defrag()` checks if enough time has been spent
- Return 1 if not all filters were processed, causing Valkey to re-invoke later
- Return 0 after completing all filters plus the Vec and BloomObject defrag

Steps 4 and 5 (Vec and BloomObject defrag) only run after all filters are processed.

## DEFRAG_BLOOM_FILTER Swap Placeholder

During inner Bloom struct defragmentation, the code needs to temporarily move the `Bloom<[u8]>` out of the BloomFilter. A global static placeholder is used for this swap:

```rust
lazy_static! {
    static ref DEFRAG_BLOOM_FILTER: Mutex<Option<Box<Bloom<[u8]>>>> =
        Mutex::new(Some(Box::new(Bloom::<[u8]>::new(1, 1).unwrap())));
}
```

The swap sequence for each filter:

1. Lock the mutex and take the placeholder out: `temporary_bloom.take()`
2. Swap the real Bloom out of the BloomFilter using `mem::replace`, putting the placeholder in its place
3. Attempt to defrag the real Bloom via `defrag.alloc()`
4. Defrag the bit vector via `realloc_large_heap_allocated_objects`
5. Swap the defragmented Bloom back into the BloomFilter
6. Put the placeholder back into the static: `*temporary_bloom = Some(placeholder_bloom)`

Avoids leaving a null or invalid pointer in the BloomFilter during defrag. The placeholder is a minimal `Bloom::new(1, 1)` - capacity 1, 1 item - using negligible memory.

## Bit Vector Defrag Callback

The `external_vec_defrag` function (line 167 of `bloom_callback.rs`) defragments the raw bit vector inside the bloomfilter crate's `Bloom` struct:

```rust
fn external_vec_defrag(vec: Vec<u8>) -> Vec<u8> {
    let defrag = Defrag::new(core::ptr::null_mut());
    let len = vec.len();
    let capacity = vec.capacity();
    let vec_ptr = Box::into_raw(vec.into_boxed_slice()) as *mut c_void;
    let defragged_filters_ptr = unsafe { defrag.alloc(vec_ptr) };
    if !defragged_filters_ptr.is_null() {
        metrics::BLOOM_DEFRAG_HITS.fetch_add(1, Ordering::Relaxed);
        unsafe { Vec::from_raw_parts(defragged_filters_ptr as *mut u8, len, capacity) }
    } else {
        metrics::BLOOM_DEFRAG_MISSES.fetch_add(1, Ordering::Relaxed);
        unsafe { Vec::from_raw_parts(vec_ptr as *mut u8, len, capacity) }
    }
}
```

This function is passed as a callback to `realloc_large_heap_allocated_objects` on the bloomfilter crate's `Bloom` struct. The crate takes ownership of the Vec, passes it to this callback, and uses the returned Vec. The callback converts the Vec to a boxed slice to get a stable pointer, attempts defrag, and reconstructs with the original length and capacity.

## bloom-defrag-enabled Config

The `bloom-defrag-enabled` configuration (default: true) controls whether defrag runs:

```rust
if !configs::BLOOM_DEFRAG.load(Ordering::Relaxed) {
    return 0;
}
```

First check in `bloom_defrag`. When disabled, the callback returns 0 immediately (indicating complete - no work needed). The config is an `AtomicBool` changeable at runtime via `CONFIG SET bloom-defrag-enabled yes|no`.

Valkey's `activedefrag` must also be enabled for the callback to be invoked at all. `bloom-defrag-enabled` is an additional module-level toggle.

## INFO bf Sections

The `bloom_info_handler` function in `src/metrics.rs` (line 15) populates two sections in the `INFO bf` output:

**Section: bloom_core_metrics**

| Field | Counter | Description |
|-------|---------|-------------|
| `bloom_total_memory_bytes` | `BLOOM_OBJECT_TOTAL_MEMORY_BYTES` | Aggregate memory across all bloom objects |
| `bloom_num_objects` | `BLOOM_NUM_OBJECTS` | Total bloom object count |
| `bloom_num_filters_across_objects` | `BLOOM_NUM_FILTERS_ACROSS_OBJECTS` | Total sub-filter count |
| `bloom_num_items_across_objects` | `BLOOM_NUM_ITEMS_ACROSS_OBJECTS` | Total items stored |
| `bloom_capacity_across_objects` | `BLOOM_CAPACITY_ACROSS_OBJECTS` | Total capacity |

**Section: bloom_defrag_metrics**

| Field | Counter | Description |
|-------|---------|-------------|
| `bloom_defrag_hits` | `BLOOM_DEFRAG_HITS` | Allocations that were moved |
| `bloom_defrag_misses` | `BLOOM_DEFRAG_MISSES` | Allocations already in good location |

The handler uses the `InfoContext` builder pattern: `ctx.builder().add_section("name").field("key", value).build_section()`.

## Atomic Counter Tracking

Seven global `AtomicU64`/`AtomicUsize` counters in `src/metrics.rs` are maintained throughout the object lifecycle:

**Incremented on creation:**

| Event | Counters Updated |
|-------|-----------------|
| BloomObject created | `BLOOM_NUM_OBJECTS +1`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES +object_overhead` |
| BloomFilter created | `BLOOM_NUM_FILTERS_ACROSS_OBJECTS +1`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES +filter_bytes`, `BLOOM_CAPACITY_ACROSS_OBJECTS +capacity` |
| Item added | `BLOOM_NUM_ITEMS_ACROSS_OBJECTS +1` |
| Scale-out | Memory bytes updated for vec capacity change |

**Decremented on drop:**

| Event | Counters Updated |
|-------|-----------------|
| BloomObject dropped | `BLOOM_NUM_OBJECTS -1`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES -object_overhead` |
| BloomFilter dropped | `BLOOM_NUM_FILTERS_ACROSS_OBJECTS -1`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES -filter_bytes`, `BLOOM_NUM_ITEMS_ACROSS_OBJECTS -num_items`, `BLOOM_CAPACITY_ACROSS_OBJECTS -capacity` |

**Updated on defrag:**

| Event | Counter |
|-------|---------|
| `defrag.alloc` returns non-null | `BLOOM_DEFRAG_HITS +1` |
| `defrag.alloc` returns null | `BLOOM_DEFRAG_MISSES +1` |

All counters use `Ordering::Relaxed` since exact precision is not required for metrics - eventual consistency across threads is acceptable.

## Memory Usage Callback

The `bloom_mem_usage` function (line 110 of `bloom_callback.rs`) reports per-key memory for the `MEMORY USAGE` command:

```rust
pub unsafe extern "C" fn bloom_mem_usage(value: *const c_void) -> usize {
    let item = &*value.cast::<BloomObject>();
    item.memory_usage()
}
```

Delegates to `BloomObject::memory_usage()`, which sums: the object struct overhead (`compute_size` with vec capacity) plus `number_of_bytes()` for each filter.

The `bloom_free_effort` callback (line 138) returns `self.filters.len()` - the filter count. Valkey uses this to decide whether to free the object asynchronously (higher effort = more likely async).