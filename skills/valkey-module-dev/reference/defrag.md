# Defragmentation API - Active Defrag for Module Data Types

Use when implementing active defragmentation for a custom data type, defragmenting global module allocations, or handling incremental defrag with cursors for large data structures.

Source: `src/module.c` (lines 14238-14438), `src/valkeymodule.h` (lines 1364-1433)

## Contents

- [Overview](#overview)
- [Defrag Callback in ValkeyModuleTypeMethods](#defrag-callback-in-valkeymoduletypemethods)
- [DefragAlloc and DefragValkeyModuleString](#defragalloc-and-defragvalkeymodulestring)
- [Incremental Defrag with Cursors](#incremental-defrag-with-cursors)
- [DefragShouldStop - Cooperative Time-Slicing](#defragshouldstop---cooperative-time-slicing)
- [Context Introspection](#context-introspection)
- [Global Defrag Callback](#global-defrag-callback)
- [Complete Example](#complete-example)

---

## Overview

When Valkey runs with active defragmentation enabled (`activedefrag yes`), it relocates memory allocations to reduce fragmentation. Modules with custom data types must participate by providing a defrag callback that can relocate their internal allocations. Without this callback, module data type memory cannot be defragmented.

The defrag context is defined internally as:

```c
struct ValkeyModuleDefragCtx {
    monotime endtime;
    unsigned long *cursor;
    struct serverObject *key;   /* Key name, NULL when unknown */
    int dbid;                   /* Database ID, -1 when unknown */
};
```

---

## Defrag Callback in ValkeyModuleTypeMethods

Register the defrag callback in the `ValkeyModuleTypeMethods` struct when creating your data type:

```c
typedef int (*ValkeyModuleTypeDefragFunc)(
    ValkeyModuleDefragCtx *ctx,
    ValkeyModuleString *key,
    void **value);
```

The callback receives a pointer to your data (`value`) and must attempt to defragment it. Return `0` when defragmentation is complete, or `1` if more work remains (late defrag mode).

```c
ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .free = MyTypeFree,
    .free_effort = MyTypeFreeEffort,
    .defrag = MyTypeDefrag,
    /* ... other callbacks ... */
};
```

### Interaction with free_effort

The `free_effort` callback determines whether defrag happens immediately or in late-defrag mode:

```c
typedef size_t (*ValkeyModuleTypeFreeEffortFunc)(
    ValkeyModuleString *key, const void *value);
```

If `free_effort` returns a value greater than the `active-defrag-max-scan-fields` config, the key enters late-defrag mode. In late-defrag mode, cursors are available for incremental processing. Keys without `free_effort` or with small effort values are defragged immediately in a single pass.

---

## DefragAlloc and DefragValkeyModuleString

These two functions are the core defrag primitives. They attempt to move an allocation to reduce fragmentation.

### DefragAlloc

```c
void *ValkeyModule_DefragAlloc(ValkeyModuleDefragCtx *ctx, void *ptr);
```

Attempts to relocate memory previously allocated with `ValkeyModule_Alloc`, `ValkeyModule_Calloc`, etc. Returns a new pointer if the allocation was moved, or `NULL` if no relocation was needed. When non-NULL is returned, the old pointer is invalid - update all references.

### DefragValkeyModuleString

```c
ValkeyModuleString *ValkeyModule_DefragValkeyModuleString(
    ValkeyModuleDefragCtx *ctx, ValkeyModuleString *str);
```

Defragments a `ValkeyModuleString`. Only works on strings with a single reference. Strings retained with `ValkeyModule_RetainString` or `ValkeyModule_HoldString` typically have multiple references and cannot be defragmented. An exception is retained command argv strings, which end up with a single reference after the command callback returns.

Usage pattern:

```c
void *new_ptr = ValkeyModule_DefragAlloc(ctx, my_struct);
if (new_ptr) {
    *value = new_ptr;  /* Update the value pointer */
    my_struct = new_ptr;
}
```

---

## Incremental Defrag with Cursors

For large data structures, defrag can be split across multiple invocations using cursors. Cursors are only available in late-defrag mode (when `free_effort` exceeds `active-defrag-max-scan-fields`).

### DefragCursorSet

```c
int ValkeyModule_DefragCursorSet(ValkeyModuleDefragCtx *ctx, unsigned long cursor);
```

Store progress before returning `1` from the defrag callback. Returns `VALKEYMODULE_ERR` if not in late-defrag mode.

### DefragCursorGet

```c
int ValkeyModule_DefragCursorGet(ValkeyModuleDefragCtx *ctx, unsigned long *cursor);
```

Retrieve the previously stored cursor on re-entry. Returns `VALKEYMODULE_ERR` if not in late-defrag mode (meaning this is a fresh start).

The server guarantees that concurrent defragmentation of multiple keys will not occur, so modules can safely use local state alongside the cursor.

Example from `tests/modules/defragtest.c`:

```c
int FragDefrag(ValkeyModuleDefragCtx *ctx, ValkeyModuleString *key, void **value) {
    VALKEYMODULE_NOT_USED(key);
    unsigned long i = 0;
    int steps = 0;

    /* Try to resume from cursor */
    if (ValkeyModule_DefragCursorGet(ctx, &i) == VALKEYMODULE_OK) {
        if (i > 0) datatype_resumes++;
    }

    /* Defrag the struct itself */
    struct FragObject *o = ValkeyModule_DefragAlloc(ctx, *value);
    if (o == NULL) {
        o = *value;
    } else {
        *value = o;
    }

    /* Deep defrag - iterate and defrag elements */
    for (; i < o->len; i++) {
        void *new = ValkeyModule_DefragAlloc(ctx, o->values[i]);
        if (new) o->values[i] = new;

        if ((o->maxstep && ++steps > o->maxstep) ||
            ((i % 64 == 0) && ValkeyModule_DefragShouldStop(ctx)))
        {
            ValkeyModule_DefragCursorSet(ctx, i);
            return 1;  /* More work remains */
        }
    }
    return 0;  /* Complete */
}
```

---

## DefragShouldStop - Cooperative Time-Slicing

```c
int ValkeyModule_DefragShouldStop(ValkeyModuleDefragCtx *ctx);
```

Returns non-zero when the defrag time budget is exhausted. Call this periodically during iteration. When it returns true, save your cursor and return `1`. The server will call your defrag callback again later.

Good practice: check every 64 iterations or after each batch of work, as shown in the example above.

---

## Context Introspection

```c
const ValkeyModuleString *ValkeyModule_GetKeyNameFromDefragCtx(
    ValkeyModuleDefragCtx *ctx);
```

Returns the key name being defragmented, or `NULL` if unavailable.

```c
int ValkeyModule_GetDbIdFromDefragCtx(ValkeyModuleDefragCtx *ctx);
```

Returns the database ID of the key, or `-1` if unavailable.

---

## Global Defrag Callback

For module-level allocations not tied to any specific key (e.g., global caches, lookup tables):

```c
int ValkeyModule_RegisterDefragFunc(ValkeyModuleCtx *ctx, ValkeyModuleDefragFunc cb);
```

The callback signature:

```c
typedef void (*ValkeyModuleDefragFunc)(ValkeyModuleDefragCtx *ctx);
```

Unlike the per-key defrag callback, the global callback has no key or cursor support - it runs in a single pass. Register it in `OnLoad` alongside your data type.

---

## Complete Example

From `tests/modules/defragtest.c` - a module with both per-key and global defrag:

```c
/* Global string array defrag */
static void defragGlobalStrings(ValkeyModuleDefragCtx *ctx) {
    for (int i = 0; i < global_strings_len; i++) {
        ValkeyModuleString *new = ValkeyModule_DefragValkeyModuleString(
            ctx, global_strings[i]);
        global_attempts++;
        if (new != NULL) {
            global_strings[i] = new;
            global_defragged++;
        }
    }
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);

    if (ValkeyModule_Init(ctx, "defragtest", 1, VALKEYMODULE_APIVER_1)
        == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;

    if (ValkeyModule_GetTypeMethodVersion() < VALKEYMODULE_TYPE_METHOD_VERSION)
        return VALKEYMODULE_ERR;

    /* Actual module parses argv[0] as global string count */

    ValkeyModuleTypeMethods tm = {
        .version = VALKEYMODULE_TYPE_METHOD_VERSION,
        .free = FragFree,
        .free_effort = FragFreeEffort,
        .defrag = FragDefrag,
    };

    FragType = ValkeyModule_CreateDataType(ctx, "frag_type", 0, &tm);
    if (FragType == NULL) return VALKEYMODULE_ERR;

    ValkeyModule_RegisterInfoFunc(ctx, FragInfo);
    ValkeyModule_RegisterDefragFunc(ctx, defragGlobalStrings);

    return VALKEYMODULE_OK;
}
```

### Testing defrag

From `tests/unit/moduleapi/defrag.tcl`. `activedefrag` requires a build with jemalloc, so the test guards with `catch`:

```tcl
start_server {tags {"modules"} overrides {{save ""}}} {
    r module load $testmodule 10000
    r config set active-defrag-ignore-bytes 1
    r config set active-defrag-threshold-lower 0
    r config set active-defrag-cycle-min 99

    catch {r config set activedefrag yes} e
    if {[r config get activedefrag] eq "activedefrag yes"} {
        test {Module defrag: late defrag with cursor works} {
            r frag.create key2 10000 100 1000
            after 2000
            set info [r info defragtest_stats]
            assert {[getInfoProperty $info defragtest_datatype_resumes] > 10}
            assert_equal 0 [getInfoProperty $info defragtest_datatype_wrong_cursor]
        }
    }
}
```
