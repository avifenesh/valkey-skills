# Three-Layer Memory Architecture

Use when working with valkey-json memory management, understanding how allocations flow through the three layers, debugging memory traps, or investigating per-document memory tracking.

Source: `src/json/memory.h`, `src/json/memory.cc`, `src/json/alloc.h`, `src/json/alloc.cc`, `src/json/stats.h`, `src/json/stats.cc`

## Contents

- [Overview](#overview)
- [Layer 1: memory (Lowest)](#layer-1-memory-lowest)
- [Layer 2: dom_alloc (Middle)](#layer-2-dom_alloc-middle)
- [Layer 3: RapidJsonAllocator (Top)](#layer-3-rapidjsonallocator-top)
- [Memory Traps](#memory-traps)
- [jsn Namespace STL Types](#jsn-namespace-stl-types)
- [Per-Thread TLS Tracking](#per-thread-tls-tracking)
- [Global Atomic Counter](#global-atomic-counter)
- [Per-Document Size Tracking](#per-document-size-tracking)
- [Stats Module](#stats-module)

## Overview

Memory management in valkey-json uses three layers, each adding accounting or safety features:

```
RapidJsonAllocator::Malloc/Free    <-- RapidJSON library calls this
        |
    dom_alloc / dom_free            <-- DOM layer, adds per-thread + global tracking
        |
    memory_alloc / memory_free      <-- Function pointers, adds Valkey accounting + optional traps
        |
    ValkeyModule_Alloc / Free       <-- Valkey engine allocator (jemalloc)
```

Every byte allocated for JSON data passes through all three layers. This ensures:
1. Valkey engine sees accurate memory usage (`MEMORY STATS`).
2. The module tracks its own total (`json_total_memory_bytes`).
3. Per-document sizes can be computed for histograms.
4. Optional trap diagnostics catch memory corruption.

## Layer 1: memory (Lowest)

Function pointers in `memory.h`, set at startup by `memory_traps_control()`:

```cpp
extern void *(*memory_alloc)(size_t size);
extern void (*memory_free)(void *ptr);
extern void *(*memory_realloc)(void *orig_ptr, size_t new_size);
extern size_t (*memory_allocsize)(void *ptr);
```

**Without traps** (default production mode):

```cpp
void *memory_alloc_without_traps(size_t size) {
    void *ptr = ValkeyModule_Alloc(size);
    totalMemoryUsage += ValkeyModule_MallocSize(ptr);
    return ptr;
}
```

Each alloc/free updates `totalMemoryUsage` (a `static std::atomic<size_t>`). `memory_allocsize` delegates to `ValkeyModule_MallocSize`. The `memory_usage()` function returns the atomic counter value.

**With traps** (diagnostic mode):

Same ValkeyModule_Alloc/Free underneath, but wraps each allocation with a prefix and suffix for corruption detection. See [Memory Traps](#memory-traps).

The function pointers are swapped atomically by `memory_traps_control(bool enable)`. Traps can only be toggled when `totalMemoryUsage == 0` (no outstanding allocations).

## Layer 2: dom_alloc (Middle)

Functions in `alloc.h` / `alloc.cc` that wrap `memory_alloc` with per-thread stats tracking:

```cpp
void *dom_alloc(size_t size) {
    void *ptr = memory_alloc(size);
    size_t real_size = memory_allocsize(ptr);
    jsonstats_increment_used_mem(real_size);
    return ptr;
}

void dom_free(void *ptr) {
    size_t size = memory_allocsize(ptr);
    memory_free(ptr);
    jsonstats_decrement_used_mem(size);
}
```

`dom_realloc` handles edge cases: `realloc(ptr, 0)` calls `dom_free`, `realloc(NULL, size)` calls `dom_alloc`. For normal realloc, it computes the delta and calls the appropriate increment/decrement.

Important: `memory_allocsize()` returns the actual allocated size (from jemalloc), which may differ from the requested size. All accounting uses actual sizes.

Convenience functions: `dom_strdup(s)` and `dom_strndup(s, n)` allocate via `dom_alloc` and copy the string.

## Layer 3: RapidJsonAllocator (Top)

The `RapidJsonAllocator` class is the template parameter for all RapidJSON types. It delegates directly to dom_alloc:

```cpp
class RapidJsonAllocator {
    void *Malloc(size_t size)  { return dom_alloc(size); }
    void *Realloc(void *ptr, size_t, size_t newSize) { return dom_realloc(ptr, newSize); }
    static void Free(void *ptr) { dom_free(ptr); }
    static const bool kNeedFree = true;
};
```

A global singleton `allocator` is declared in `dom.h`. All RapidJSON operations that allocate memory (AddMember, PushBack, SetString, etc.) use this allocator. All instances compare equal because there is a single allocation pathway.

## Memory Traps

Traps are a diagnostic shim that catches three classes of corruption:

1. **Double free** - Prefix sentinel is zeroed on free; re-freeing detects invalid sentinel.
2. **Buffer overrun** - Suffix sentinel is checked on every free and validate call.
3. **Dangling pointer** - Voluntary `memory_validate_ptr()` checks both sentinels.

### Trap Data Structures

Each allocation is wrapped:

```
[trap_prefix (8 bytes)] [user data (rounded up to 8 bytes)] [trap_suffix (8 bytes)]
```

**trap_prefix** (8 bytes packed):
```cpp
struct trap_prefix {
    uint64_t length:40;        // actual allocated length
    uint64_t valid_prefix:24;  // sentinel: 0xdeadbe when valid
};
```

**trap_suffix** (8 bytes):
```cpp
struct trap_suffix {
    uint64_t valid_suffix;     // sentinel: 0xdeadfeedbeeff00d when valid
};
```

### Validation

`memory_validate_ptr(ptr, crashOnError)`:
1. Compute prefix location: `(trap_prefix*)ptr - 1`.
2. Check `valid_prefix == 0xdeadbe`. If not, log error, optionally crash.
3. Compute suffix location from prefix + length.
4. Check `valid_suffix == 0xdeadfeedbeeff00d`. If not, dump first 256 bytes of user data for debugging, optionally crash.

The `MEMORY_VALIDATE<T>(ptr)` template is called throughout the codebase (pointer dereferences in GenericValue, KeyTable_Shard, etc.). When traps are disabled, it is a no-op passthrough.

### Trap-aware Allocators

- `memory_alloc_with_traps`: Rounds size up to 8 bytes, allocates size + prefix + suffix, writes sentinels.
- `memory_free_with_traps`: Validates, zeroes prefix sentinel, frees.
- `memory_realloc_with_traps`: Validates old ptr, allocates new, copies, frees old (suboptimal but correct; realloc with traps is rare).
- `memory_allocsize_with_traps`: Returns `prefix->length` (the user-visible size, excluding trap overhead).

### Testing Support

`memory_corrupt_memory(ptr, type)` and `memory_uncorrupt_memory(ptr, type)` deliberately corrupt/restore prefix, length, or suffix for unit testing trap detection.

## jsn Namespace STL Types

The `jsn` namespace provides STL containers that allocate through `memory_alloc`/`memory_free` (but note: the current `stl_allocator` implementation uses `std::malloc`/`std::free` directly - this routes through the C library rather than through the memory trap layer):

```cpp
namespace jsn {
    template<class Elm> using vector = std::vector<Elm, stl_allocator<Elm>>;
    template<class Key, class Compare = std::less<Key>>
        using set = std::set<Key, Compare, stl_allocator<Key>>;
    template<class Key, class Hash = std::hash<Key>, class KeyEqual = std::equal_to<Key>>
        using unordered_set = std::unordered_set<Key, Hash, KeyEqual, stl_allocator<Key>>;
    typedef std::basic_string<char, std::char_traits<char>, stl_allocator<char>> string;
    typedef std::basic_stringstream<char, std::char_traits<char>, stl_allocator<char>> stringstream;
}
```

All module code uses `jsn::string`, `jsn::vector`, etc. instead of `std::string`, `std::vector`. Custom `std::hash<jsn::string>` is provided for use in hash maps.

## Per-Thread TLS Tracking

The stats module uses POSIX thread-local storage to track allocations per thread, enabling per-operation memory delta computation:

```cpp
static pthread_key_t thread_local_mem_counter_key;
```

Initialized by `jsonstats_init()` via `pthread_key_create()`.

**Tracking a write operation**:

```cpp
int64_t begin = jsonstats_begin_track_mem();
// ... perform DOM mutations (dom_alloc/dom_free calls happen) ...
int64_t delta = jsonstats_end_track_mem(begin);
// delta = net memory change for this operation
```

`jsonstats_begin_track_mem()` reads the current TLS counter value. `jsonstats_end_track_mem()` reads it again and returns the difference.

Every `dom_alloc` calls `jsonstats_increment_used_mem(delta)`, which updates both:
1. The global atomic `jsonstats.used_mem`.
2. The per-thread TLS counter via `pthread_getspecific` / `pthread_setspecific`.

Every `dom_free` does the same via `jsonstats_decrement_used_mem(delta)`.

The TLS value is stored as a `void*` cast from `int64_t` (a POSIX TLS convention), avoiding heap allocation for the counter.

## Global Atomic Counter

Two levels of global counters:

**Layer 1** (`memory.cc`): `static std::atomic<size_t> totalMemoryUsage` - tracks all memory_alloc/free calls. Includes everything: DOM data, KeyTable, STL containers. Returned by `memory_usage()`.

**Layer 2** (`stats.cc`): `jsonstats.used_mem` (`std::atomic_ullong`) - tracks dom_alloc/free calls. This is the JSON-specific subset. Returned by `jsonstats_get_used_mem()` and reported as `json_total_memory_bytes` in INFO.

The difference: Layer 1 includes KeyTable overhead and jsn:: STL allocations that go through `memory_alloc` directly. Layer 2 only counts allocations routed through `dom_alloc`.

## Per-Document Size Tracking

Document size (`JDocument::size`) is maintained by the stats module, not the DOM layer:

1. Before a write: `begin = jsonstats_begin_track_mem()`.
2. After a write: `delta = jsonstats_end_track_mem(begin)`.
3. Update: `dom_set_doc_size(doc, orig_size + delta)`.

The histogram bucket (`JDocument::bucket_id`) is updated by `update_doc_hist()` when document size changes buckets. Buckets are:

```
[0, 256, 1K, 4K, 16K, 64K, 256K, 1M, 4M, 16M, 64M, INF]
```

11 buckets, indexed 0-10. `jsonstats_find_bucket()` uses binary search.

## Stats Module

The stats module (`stats.h` / `stats.cc`) provides:

**Counters** (atomic):
- `used_mem` - Total JSON memory
- `num_doc_keys` - Number of JSON document keys
- `max_depth_ever_seen` - Deepest JSON path
- `max_size_ever_seen` - Largest document ever
- `defrag_count` / `defrag_bytes` - Defragmentation metrics

**Histograms** (per-bucket arrays of size_t):
- `doc_hist` - Static: current document size distribution
- `read_hist` - Dynamic: fetched value sizes
- `insert_hist` - Dynamic: inserted value sizes
- `update_hist` - Dynamic: input JSON sizes for updates
- `delete_hist` - Dynamic: deleted value sizes

**Logical stats** (`LogicalStats`): Atomic counters for billing - boolean/number/string/null/array/object counts and character sums.

All histogram data is formatted by `jsonstats_sprint_*_hist()` functions for the `JSON.DEBUG` / INFO output.
