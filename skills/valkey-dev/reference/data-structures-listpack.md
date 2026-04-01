# Listpack - Compact Sequential Encoding

Use when you need a compact, contiguous-memory container for small collections. Listpack is the small-encoding for Lists, Hashes, Sets, and Sorted Sets.

Source: `src/listpack.c`, `src/listpack.h`

## Contents

- Overview (line 19)
- Header (line 23)
- Entry Format (line 45)
- Key Operations (line 95)
- When Valkey Uses Listpack (line 168)
- Performance Characteristics (line 181)

---

## Overview

A listpack is a serialized sequence of entries in a single contiguous allocation. It stores strings and integers with minimal per-element overhead, offering excellent cache locality at the cost of O(n) random access. Valkey uses it as the compact encoding for small collections, converting to full structures (quicklist, hashtable, skiplist) when thresholds are exceeded.

## Header

Every listpack begins with a 6-byte header:

```
+-------------------+------------------+-----+-----+-----+-----+
| total_bytes (4B)  | num_elements(2B) | e0  | e1  | ... | EOF |
+-------------------+------------------+-----+-----+-----+-----+
```

```c
#define LP_HDR_SIZE 6  /* 32-bit total len + 16-bit number of elements */
#define LP_EOF 0xFF
```

- `total_bytes` (uint32): Total byte length of the entire listpack, including header and EOF marker
- `num_elements` (uint16): Number of entries. Set to `UINT16_MAX` (65535) when the count exceeds that, requiring a full traversal to count

The listpack is terminated by a single `LP_EOF` (0xFF) byte.

Maximum listpack size is 1 GB (`LISTPACK_MAX_SAFETY_SIZE = 1 << 30`) to avoid overflowing the 32-bit total_bytes header.

## Entry Format

Each entry consists of three parts:

```
+----------+------+---------+
| encoding | data | backlen |
+----------+------+---------+
```

1. **Encoding + data**: The encoding byte(s) describe the type and may embed the data directly
2. **Backlen**: A variable-length reverse-encoded length of the entry (encoding + data), enabling backward traversal

### Integer Encodings

| Type | Encoding Byte | Total Entry Size | Range |
|------|--------------|------------------|-------|
| 7-bit uint | `0xxxxxxx` | 2 bytes | 0 to 127 |
| 13-bit int | `110xxxxx` + 1 byte | 3 bytes | -4096 to 4095 |
| 16-bit int | `0xF1` + 2 bytes | 4 bytes | -32768 to 32767 |
| 24-bit int | `0xF2` + 3 bytes | 5 bytes | -8388608 to 8388607 |
| 32-bit int | `0xF3` + 4 bytes | 6 bytes | -2^31 to 2^31-1 |
| 64-bit int | `0xF4` + 8 bytes | 10 bytes | Full int64 range |

Strings that can be parsed as integers are automatically stored using integer encoding.

### String Encodings

| Type | Encoding Bytes | Max Length |
|------|---------------|------------|
| 6-bit str | `10xxxxxx` (1 byte) | 63 bytes |
| 12-bit str | `1110xxxx` + 1 byte (2 bytes) | 4095 bytes |
| 32-bit str | `0xF0` + 4 bytes (5 bytes) | ~4 GB |

### Backlen (Reverse-Encoded Entry Length)

The backlen field encodes the length of the preceding encoding+data portion, using a variable-length format where each byte uses 7 data bits and 1 continuation bit:

```c
static inline unsigned long lpEncodeBacklen(unsigned char *buf, uint64_t l) {
    if (l <= 127)       return 1;   // 1 byte
    if (l < 16383)      return 2;   // 2 bytes
    if (l < 2097151)    return 3;   // 3 bytes
    if (l < 268435455)  return 4;   // 4 bytes
    else                return 5;   // 5 bytes (maximum)
}
```

Bytes with the high bit set indicate continuation (more bytes follow when reading backward). This enables `lpPrev()` to walk backward by reading bytes from the end until a byte without the continuation bit is found.

## Key Operations

### Creation and Lifecycle

```c
unsigned char *lpNew(size_t capacity);  // Allocate with optional pre-allocation
void lpFree(unsigned char *lp);
unsigned char *lpShrinkToFit(unsigned char *lp);
unsigned char *lpDup(unsigned char *lp);
```

### Insertion

```c
unsigned char *lpInsertString(unsigned char *lp, unsigned char *s, uint32_t slen,
                               unsigned char *p, int where, unsigned char **newp);
unsigned char *lpInsertInteger(unsigned char *lp, long long lval,
                                unsigned char *p, int where, unsigned char **newp);
unsigned char *lpAppend(unsigned char *lp, unsigned char *s, uint32_t slen);
unsigned char *lpPrepend(unsigned char *lp, unsigned char *s, uint32_t slen);
```

`where` is one of: `LP_BEFORE`, `LP_AFTER`, `LP_REPLACE`.

All insert/delete operations may reallocate the listpack. The returned pointer is the new listpack base, and `*newp` (if provided) points to the inserted element.

### Deletion

```c
unsigned char *lpDelete(unsigned char *lp, unsigned char *p, unsigned char **newp);
unsigned char *lpDeleteRange(unsigned char *lp, long index, unsigned long num);
unsigned char *lpBatchDelete(unsigned char *lp, unsigned char **ps, unsigned long count);
```

### Traversal

```c
unsigned char *lpFirst(unsigned char *lp);     // First element
unsigned char *lpLast(unsigned char *lp);      // Last element
unsigned char *lpNext(unsigned char *lp, unsigned char *p);   // Forward
unsigned char *lpPrev(unsigned char *lp, unsigned char *p);   // Backward
unsigned char *lpSeek(unsigned char *lp, long index);         // By index (O(n))
```

### Reading Values

```c
unsigned char *lpGet(unsigned char *p, int64_t *count, unsigned char *intbuf);
unsigned char *lpGetValue(unsigned char *p, unsigned int *slen, long long *lval);
```

`lpGet` returns: the string pointer if the entry is a string (with `count` set to the length), or writes the integer into `intbuf` as a string.

`lpGetValue` returns: string pointer with `slen` set, or NULL with `lval` set for integers.

### Search and Compare

```c
unsigned char *lpFind(unsigned char *lp, unsigned char *p, unsigned char *s,
                       uint32_t slen, unsigned int skip);
unsigned int lpCompare(unsigned char *p, unsigned char *s, uint32_t slen);
```

`lpFind` does linear search with optional `skip` to jump over entries (used for key-value pair iteration in hashes: skip=1 means check every other entry).

### Metadata

```c
unsigned long lpLength(unsigned char *lp);  // O(1) if <= 65535, O(n) otherwise
size_t lpBytes(unsigned char *lp);          // Total bytes (O(1), from header)
int lpSafeToAdd(unsigned char *lp, size_t add); // Check 1GB safety limit
```

## When Valkey Uses Listpack

[See also: encoding-transitions.md](encoding-transitions.md) for the full transition table covering all data types.

| Data Type | Listpack For | Transitions To | Threshold Config |
|-----------|-------------|----------------|------------------|
| Hash | Small hashes | hashtable | `hash-max-listpack-entries` (512), `hash-max-listpack-value` (64) |
| Set | Small sets with short strings | hashtable | `set-max-listpack-entries` (128), `set-max-listpack-value` (64) |
| Sorted Set | Small sorted sets | skiplist + hashtable | `zset-max-listpack-entries` (128), `zset-max-listpack-value` (64) |
| List | Small lists | quicklist | `list-max-listpack-size` (default -2 = 8KB) |

For Hashes and Sorted Sets stored in listpack, key-value pairs are stored as consecutive entries (key, value, key, value, ...).

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| lpLength | O(1) / O(n) | O(1) if count <= 65535, else full scan |
| lpFirst / lpLast | O(1) | Direct from header / backward from EOF |
| lpNext / lpPrev | O(1) | Using encoded lengths / backlen |
| lpSeek(index) | O(n) | Linear scan from head or tail |
| lpFind | O(n) | Linear scan |
| lpInsert / lpDelete | O(n) | Requires memmove of trailing data |
| lpBytes | O(1) | Stored in header |
