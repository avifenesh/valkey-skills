# Key API for Sorted Set - Add, Remove, Score, Range Iterators

Use when manipulating sorted set values in keys - adding/removing elements, querying scores, or iterating by score or lexicographic range.

Source: `src/module.c` (lines 4906-5352), `src/valkeymodule.h`

## Contents

- [ZsetAdd and ZsetIncrby](#zsetadd-and-zsetincrby) (line 18)
- [ZsetRem and ZsetScore](#zsetrem-and-zsetscore) (line 46)
- [ZADD Flags](#zadd-flags) (line 61)
- [Score Range Iterator](#score-range-iterator) (line 80)
- [Lex Range Iterator](#lex-range-iterator) (line 115)
- [Iterator Navigation](#iterator-navigation) (line 142)

---

## ZsetAdd and ZsetIncrby

```c
int ValkeyModule_ZsetAdd(ValkeyModuleKey *key, double score,
                         ValkeyModuleString *ele, int *flagsptr);
int ValkeyModule_ZsetIncrby(ValkeyModuleKey *key, double score,
                            ValkeyModuleString *ele, int *flagsptr,
                            double *newscore);
```

`ZsetAdd` adds or updates an element. Creates the sorted set if the key is empty and open for writing. `flagsptr` can be NULL if no flags are needed.

`ZsetIncrby` increments the score (or adds with the given score if element is absent). `newscore` receives the new score after increment (can be NULL).

Both return `VALKEYMODULE_ERR` if:
- Key not open for writing
- Key is wrong type
- Score is NaN (ZsetAdd) or increment results in NaN (ZsetIncrby)

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_WRITE);
int flags = VALKEYMODULE_ZADD_NX;
ValkeyModule_ZsetAdd(key, 1.0, argv[2], &flags);
if (flags & VALKEYMODULE_ZADD_ADDED) {
    /* Element was added (did not exist) */
}
```

## ZsetRem and ZsetScore

```c
int ValkeyModule_ZsetRem(ValkeyModuleKey *key, ValkeyModuleString *ele,
                         int *deleted);
int ValkeyModule_ZsetScore(ValkeyModuleKey *key, ValkeyModuleString *ele,
                           double *score);
```

`ZsetRem` removes an element. `deleted` is set to 1 if the element existed, 0 otherwise (can be NULL). Returns `VALKEYMODULE_ERR` only for wrong type or not open for writing - not finding the element is not an error.

`ZsetScore` retrieves the score. Returns `VALKEYMODULE_ERR` if:
- Key is empty or wrong type
- Element does not exist in the sorted set

## ZADD Flags

Input flags (pass via `flagsptr`):

| Flag | Value | Meaning |
|------|-------|---------|
| `VALKEYMODULE_ZADD_XX` | `1<<0` | Only update existing elements |
| `VALKEYMODULE_ZADD_NX` | `1<<1` | Only add new elements |
| `VALKEYMODULE_ZADD_GT` | `1<<5` | Update only if new score > current (combine with XX) |
| `VALKEYMODULE_ZADD_LT` | `1<<6` | Update only if new score < current (combine with XX) |

Output flags (returned in `flagsptr` after the call):

| Flag | Value | Meaning |
|------|-------|---------|
| `VALKEYMODULE_ZADD_ADDED` | `1<<2` | Element was newly added |
| `VALKEYMODULE_ZADD_UPDATED` | `1<<3` | Score was updated |
| `VALKEYMODULE_ZADD_NOP` | `1<<4` | No operation performed (NX/XX condition) |

## Score Range Iterator

```c
int ValkeyModule_ZsetFirstInScoreRange(ValkeyModuleKey *key,
    double min, double max, int minex, int maxex);
int ValkeyModule_ZsetLastInScoreRange(ValkeyModuleKey *key,
    double min, double max, int minex, int maxex);
```

Sets up an iterator positioned at the first (or last) element in the score range. Returns `VALKEYMODULE_ERR` if the key is empty or not a sorted set.

Parameters:
- `min`, `max` - score bounds
- `minex`, `maxex` - if true, bound is exclusive (not included)

Special values for unbounded ranges:

```c
#define VALKEYMODULE_POSITIVE_INFINITE  (1.0/0.0)
#define VALKEYMODULE_NEGATIVE_INFINITE  (-1.0/0.0)
```

```c
/* Iterate all elements with score between 1.0 and 10.0 (inclusive) */
ValkeyModule_ZsetFirstInScoreRange(key, 1.0, 10.0, 0, 0);
while (!ValkeyModule_ZsetRangeEndReached(key)) {
    double score;
    ValkeyModuleString *ele = ValkeyModule_ZsetRangeCurrentElement(key, &score);
    /* process element */
    ValkeyModule_FreeString(ctx, ele);
    ValkeyModule_ZsetRangeNext(key);
}
ValkeyModule_ZsetRangeStop(key);
```

## Lex Range Iterator

```c
int ValkeyModule_ZsetFirstInLexRange(ValkeyModuleKey *key,
    ValkeyModuleString *min, ValkeyModuleString *max);
int ValkeyModule_ZsetLastInLexRange(ValkeyModuleKey *key,
    ValkeyModuleString *min, ValkeyModuleString *max);
```

Sets up an iterator for lexicographic ranges. The `min` and `max` strings use ZRANGEBYLEX format:

- `[value` - inclusive bound
- `(value` - exclusive bound
- `+` - positive infinity
- `-` - negative infinity

Returns `VALKEYMODULE_ERR` if key is empty, not a sorted set, or the range format is invalid. The function does not take ownership of `min`/`max` - they can be freed immediately.

```c
ValkeyModuleString *min = ValkeyModule_CreateString(ctx, "[a", 2);
ValkeyModuleString *max = ValkeyModule_CreateString(ctx, "[z", 2);
ValkeyModule_ZsetFirstInLexRange(key, min, max);
ValkeyModule_FreeString(ctx, min);
ValkeyModule_FreeString(ctx, max);
/* iterate as with score range */
```

## Iterator Navigation

```c
ValkeyModuleString *ValkeyModule_ZsetRangeCurrentElement(ValkeyModuleKey *key,
                                                         double *score);
int ValkeyModule_ZsetRangeNext(ValkeyModuleKey *key);
int ValkeyModule_ZsetRangePrev(ValkeyModuleKey *key);
int ValkeyModule_ZsetRangeEndReached(ValkeyModuleKey *key);
void ValkeyModule_ZsetRangeStop(ValkeyModuleKey *key);
```

`ZsetRangeCurrentElement` returns the current element and optionally its score. Returns NULL if the iterator is exhausted or invalid. The returned string must be freed.

`ZsetRangeNext` / `ZsetRangePrev` advance the iterator. Return 1 if moved successfully, 0 if at the boundary or no active iterator.

`ZsetRangeEndReached` returns 1 when the iterator is exhausted.

`ZsetRangeStop` frees iterator resources. Must be called when done. Also called automatically by `CloseKey`.

Reverse iteration pattern:

```c
ValkeyModule_ZsetLastInScoreRange(key,
    VALKEYMODULE_NEGATIVE_INFINITE,
    VALKEYMODULE_POSITIVE_INFINITE, 0, 0);
while (!ValkeyModule_ZsetRangeEndReached(key)) {
    double score;
    ValkeyModuleString *ele = ValkeyModule_ZsetRangeCurrentElement(key, &score);
    /* process in reverse order */
    ValkeyModule_FreeString(ctx, ele);
    ValkeyModule_ZsetRangePrev(key);
}
ValkeyModule_ZsetRangeStop(key);
```

## See Also

- [key-generic.md](key-generic.md) - OpenKey, CloseKey, KeyType, ValueLength
- [key-hash-stream.md](key-hash-stream.md) - Hash and stream operations
- [key-list.md](key-list.md) - List operations
- [string-objects.md](string-objects.md) - Creating ValkeyModuleString for elements and lex bounds
- [reply-building.md](reply-building.md) - Replying with scores and element arrays
- [../lifecycle/memory.md](../lifecycle/memory.md) - AutoMemory for automatic cleanup of returned strings
- [../advanced/scan.md](../advanced/scan.md) - ScanKey for iterating sorted set elements outside range queries
