# Memory Management - Heap Allocation, AutoMemory, and Pool Allocator

Use when allocating memory in a module, choosing between heap allocation and pool allocation, enabling automatic memory management, or tracking memory usage for eviction.

Source: `src/module.c` (lines 542-663, 2646-2737, 3127-3130, 11409-11437)

## Contents

- Heap Allocation (line 20)
- Try Variants (line 59)
- Memory Size APIs (line 78)
- Pool Allocator (line 108)
- AutoMemory (line 147)
- AutoMemory Internals (line 187)
- TrimStringAllocation (line 213)
- Choosing the Right Allocator (line 217)
- See Also (line 227)

---

## Heap Allocation

Modules must use the `ValkeyModule_*` allocation functions instead of standard `malloc`/`free`. Memory allocated through these APIs is:

- Tracked by INFO memory reporting
- Counted toward maxmemory for eviction decisions
- Accounted for in server memory statistics

```c
void *ValkeyModule_Alloc(size_t bytes);
```

Allocates `bytes` of memory. Panics (aborts the server) if allocation fails. Internally calls `zmalloc_usable()` to allow the compiler to recognize the usable memory size.

```c
void *ValkeyModule_Calloc(size_t nmemb, size_t size);
```

Allocates zero-initialized memory for an array of `nmemb` elements of `size` bytes each. Panics on failure.

```c
void *ValkeyModule_Realloc(void *ptr, size_t bytes);
```

Resizes memory previously obtained with `ValkeyModule_Alloc()`. Panics on failure.

```c
void ValkeyModule_Free(void *ptr);
```

Frees memory obtained by `ValkeyModule_Alloc()`, `ValkeyModule_Calloc()`, or `ValkeyModule_Realloc()`. Never use this to free memory obtained from standard `malloc()`.

```c
char *ValkeyModule_Strdup(const char *str);
```

Duplicates a C string using `ValkeyModule_Alloc()`. The returned string must be freed with `ValkeyModule_Free()`.

## Try Variants

These variants return NULL on failure instead of panicking:

```c
void *ValkeyModule_TryAlloc(size_t bytes);
void *ValkeyModule_TryCalloc(size_t nmemb, size_t size);
void *ValkeyModule_TryRealloc(void *ptr, size_t bytes);
```

Use these when the module can handle allocation failure gracefully - for example, returning an error to the client rather than crashing the server.

```c
void *ptr = ValkeyModule_TryAlloc(large_size);
if (ptr == NULL) {
    return ValkeyModule_ReplyWithError(ctx, "OOM allocation failed");
}
```

## Memory Size APIs

Query the allocated size of memory blocks:

```c
size_t ValkeyModule_MallocSize(void *ptr);
```

Returns the total allocation size of a pointer allocated with `ValkeyModule_Alloc()` and related functions. This is the raw allocation size including allocator overhead.

```c
size_t ValkeyModule_MallocUsableSize(void *ptr);
```

Returns the usable size of the allocation. This may be larger than the requested size because allocators often round up. It is safe to use the extra space reported by this function for pointers obtained from `ValkeyModule_Alloc`, `ValkeyModule_TryAlloc`, `ValkeyModule_Realloc`, or `ValkeyModule_Calloc`.

```c
size_t ValkeyModule_MallocSizeString(ValkeyModuleString *str);
```

Returns the memory size of a ValkeyModuleString, including the object overhead and the SDS string backing it. Only works on string-type objects.

```c
size_t ValkeyModule_MallocSizeDict(ValkeyModuleDict *dict);
```

Returns the overhead of a ValkeyModuleDict structure, including the radix tree. Does not include the size of stored keys and values.

Source: `src/module.c` (lines 11409-11437)

## Pool Allocator

The pool allocator provides fast, short-lived allocations that are automatically freed when the command callback returns. Ideal for temporary buffers and scratch space.

```c
void *ValkeyModule_PoolAlloc(ValkeyModuleCtx *ctx, size_t bytes);
```

Returns word-aligned memory from a pool. Returns NULL if `bytes` is 0.

Key characteristics:

- Memory is freed automatically when the callback returns (via `poolAllocRelease()`)
- Faster than heap allocation for many small allocations
- No realloc - the pool allocator does not support resizing
- Blocks are allocated in chunks of at least 8 KB (`VALKEYMODULE_POOL_ALLOC_MIN_SIZE`)
- Alignment follows `sizeof(void *)` for requests >= word size, otherwise next power of two

Internal block structure:

```c
typedef struct ValkeyModulePoolAllocBlock {
    uint32_t size;
    uint32_t used;
    struct ValkeyModulePoolAllocBlock *next;
    char memory[];  /* Flexible array member */
} ValkeyModulePoolAllocBlock;
```

Source: `src/module.c` (lines 143-148)

The blocks form a linked list through `ctx->pa_head`. When a block runs out of space, a new block is allocated (at least 8 KB or the requested size, whichever is larger).

```c
/* Temporary buffer for processing */
char *buf = ValkeyModule_PoolAlloc(ctx, 256);
/* No need to free - released automatically */
```

## AutoMemory

AutoMemory tracks ValkeyModuleString objects, ValkeyModuleKey handles, and ValkeyModuleCallReply objects, automatically freeing them when the command callback returns.

```c
void ValkeyModule_AutoMemory(ValkeyModuleCtx *ctx);
```

Must be called as the first function in a command implementation that wants automatic memory management. When enabled, these manual cleanup calls become optional:

| Object Type | Manual Free Function |
|-------------|---------------------|
| ValkeyModuleKey | `ValkeyModule_CloseKey()` |
| ValkeyModuleCallReply | `ValkeyModule_FreeCallReply()` |
| ValkeyModuleString | `ValkeyModule_FreeString()` |

Manual free functions still work with AutoMemory enabled, which avoids accumulating objects in loops:

```c
int MyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModule_AutoMemory(ctx);

    /* These are tracked and freed automatically on return */
    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1],
                                                VALKEYMODULE_READ);
    ValkeyModuleCallReply *reply = ValkeyModule_Call(ctx, "GET", "s",
                                                     argv[1]);

    /* But in a tight loop, free manually to avoid buildup */
    for (int i = 0; i < 1000; i++) {
        ValkeyModuleString *s = ValkeyModule_CreateString(ctx, "x", 1);
        /* process s ... */
        ValkeyModule_FreeString(ctx, s);  /* Freed immediately */
    }

    return VALKEYMODULE_OK;
    /* key and reply are freed here automatically */
}
```

## AutoMemory Internals

The auto-memory queue is a dynamically-sized array of `AutoMemEntry` structs:

```c
struct AutoMemEntry {
    void *ptr;
    int type;  /* VALKEYMODULE_AM_STRING, AM_KEY, AM_REPLY, etc. */
};
```

Type constants:

| Constant | Value | Tracks |
|----------|-------|--------|
| `VALKEYMODULE_AM_KEY` | 0 | ValkeyModuleKey handles |
| `VALKEYMODULE_AM_STRING` | 1 | ValkeyModuleString objects |
| `VALKEYMODULE_AM_REPLY` | 2 | ValkeyModuleCallReply objects |
| `VALKEYMODULE_AM_FREED` | 3 | Already freed by user |
| `VALKEYMODULE_AM_DICT` | 4 | ValkeyModuleDict objects |
| `VALKEYMODULE_AM_INFO` | 5 | ValkeyModuleServerInfoData objects |

When a module manually frees an auto-tracked object, the queue entry is marked as `AM_FREED` using a zig-zag scan (checking from both ends) for efficiency. The freed entry is swapped with the last entry to avoid unnecessary queue growth.

At callback return, `autoMemoryCollect()` iterates the queue and frees all remaining tracked objects.

## TrimStringAllocation

See [../commands/string-objects.md](../commands/string-objects.md) for `ValkeyModule_TrimStringAllocation` - trims excess memory from ValkeyModuleString allocations after `RetainString` or `HoldString`.

## Choosing the Right Allocator

| Need | Use |
|------|-----|
| Long-lived data (stored in keys, module state) | `ValkeyModule_Alloc` / `Free` |
| Large allocations that might fail | `ValkeyModule_TryAlloc` |
| Small temporary buffers within a single callback | `ValkeyModule_PoolAlloc` |
| Strings, keys, reply objects within a callback | `ValkeyModule_AutoMemory` |
| Tight loops creating many temporary objects | Manual `Free` even with AutoMemory |
