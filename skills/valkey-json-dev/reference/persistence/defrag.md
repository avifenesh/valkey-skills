# Defragmentation

Use when working on the defrag callback, tuning the defrag threshold, understanding memory fragmentation recovery, or investigating defrag-related stats.

Source: `src/json/json.cc` (lines 2354-2378), `src/json/stats.cc` (lines 29-38, 133-146)

## Contents

- [Overview](#overview)
- [Copy-Swap Strategy](#copy-swap-strategy)
- [Defrag Threshold](#defrag-threshold)
- [Why No Stop/Resume](#why-no-stopresume)
- [Stats Tracking](#stats-tracking)
- [Configuration](#configuration)
- [Interaction with Memory Accounting](#interaction-with-memory-accounting)

## Overview

Valkey's active defragmentation subsystem periodically calls registered defrag callbacks to let modules relocate their data, reducing memory fragmentation. The JSON module registers `DocumentType_Defrag` as the defrag callback via the `type_methods.defrag` field during module load (json.cc line 2660).

The callback receives a pointer to the stored value (a `JDocument*`) and can replace it with a freshly allocated copy. Valkey expects the callback to return 0 when it has handled the defrag (or decided to skip it).

## Copy-Swap Strategy

The defrag implementation uses a straightforward copy-swap-free approach (json.cc line 2361):

```c
int DocumentType_Defrag(ValkeyModuleDefragCtx *ctx, ValkeyModuleString *key, void **value) {
    VALKEYMODULE_NOT_USED(ctx);
    VALKEYMODULE_NOT_USED(key);
    ValkeyModule_Assert(*value != nullptr);
    JDocument *orig = static_cast<JDocument*>(*value);
    size_t doc_size = dom_get_doc_size(orig);
    if (doc_size <= json_get_defrag_threshold()) {
        JDocument *new_doc = dom_copy(orig);
        dom_set_bucket_id(new_doc, dom_get_bucket_id(orig));
        *value = new_doc;
        dom_free_doc(orig);
        jsonstats_increment_defrag_count();
        jsonstats_increment_defrag_bytes(doc_size);
    }
    return 0;
}
```

The steps are:

1. Get the original document size from the tracked `doc_size` field.
2. Check if the document is within the defrag threshold.
3. Call `dom_copy(orig)` to create a deep copy of the entire DOM tree. This allocates all new memory, which the allocator places in fresh (contiguous) pages.
4. Preserve the bucket_id from the original (used for histogram stats).
5. Replace the Valkey-held pointer with the new document.
6. Free the original document via `dom_free_doc`, returning fragmented memory to the allocator.
7. Update defrag counters.

The `dom_copy` function performs a full recursive copy of the JDocument tree, including all JValue nodes, strings (via KeyTable handle cloning), and the document metadata. Because the copy allocates everything fresh, the new document occupies contiguous memory pages.

## Defrag Threshold

The threshold controls the maximum document size (in bytes) that defrag will process. Defined in json.cc (line 61):

```c
#define DEFAULT_DEFRAG_THRESHOLD (64 * 1024 * 1024)  // 64MB
```

Documents larger than the threshold are skipped entirely. From the source comment (json.cc line 2367):

> We do not want to defrag a key larger than the default max document size. If there is a need to do that, increase the defrag-threshold config value.

Defrag requires copying the entire document. For a 64MB document, two copies exist simultaneously in memory. A threshold set too high risks doubling the memory footprint during defrag passes on large documents.

The threshold is stored in `config_defrag_threshold` and accessed via `json_get_defrag_threshold()`. It is not currently exposed as a runtime-configurable module config through the `registerModuleConfigs` function - it uses the default value unless modified by a future config registration.

## Why No Stop/Resume

The source comment (json.cc lines 2354-2360) explains the design choice:

> The current implementation does not support defrag stop and resume, which is needed for very large JSON objects.

Valkey's defrag API supports a stop/resume pattern where the module can pause partway through defragging a large value and resume on the next defrag cycle. The JSON module does not implement this because:

1. **Atomic copy** - `dom_copy` is an all-or-nothing operation. There is no facility to partially copy a JDocument tree, pause, and resume later.

2. **Threshold gate** - The 64MB threshold ensures that only moderately sized documents go through defrag, keeping the copy time bounded.

3. **Simplicity** - The copy-swap approach is straightforward and correct. Implementing incremental defrag would require tracking which subtrees have been copied, maintaining mixed old/new pointers, and handling concurrent mutations - all significant complexity for the DOM tree structure.

For workloads with documents exceeding 64MB that suffer from fragmentation, the operator can increase the threshold. The tradeoff is longer defrag pauses and higher peak memory during defrag.

## Stats Tracking

Two atomic counters in the stats subsystem track defrag activity (stats.cc lines 29-30):

```c
std::atomic_ullong defrag_count;  // Number of documents defragged
std::atomic_ullong defrag_bytes;  // Total bytes of documents defragged
```

These are incremented after each successful defrag (json.cc lines 2374-2375):

```c
jsonstats_increment_defrag_count();
jsonstats_increment_defrag_bytes(doc_size);
```

The counters are cumulative - they grow monotonically from module load and are never reset. They are initialized to 0 during `jsonstats_init()` (stats.cc lines 37-38).

Accessor functions (stats.cc lines 133-146):

| Function | Returns |
|----------|---------|
| `jsonstats_get_defrag_count()` | Total documents defragged since load |
| `jsonstats_get_defrag_bytes()` | Total bytes processed by defrag since load |

These stats can be observed via `JSON.DEBUG` commands and the module info callback.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| defrag_threshold | 64MB | Maximum document size for defrag eligibility |

The defrag threshold is currently a compile-time default with a runtime accessor. Unlike `json.max-document-size` and `json.max-path-limit`, it is not registered through `registerModuleConfigs` as a `CONFIG SET`-able parameter. To change it, modify the `DEFAULT_DEFRAG_THRESHOLD` constant and rebuild, or add a module config registration following the existing pattern.

## Interaction with Memory Accounting

The defrag callback does not update `jsonstats_update_stats_on_insert` or `jsonstats_update_stats_on_delete` because the document count and total memory remain the same - only the physical memory layout changes. The `dom_copy` + `dom_free_doc` sequence results in the same tracked `doc_size` because `dom_set_bucket_id` preserves the histogram bucket from the original.

The `DocumentType_Copy` callback (json.cc line 2342) - used by the `COPY` command - does call `jsonstats_update_stats_on_insert` because it creates a new key, unlike defrag which replaces in-place.
