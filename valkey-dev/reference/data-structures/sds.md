# SDS - Simple Dynamic Strings

Use when you need binary-safe strings with O(1) length, preallocation for amortized appends, and C-string compatibility.

Source: `src/sds.c`, `src/sds.h`

---

## Overview

SDS is the fundamental string type used throughout Valkey. The `sds` type is defined as `typedef char *sds` - the pointer returned to callers points directly at the string data, making it compatible with any C function expecting `char *`. The header containing metadata lives immediately before the pointer, accessed by subtracting from it.

Every SDS string is null-terminated, but the stored length makes it binary-safe - it can contain `\0` bytes in the middle.

## Header Variants

SDS selects the smallest header that can represent the string's length, saving memory on short strings (which are the common case in Valkey).

```c
struct __attribute__((__packed__)) sdshdr5 {
    unsigned char flags; /* 3 lsb of type, 5 msb of string length */
    char buf[];
};
struct __attribute__((__packed__)) sdshdr8 {
    uint8_t len;         /* used */
    uint8_t alloc;       /* excluding the header and null terminator */
    unsigned char flags; /* 3 lsb of type, 5 unused bits */
    char buf[];
};
struct __attribute__((__packed__)) sdshdr16 {
    uint16_t len;
    uint16_t alloc;
    unsigned char flags;
    char buf[];
};
struct __attribute__((__packed__)) sdshdr32 {
    uint32_t len;
    uint32_t alloc;
    unsigned char flags;
    char buf[];
};
struct __attribute__((__packed__)) sdshdr64 {
    uint64_t len;
    uint64_t alloc;
    unsigned char flags;
    char buf[];
};
```

| Type | Max Length | Header Size | Notes |
|------|-----------|-------------|-------|
| SDS_TYPE_5 (0) | 31 bytes | 1 byte (flags only) | No alloc tracking; cannot record free space |
| SDS_TYPE_8 (1) | 255 bytes | 3 bytes | Most common for short keys/values |
| SDS_TYPE_16 (2) | 65535 bytes | 5 bytes | |
| SDS_TYPE_32 (3) | ~4 GB | 9 bytes | |
| SDS_TYPE_64 (4) | ~unlimited | 17 bytes | 64-bit platforms only |

The `flags` byte is always at `s[-1]` (one byte before the string pointer). Its 3 lowest bits encode the type; the remaining 5 bits are unused in types 8-64 and can store auxiliary bits via `sdsGetAuxBit`/`sdsSetAuxBit`.

## Memory Layout

```
+---------+------+------+-------+-------------------+----+
| len     | alloc| flags| buf[] (string data)        | \0 |
+---------+------+------+-------------------+--------+----+
                         ^
                         |
                    sds pointer (returned to caller)
```

The type is selected by `sdsReqType()`:

```c
char sdsReqType(size_t string_size) {
    if (string_size < 1 << 5) return SDS_TYPE_5;
    if (string_size <= (1 << 8) - sizeof(struct sdshdr8) - 1) return SDS_TYPE_8;
    if (string_size <= (1 << 16) - sizeof(struct sdshdr16) - 1) return SDS_TYPE_16;
    ...
}
```

## Key Functions

### Creation

| Function | Signature | Purpose |
|----------|-----------|---------|
| `sdsnewlen` | `sds sdsnewlen(const void *init, size_t initlen)` | Create with explicit length (binary-safe) |
| `sdsnew` | `sds sdsnew(const char *init)` | Create from C string (uses strlen) |
| `sdsempty` | `sds sdsempty(void)` | Create zero-length string (uses TYPE_8 for future appends) |
| `sdsdup` | `sds sdsdup(const_sds s)` | Duplicate an existing SDS |
| `sdsfree` | `void sdsfree(sds s)` | Free an SDS string |

Empty strings created with `sdsempty()` are promoted from TYPE_5 to TYPE_8, because TYPE_5 cannot track free space, making it useless for append patterns.

### Concatenation

| Function | Signature | Purpose |
|----------|-----------|---------|
| `sdscat` | `sds sdscat(sds s, const char *t)` | Append C string |
| `sdscatlen` | `sds sdscatlen(sds s, const void *t, size_t len)` | Append binary data |
| `sdscatsds` | `sds sdscatsds(sds s, const_sds t)` | Append another SDS |
| `sdscatprintf` | `sds sdscatprintf(sds s, const char *fmt, ...)` | Append printf-style formatted string |
| `sdscatfmt` | `sds sdscatfmt(sds s, char const *fmt, ...)` | Fast format (subset of printf specifiers) |

All concatenation functions may reallocate and return a new pointer. Callers must always use the return value: `s = sdscat(s, "hello")`.

### Growth and Preallocation

```c
sds sdsMakeRoomFor(sds s, size_t addlen);        // Greedy - doubles up to 1MB, then +1MB
sds sdsMakeRoomForNonGreedy(sds s, size_t addlen); // Exact - allocates only what's needed
```

The greedy strategy in `_sdsMakeRoomFor` with `greedy=1`:

```c
if (newlen < SDS_MAX_PREALLOC)   // SDS_MAX_PREALLOC = 1MB
    newlen *= 2;
else
    newlen += SDS_MAX_PREALLOC;
```

This amortizes repeated appends to O(1) per operation. When the header type must change (e.g., growing from TYPE_8 to TYPE_16), realloc cannot be used - a fresh allocation is made and the data is copied, because the header size differs.

### Other Operations

| Function | Purpose |
|----------|---------|
| `sdsgrowzero(s, len)` | Grow string to `len`, filling with zero bytes |
| `sdscpy(s, t)` | Overwrite content (destructive copy) |
| `sdstrim(s, cset)` | Trim characters in `cset` from both ends |
| `sdsrange(s, start, end)` | Keep only the substring (in-place) |
| `sdscmp(s1, s2)` | Compare two SDS strings (binary-safe memcmp) |
| `sdssplitlen(s, len, sep, seplen, &count)` | Split by separator, returns array of SDS |
| `sdsRemoveFreeSpace(s, would_regrow)` | Reclaim unused allocation |

### Inline Accessors (O(1))

```c
static inline size_t sdslen(const_sds s);    // Current string length
static inline size_t sdsavail(const_sds s);  // Free bytes before realloc needed
static inline size_t sdsalloc(const_sds s);  // Total allocated (len + avail)
```

These access the header by subtracting from the string pointer using the `SDS_HDR` macro:

```c
#define SDS_HDR(T, s) ((struct sdshdr##T *)((s) - (sizeof(struct sdshdr##T))))
```

## Why SDS Over C Strings

| Property | C strings | SDS |
|----------|-----------|-----|
| Length | O(n) strlen | O(1) sdslen |
| Binary safe | No (\0 terminates) | Yes (length-tracked) |
| Buffer overflow | Manual management | Automatic growth |
| Preallocation | None | Greedy doubling up to 1MB |
| Memory info | None | Tracks used and allocated |
| C compat | Native | Direct (null-terminated, char*) |

## Implementation Notes

- All structs use `__attribute__((__packed__))` to prevent padding between fields.
- TYPE_5 is never used for appending; `sdsMakeRoomFor` promotes to TYPE_8 if TYPE_5 would be selected.
- When `s_malloc_usable` returns more memory than requested, `adjustTypeIfNeeded` may promote the type to use the extra space, avoiding a future reallocation.
- The `sdswrite()` function can write an SDS into a caller-provided buffer, used for embedding SDS into other structures (e.g., [skiplist nodes](skiplist.md), [robj](../valkey-specific/object-lifecycle.md)).

## See Also

- [../valkey-specific/object-lifecycle.md](../valkey-specific/object-lifecycle.md) - SDS strings are embedded in robj for EMBSTR encoding and as embedded keys
- [skiplist.md](skiplist.md) - SDS element strings embedded directly in skiplist nodes
- [encoding-transitions.md](encoding-transitions.md) - How string encoding (INT, EMBSTR, RAW) transitions relate to SDS
