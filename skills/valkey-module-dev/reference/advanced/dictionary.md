# Dictionary API - Radix Tree Key-Value Store

Use when a module needs an in-memory sorted dictionary (radix tree) for fast key-value lookups, range iteration, or prefix matching independent of the Valkey keyspace.

Source: `src/module.c` (lines 10526-10778), `src/valkeymodule.h`

## Contents

- [Create and Free](#create-and-free)
- [Set and Replace](#set-and-replace)
- [Get and Delete](#get-and-delete)
- [Size](#size)
- [Iteration](#iteration)
- [Comparison](#comparison)

---

## Create and Free

```c
ValkeyModuleDict *ValkeyModule_CreateDict(ValkeyModuleCtx *ctx);
void ValkeyModule_FreeDict(ValkeyModuleCtx *ctx, ValkeyModuleDict *d);
```

Pass `ctx` if the dictionary lifetime is limited to the callback scope - this enables auto-memory management. Pass NULL if the dictionary will outlive the callback (e.g. stored in module global state). When freeing, pass the same `ctx` used at creation (or NULL).

```c
/* Short-lived dictionary with auto-memory */
ValkeyModuleDict *d = ValkeyModule_CreateDict(ctx);
/* ... use it ... */
ValkeyModule_FreeDict(ctx, d);

/* Long-lived dictionary (module global) */
static ValkeyModuleDict *global_dict = NULL;
/* In OnLoad: */
global_dict = ValkeyModule_CreateDict(NULL);
/* On unload: */
ValkeyModule_FreeDict(NULL, global_dict);
```

## Set and Replace

```c
int ValkeyModule_DictSetC(ValkeyModuleDict *d, void *key, size_t keylen, void *ptr);
int ValkeyModule_DictSet(ValkeyModuleDict *d, ValkeyModuleString *key, void *ptr);
```

Insert a key only if it does not already exist. Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the key already exists.

```c
int ValkeyModule_DictReplaceC(ValkeyModuleDict *d, void *key, size_t keylen, void *ptr);
int ValkeyModule_DictReplace(ValkeyModuleDict *d, ValkeyModuleString *key, void *ptr);
```

Insert or overwrite. Returns `VALKEYMODULE_OK` if the key was newly inserted, `VALKEYMODULE_ERR` if it already existed (value is still replaced).

```c
/* Insert new entry */
ValkeyModule_DictSetC(d, "mykey", 5, my_data_ptr);

/* Overwrite regardless */
ValkeyModule_DictReplaceC(d, "mykey", 5, new_data_ptr);
```

## Get and Delete

```c
void *ValkeyModule_DictGetC(ValkeyModuleDict *d, void *key, size_t keylen, int *nokey);
void *ValkeyModule_DictGet(ValkeyModuleDict *d, ValkeyModuleString *key, int *nokey);
```

Returns the stored pointer, or NULL if the key does not exist. Since NULL is a valid stored value, use the optional `nokey` output to distinguish: `*nokey` is set to 1 if the key was not found, 0 if it was.

```c
int ValkeyModule_DictDelC(ValkeyModuleDict *d, void *key, size_t keylen, void *oldval);
int ValkeyModule_DictDel(ValkeyModuleDict *d, ValkeyModuleString *key, void *oldval);
```

Remove a key. Returns `VALKEYMODULE_OK` if deleted, `VALKEYMODULE_ERR` if not found. If `oldval` is not NULL, `*(void **)oldval` is set to the previous value before deletion.

```c
int nokey;
void *val = ValkeyModule_DictGetC(d, "mykey", 5, &nokey);
if (!nokey) {
    /* Key exists, val is the stored pointer */
}

void *old;
if (ValkeyModule_DictDelC(d, "mykey", 5, &old) == VALKEYMODULE_OK) {
    /* old contains the removed value pointer */
    free_my_data(old);
}
```

## Size

```c
uint64_t ValkeyModule_DictSize(ValkeyModuleDict *d);
```

Returns the number of keys in the dictionary.

## Iteration

Create an iterator positioned by an operator and key:

```c
ValkeyModuleDictIter *ValkeyModule_DictIteratorStartC(
    ValkeyModuleDict *d, const char *op, void *key, size_t keylen);
ValkeyModuleDictIter *ValkeyModule_DictIteratorStart(
    ValkeyModuleDict *d, const char *op, ValkeyModuleString *key);
```

Seek operators:

| Operator | Meaning |
|----------|---------|
| `^` | First element (key ignored, pass NULL/0) |
| `$` | Last element (key ignored, pass NULL/0) |
| `>` | First element greater than key |
| `>=` | First element greater than or equal to key |
| `<` | First element less than key |
| `<=` | First element less than or equal to key |
| `==` | Exact match |

Step through elements:

```c
void *ValkeyModule_DictNextC(ValkeyModuleDictIter *di, size_t *keylen, void **dataptr);
void *ValkeyModule_DictPrevC(ValkeyModuleDictIter *di, size_t *keylen, void **dataptr);
ValkeyModuleString *ValkeyModule_DictNext(ValkeyModuleCtx *ctx,
                                          ValkeyModuleDictIter *di, void **dataptr);
ValkeyModuleString *ValkeyModule_DictPrev(ValkeyModuleCtx *ctx,
                                          ValkeyModuleDictIter *di, void **dataptr);
```

The `C` variants return a raw pointer (valid until the next step or iterator release). The non-`C` variants allocate a `ValkeyModuleString`. Both return NULL when iteration is exhausted.

Reposition an existing iterator:

```c
int ValkeyModule_DictIteratorReseekC(ValkeyModuleDictIter *di,
                                     const char *op, void *key, size_t keylen);
int ValkeyModule_DictIteratorReseek(ValkeyModuleDictIter *di,
                                    const char *op, ValkeyModuleString *key);
```

Release the iterator (mandatory to avoid leaks):

```c
void ValkeyModule_DictIteratorStop(ValkeyModuleDictIter *di);
```

Example - iterate all entries:

```c
ValkeyModuleDictIter *iter = ValkeyModule_DictIteratorStartC(d, "^", NULL, 0);
char *key;
size_t keylen;
void *data;
while ((key = ValkeyModule_DictNextC(iter, &keylen, &data)) != NULL) {
    /* process key/data */
}
ValkeyModule_DictIteratorStop(iter);
```

Example - range scan from "aaa" to "zzz":

```c
ValkeyModuleDictIter *iter = ValkeyModule_DictIteratorStartC(d, ">=", "aaa", 3);
char *key;
size_t keylen;
void *data;
while ((key = ValkeyModule_DictNextC(iter, &keylen, &data)) != NULL) {
    if (ValkeyModule_DictCompareC(iter, "<=", "zzz", 3) != VALKEYMODULE_OK)
        break;
    /* process entries in [aaa, zzz] */
}
ValkeyModule_DictIteratorStop(iter);
```

## Comparison

```c
int ValkeyModule_DictCompareC(ValkeyModuleDictIter *di,
                              const char *op, void *key, size_t keylen);
int ValkeyModule_DictCompare(ValkeyModuleDictIter *di,
                             const char *op, ValkeyModuleString *key);
```

Compare the current iterator position against a key using the same operators as `DictIteratorStart`. Returns `VALKEYMODULE_OK` if the comparison holds, `VALKEYMODULE_ERR` if it does not or the iterator is exhausted. Useful for bounded range iteration.

## See Also

- [scan.md](scan.md) - Scanning the Valkey keyspace (different from dictionary iteration)
- [../data-types/registration.md](../data-types/registration.md) - Custom data types that may use dictionaries internally
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - Auto-memory management context rules
