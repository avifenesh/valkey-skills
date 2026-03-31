# Object Lifecycle - The robj (serverObject) Structure

Use when you need to understand how Valkey represents values in memory, how
reference counting works, or when working on encoding conversions and memory
optimization.

Source: `src/object.c` (1,931 lines), `src/server.h` (struct definition)

## Contents

- What This Is (line 27)
- The robj Struct (line 35)
- Memory Layout (line 55)
- Object Types and Encodings (line 80)
- Creation Functions (line 113)
- Embedded Key and Expire (Valkey-Specific) (line 157)
- Value Access (line 179)
- Reference Counting (line 192)
- Shared Integer Objects (line 218)
- Encoding Optimization (line 224)
- Memory Dismissal (CoW Optimization) (line 237)
- OBJECT Command (line 247)
- See Also (line 258)

---

## What This Is

Valkey's `robj` (typedef for `struct serverObject`) is the universal wrapper
for all stored values. Compared to Redis's robj, Valkey's version adds
embedded key and expire fields directly into the object allocation, reducing
pointer chasing and memory overhead. This is a significant Valkey-specific
optimization.

## The robj Struct

```c
struct serverObject {
    unsigned type : 4;        // OBJ_STRING, OBJ_LIST, OBJ_SET, etc.
    unsigned encoding : 4;    // OBJ_ENCODING_RAW, INT, EMBSTR, etc.
    unsigned lru : LRULFU_BITS;  // LRU time or LFU data
    unsigned hasexpire : 1;   // Expire field is embedded after struct
    unsigned hasembkey : 1;   // Key SDS is embedded after struct
    unsigned hasembval : 1;   // Value is embedded (EMBSTR)
    unsigned refcount : OBJ_REFCOUNT_BITS;
    void *val_ptr;            // Value pointer (absent when hasembval=1)
};
static_assert(sizeof(struct serverObject) <= 8 + sizeof(void *));
```

The struct is designed to fit in 16 bytes (on 64-bit) with the `val_ptr`.
When `hasembval=1`, the `val_ptr` field is repurposed for embedded data,
shrinking the base to `sizeof(robj) - sizeof(void *)`.

## Memory Layout

When the value is embedded (EMBSTR encoding):

```
+------+----------+-----+------------+----------+--------+-----------------+---------+-----------+
| type | encoding | lru | has* flags | refcount | expire | key_header_size | key sds | value sds |
+------+----------+-----+------------+----------+--------+-----------------+---------+-----------+
                                                  ^        ^                 ^         ^
                                                  |        |                 |         |
                                           (no val_ptr)   if hasexpire      if hasembkey
```

When the value is NOT embedded:

```
+------+----------+-----+------------+----------+---------+--------+-----------------+---------+
| type | encoding | lru | has* flags | refcount | val_ptr | expire | key_header_size | key sds |
+------+----------+-----+------------+----------+---------+--------+-----------------+---------+
```

The `hasexpire`, `hasembkey`, and `hasembval` bits control which optional
fields are present after the base struct. This variable-length layout is
a Valkey innovation - Redis always stored expire in a separate dict.

## Object Types and Encodings

Types:

```c
#define OBJ_STRING 0
#define OBJ_LIST   1
#define OBJ_SET    2
#define OBJ_ZSET   3
#define OBJ_HASH   4
#define OBJ_MODULE 5
#define OBJ_STREAM 6
```

Encodings:

```c
#define OBJ_ENCODING_RAW       0   // Raw SDS string
#define OBJ_ENCODING_INT       1   // Integer stored in val_ptr
#define OBJ_ENCODING_HASHTABLE 2   // Hash table
#define OBJ_ENCODING_ZIPMAP    3   // Reserved (old RDB compat)
#define OBJ_ENCODING_LINKEDLIST 4  // Reserved (old RDB compat)
#define OBJ_ENCODING_ZIPLIST   5   // Reserved (old RDB compat)
#define OBJ_ENCODING_INTSET    6   // Compact integer set
#define OBJ_ENCODING_SKIPLIST  7   // Skip list + hash table
#define OBJ_ENCODING_EMBSTR    8   // Embedded SDS in the robj allocation
#define OBJ_ENCODING_QUICKLIST 9   // Linked list of listpacks
#define OBJ_ENCODING_STREAM   10   // Radix tree of listpacks
#define OBJ_ENCODING_LISTPACK 11   // Single listpack
```

[NOTE] Values 3-5 (ZIPMAP, LINKEDLIST, ZIPLIST) are reserved for backward compatibility with old RDB files but are no longer used at runtime.

## Creation Functions

Core creation:

```c
robj *createObject(int type, void *val);
```

Internally calls `createUnembeddedObjectWithKeyAndExpire(type, val, NULL, EXPIRY_NONE)`.

String creation with automatic encoding selection:

```c
robj *createStringObject(const char *ptr, size_t len);
```

Calls `shouldEmbedStringObject()` to decide between EMBSTR and RAW.
The embedding threshold: the total allocation (struct + expire + key + value)
must fit in 64 bytes (one cache line).

```c
static bool shouldEmbedStringObject(size_t val_len, const_sds key, long long expire) {
    if (val_len > sdsTypeMaxSize(SDS_TYPE_8)) return false;
    size_t size = sizeof(robj) - sizeof(void *);
    // ... add key, expire, value sizes
    return size <= 64;
}
```

Other creation functions:

```c
robj *createRawStringObject(const char *ptr, size_t len);
robj *createStringObjectFromLongLong(long long value);
robj *createQuicklistObject(int fill, int compress);
robj *createListListpackObject(void);
robj *createSetObject(void);
robj *createIntsetObject(void);
robj *createHashObject(void);
robj *createZsetObject(void);
robj *createStreamObject(void);
robj *createModuleObject(moduleType *mt, void *value);
```

## Embedded Key and Expire (Valkey-Specific)

Valkey embeds the key and expire directly into the robj allocation:

```c
robj *objectSetKeyAndExpire(robj *o, const_sds key, long long expire);
robj *objectSetExpire(robj *o, long long expire);
sds objectGetKey(const robj *o);
mstime_t objectGetExpire(const robj *o);
```

The `objectSetKeyAndExpire` function may reallocate the object. Callers must
use the returned pointer. This eliminates the separate expires dict that
Redis maintained.

For keys larger than 128 bytes, space for expire is pre-reserved even if no
TTL is set, avoiding reallocation when TTL is added later:

```c
#define KEY_SIZE_TO_INCLUDE_EXPIRE_THRESHOLD 128
```

## Value Access

Because the value may or may not be embedded, always use accessors:

```c
void *objectGetVal(const robj *o);   // Navigates embedded data if needed
void objectSetVal(robj *o, void *val);
void objectUnembedVal(robj *o);      // Convert EMBSTR to RAW in-place
```

`objectGetVal` walks the embedded fields (skipping expire, key header, key
SDS) to find the embedded value location when `hasembval=1`.

## Reference Counting

```c
void incrRefCount(robj *o);
void decrRefCount(robj *o);
robj *makeObjectShared(robj *o);
```

Special refcount values:

- `OBJ_SHARED_REFCOUNT` - immutable shared object, never freed
- `OBJ_STATIC_REFCOUNT` - stack-allocated object, panic if retained

When refcount reaches 0 via `decrRefCount`, the type-specific free function
is called:

```c
case OBJ_STRING: freeStringObject(o); break;
case OBJ_LIST:   freeListObject(o);   break;
case OBJ_SET:    freeSetObject(o);    break;
case OBJ_ZSET:   freeZsetObject(o);   break;
case OBJ_HASH:   freeHashObject(o);   break;
case OBJ_MODULE: freeModuleObject(o); break;
case OBJ_STREAM: freeStreamObject(o); break;
```

## Shared Integer Objects

Small integers (0 to `OBJ_SHARED_INTEGERS-1`) are pre-allocated as shared
objects in `shared.integers[]`. `createStringObjectFromLongLong` returns
these shared instances directly.

## Encoding Optimization

```c
robj *tryObjectEncoding(robj *o);
```

Attempts to optimize a string object:

1. If the string represents a number (up to 20 chars), convert to
   `OBJ_ENCODING_INT` (storing the value in the pointer itself).
2. If the string is small enough, convert to `OBJ_ENCODING_EMBSTR`.
3. Otherwise, trim excess allocation from the SDS.

## Memory Dismissal (CoW Optimization)

```c
void dismissObject(robj *o, size_t size_hint);
```

After serializing an object in a fork child (for RDB/AOF), this function
releases physical pages back to the OS via `madvise(MADV_DONTNEED)` to
reduce copy-on-write overhead. Only effective with jemalloc on Linux.

## OBJECT Command

```c
void objectCommand(client *c);
```

Subcommands: `REFCOUNT`, `ENCODING`, `IDLETIME`, `FREQ`, `HELP`.

Uses `objectCommandLookup` which calls `lookupKeyReadWithFlags` with
`LOOKUP_NOTOUCH | LOOKUP_NONOTIFY` to avoid side effects.

## See Also

- [../data-structures/encoding-transitions.md](../data-structures/encoding-transitions.md) - How robj encoding changes based on collection size
- [../data-structures/sds.md](../data-structures/sds.md) - The SDS string type used for RAW and EMBSTR values and embedded keys
- [kvstore.md](kvstore.md) - Where robj entries are stored in the keyspace
- [../architecture/command-dispatch.md](../architecture/command-dispatch.md) - How commands receive `robj` in `c->argv[]`
