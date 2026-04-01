# Key API for List Type - Push, Pop, Get, Set, Insert, Delete

Use when manipulating list values in keys using the module API - pushing, popping, accessing by index, inserting, or deleting elements.

Source: `src/module.c` (lines 4614-4905), `src/valkeymodule.h`

## Contents

- [List Direction Constants](#list-direction-constants) (line 20)
- [ListPush](#listpush) (line 27)
- [ListPop](#listpop) (line 50)
- [ListGet](#listget) (line 74)
- [ListSet](#listset) (line 93)
- [ListInsert](#listinsert) (line 111)
- [ListDelete](#listdelete) (line 133)
- [Iteration Pattern](#iteration-pattern) (line 150)

---

## List Direction Constants

```c
#define VALKEYMODULE_LIST_HEAD 0
#define VALKEYMODULE_LIST_TAIL 1
```

## ListPush

```c
int ValkeyModule_ListPush(ValkeyModuleKey *key, int where,
                          ValkeyModuleString *ele);
```

Pushes an element to the head or tail of a list. Creates the key if it does not exist.

Returns `VALKEYMODULE_OK` on success. On failure returns `VALKEYMODULE_ERR` and sets `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | key or ele is NULL |
| `ENOTSUP` | Key exists but is not a list |
| `EBADF` | Key not opened for writing |

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_WRITE);
ValkeyModule_ListPush(key, VALKEYMODULE_LIST_TAIL, argv[2]);
ValkeyModule_CloseKey(key);
```

## ListPop

```c
ValkeyModuleString *ValkeyModule_ListPop(ValkeyModuleKey *key, int where);
```

Removes and returns an element from the head or tail. The returned string must be freed with `ValkeyModule_FreeString()` or auto-managed.

Returns NULL on failure and sets `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | key is NULL |
| `ENOTSUP` | Key is empty or not a list |
| `EBADF` | Key not opened for writing |

```c
ValkeyModuleString *elem = ValkeyModule_ListPop(key, VALKEYMODULE_LIST_HEAD);
if (elem) {
    /* process elem */
    ValkeyModule_FreeString(ctx, elem);
}
```

## ListGet

```c
ValkeyModuleString *ValkeyModule_ListGet(ValkeyModuleKey *key, long index);
```

Returns the element at `index` without removing it (like LINDEX). Zero-based indexing. Negative indices count from the tail (-1 = last element).

The returned string must be freed or is auto-managed.

Returns NULL on failure and sets `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | key is NULL |
| `ENOTSUP` | Key is not a list |
| `EBADF` | Key not opened for reading |
| `EDOM` | Index out of range |

## ListSet

```c
int ValkeyModule_ListSet(ValkeyModuleKey *key, long index,
                         ValkeyModuleString *value);
```

Replaces the element at `index`. Same indexing as `ListGet`.

Returns `VALKEYMODULE_OK` on success or `VALKEYMODULE_ERR` with `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | key or value is NULL |
| `ENOTSUP` | Key is not a list |
| `EBADF` | Key not opened for writing |
| `EDOM` | Index out of range |

## ListInsert

```c
int ValkeyModule_ListInsert(ValkeyModuleKey *key, long index,
                            ValkeyModuleString *value);
```

Inserts an element at `index`. The index is the element's position after insertion. Handles special cases:

- Inserting at index 0 or `-(length+1)` on an existing list prepends (push head)
- Inserting at index `length` or -1 appends (push tail)
- Inserting at 0 or -1 on an empty key creates the list

Returns `VALKEYMODULE_OK` on success or `VALKEYMODULE_ERR` with `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | key or value is NULL |
| `ENOTSUP` | Key is of another type |
| `EBADF` | Key not opened for writing |
| `EDOM` | Index out of range |

## ListDelete

```c
int ValkeyModule_ListDelete(ValkeyModuleKey *key, long index);
```

Removes the element at `index`. If the list becomes empty, the key is automatically deleted.

Returns `VALKEYMODULE_OK` on success or `VALKEYMODULE_ERR` with `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | key is NULL |
| `ENOTSUP` | Key is not a list |
| `EBADF` | Key not opened for writing |
| `EDOM` | Index out of range |

## Iteration Pattern

The internal iterator optimizes sequential access. A simple forward scan is O(N) total rather than O(N^2):

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_READ);
long n = ValkeyModule_ValueLength(key);
for (long i = 0; i < n; i++) {
    ValkeyModuleString *elem = ValkeyModule_ListGet(key, i);
    /* process elem */
    ValkeyModule_FreeString(ctx, elem);
}
ValkeyModule_CloseKey(key);
```

Important caveats:
- After `ListPop`, `ListSet`, or `ListInsert`, the internal iterator is invalidated. The next index-based access requires a linear seek.
- `ListDelete` advances the iterator to the next element rather than invalidating it, so sequential deletion by index is efficient.
- Do not use `ValkeyModule_Call()` to modify the list while the key is open - it confuses the internal iterator. Reopen the key after such modifications.
- Access patterns with indices close together are optimized (seeks from previous position rather than from the ends).
