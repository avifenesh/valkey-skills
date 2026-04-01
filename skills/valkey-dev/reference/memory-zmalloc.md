# zmalloc - Memory Allocator Wrapper

Use when you need to understand how Valkey tracks memory usage, wraps the
underlying allocator, or when debugging memory accounting discrepancies.

Source: `src/zmalloc.c`, `src/zmalloc.h`

## Contents

- Overview (line 21)
- Compile-Time Allocator Selection (line 40)
- Memory Tracking Architecture (line 75)
- Core Allocation Functions (line 112)
- Memory Reporting (line 186)
- jemalloc Background Thread and Purge (line 240)
- CoW Optimization: zmadvise_dontneed (line 253)

---

## Overview

Every heap allocation in Valkey goes through the `zmalloc` layer. It serves
two purposes: (1) provide a uniform API that works across jemalloc, tcmalloc,
and libc malloc, and (2) maintain a running total of memory consumed so the
server can enforce `maxmemory` and report `used_memory` in `INFO`.

The symbols `zmalloc`, `zcalloc`, `zrealloc`, and `zfree` are preprocessor-renamed
to `valkey_malloc`, `valkey_calloc`, etc. to avoid collisions with zlib:

```c
#define zmalloc  valkey_malloc
#define zcalloc  valkey_calloc
#define zrealloc valkey_realloc
#define zfree    valkey_free
```

---

## Compile-Time Allocator Selection

The allocator is chosen at build time via `USE_JEMALLOC`, `USE_TCMALLOC`, or
falling back to libc. The header resolves this into a common `zmalloc_size()`
macro that queries the actual usable size of an allocation:

```c
#if defined(USE_TCMALLOC)
#define zmalloc_size(p) tc_malloc_size(p)
#elif defined(USE_JEMALLOC)
#define zmalloc_size(p) je_malloc_usable_size(p)
#elif defined(__APPLE__)
#define zmalloc_size(p) malloc_size(p)
#elif defined(__GLIBC__) || defined(__FreeBSD__) ...
#define zmalloc_size(p) malloc_usable_size(p)
#endif
```

When `HAVE_MALLOC_SIZE` is defined (jemalloc, tcmalloc, macOS, glibc), the
allocator itself reports usable sizes and no per-allocation header is needed
(`PREFIX_SIZE == 0`). When the allocator cannot report sizes, zmalloc prepends
an 8-byte header storing the requested size (`PREFIX_SIZE == 8` on 64-bit).

The actual `malloc`/`free` calls are also redirected:

```c
#if defined(USE_JEMALLOC)
#define malloc(size) je_malloc(size)
#define free(ptr)    je_free(ptr)
// ...
#endif
```

---

## Memory Tracking Architecture

Valkey uses per-thread counters instead of a single atomic counter. This avoids
cache-line bouncing across I/O threads:

```c
#define MAX_THREADS_NUM (IO_THREADS_MAX_NUM + 3 + 1)
static thread_local int thread_index = -1;

// On x86/ARM/PowerPC - plain aligned array (safe due to aligned stores):
static __attribute__((aligned(CACHE_LINE_SIZE)))
    size_t used_memory_thread_padded[MAX_THREADS_NUM + PADDING_ELEMENT_NUM];

// On other architectures - atomic array:
static __attribute__((aligned(CACHE_LINE_SIZE)))
    _Atomic size_t used_memory_thread_padded[MAX_THREADS_NUM + PADDING_ELEMENT_NUM];
```

Each thread gets an index on its first allocation via
`zmalloc_register_thread_index()`. The update functions are inlined:

```c
static inline void update_zmalloc_stat_alloc(size_t size) {
    if (unlikely(thread_index == -1)) zmalloc_register_thread_index();
    if (unlikely(thread_index >= MAX_THREADS_NUM)) {
        atomic_fetch_add_explicit(&used_memory_for_additional_threads, size, ...);
    } else {
        used_memory_thread[thread_index] += size;
    }
}
```

Threads beyond `MAX_THREADS_NUM` (e.g. from loaded modules) fall back to a
single atomic counter `used_memory_for_additional_threads`.

---

## Core Allocation Functions

### zmalloc / ztrymalloc

```c
void *zmalloc(size_t size);      // Allocate or abort on OOM
void *ztrymalloc(size_t size);   // Allocate or return NULL
```

Both call `ztrymalloc_usable_internal()`, which:

1. Guards against overflow (`size >= SIZE_MAX / 2`)
2. Calls `malloc(MALLOC_MIN_SIZE(size) + PREFIX_SIZE)`
3. Queries `zmalloc_size()` to get the actual usable size
4. Updates the per-thread counter
5. Returns the pointer (offset by `PREFIX_SIZE` if no `HAVE_MALLOC_SIZE`)

### zcalloc

```c
void *zcalloc(size_t size);
void *zcalloc_num(size_t num, size_t size);  // Safe multiplication check
```

Zero-initialized allocation. `zcalloc_num` guards against integer overflow
before multiplying `num * size`.

### zrealloc

```c
void *zrealloc(void *ptr, size_t size);
```

Handles edge cases: `size == 0` redirects to `zfree`, `ptr == NULL` redirects
to `zmalloc`. Subtracts old size from the counter, adds new size.

### zfree / zfree_with_size

```c
void zfree(void *ptr);
void zfree_with_size(void *ptr, size_t size);
```

`zfree` queries `zmalloc_size()` to determine how much to subtract from the
counter. `zfree_with_size` skips the query when the caller already knows the
size - used on the jemalloc fast path via `je_sdallocx()`:

```c
static inline void zfree_internal(void *ptr, size_t size) {
    update_zmalloc_stat_free(size);
#ifdef USE_JEMALLOC
    je_sdallocx(ptr, size, 0);   // sized deallocation - faster
#else
    free(ptr);
#endif
}
```

### Usable-size variants

```c
void *zmalloc_usable(size_t size, size_t *usable);
void *zcalloc_usable(size_t size, size_t *usable);
void *zrealloc_usable(void *ptr, size_t size, size_t *usable);
```

These return the actual usable size through an output parameter. Callers can
safely use the extra bytes (jemalloc rounds up to size classes). The
`extend_to_usable()` function is called to inform the compiler that the
returned pointer is valid for `usable` bytes, preventing `-Wstringop-overread`
with GCC 12+ and LTO.

---

## Memory Reporting

### zmalloc_used_memory

```c
size_t zmalloc_used_memory(void) {
    size_t um = 0;
    int threads_num = total_active_threads;
    if (unlikely(total_active_threads > MAX_THREADS_NUM)) {
        um += atomic_load_explicit(&used_memory_for_additional_threads, ...);
        threads_num = MAX_THREADS_NUM;
    }
    for (int i = 0; i < threads_num; i++) {
        um += used_memory_thread[i];
    }
    return um;
}
```

Sums all per-thread counters. This is the value reported as `used_memory` in
`INFO memory`. It reflects only zmalloc-tracked allocations - not RSS, not
jemalloc metadata.

### zmalloc_get_rss

Reads the process RSS from the OS:
- Linux: field 24 of `/proc/self/stat` multiplied by page size
- macOS: `task_info(TASK_BASIC_INFO)`
- FreeBSD/NetBSD/OpenBSD: `sysctl(KERN_PROC)`
- Fallback: returns `zmalloc_used_memory()` (fragmentation appears as 1.0)

### zmalloc_get_allocator_info (jemalloc only)

```c
int zmalloc_get_allocator_info(
    size_t *allocated,  // stats.allocated - all jemalloc allocations
    size_t *active,     // stats.active - pages with allocations
    size_t *resident,   // stats.resident - RSS from jemalloc
    size_t *retained,   // MADV_DONTNEED pages (not in RSS)
    size_t *muzzy);     // MADV_FREE pages (still in RSS until reclaimed)
```

Refreshes jemalloc's epoch and queries stats. The fragmentation ratio is
`active / allocated`. The `INFO memory` field `mem_fragmentation_ratio` is
computed as `RSS / used_memory`.

### Other reporting functions

- `zmalloc_get_memory_size()` - total physical RAM on the machine
- `zmalloc_get_private_dirty(pid)` - Private_Dirty from `/proc/self/smaps`
- `zmalloc_get_smap_bytes_by_field(field, pid)` - arbitrary smaps field

---

## jemalloc Background Thread and Purge

```c
void set_jemalloc_bg_thread(int enable);  // Enable/disable jemalloc bg purging
int jemalloc_purge(void);                 // Force return unused pages to OS
```

After `FLUSHDB`, there may be no traffic to trigger jemalloc's lazy purge.
`set_jemalloc_bg_thread(1)` enables jemalloc's own background thread to purge
dirty pages asynchronously.

---

## CoW Optimization: zmadvise_dontneed

```c
void zmadvise_dontneed(void *ptr, size_t size_hint);
```

Used in fork child processes (RDB save, AOF rewrite) to release pages via
`MADV_DONTNEED`, avoiding copy-on-write when the parent later modifies the
same pages. Only effective on Linux with jemalloc, and only for allocations
larger than one page.

---
