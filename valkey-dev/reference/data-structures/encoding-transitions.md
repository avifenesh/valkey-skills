# Encoding Transitions

Use when you need to understand how Valkey automatically selects compact encodings for small collections and transitions to full-featured structures when thresholds are exceeded.

Source: `src/object.c`, `src/t_list.c`, `src/t_set.c`, `src/t_zset.c`, `src/t_hash.c`, `src/config.c`

---

## Overview

Every Valkey data type (represented by an `robj` - see [../valkey-specific/object-lifecycle.md](../valkey-specific/object-lifecycle.md)) has a compact encoding optimized for small collections and a full encoding for large ones. Valkey starts with the compact encoding and converts automatically when element count or element size exceeds configurable thresholds. Conversions are one-way (compact to full) during normal operation - Valkey does not convert back to compact encoding after deletion, with one exception: lists can convert from quicklist back to listpack when they shrink enough.

## Transition Table

| Data Type | Compact Encoding | Full Encoding | Count Threshold | Size Threshold |
|-----------|-----------------|---------------|-----------------|----------------|
| String | EMBSTR or INT | RAW | N/A | Total embedded size > 64 bytes or non-numeric |
| List | LISTPACK | QUICKLIST | Per `list-max-listpack-size` | Per `list-max-listpack-size` |
| Set | INTSET | HASHTABLE | `set-max-intset-entries` (512) | Non-integer element added |
| Set | LISTPACK | HASHTABLE | `set-max-listpack-entries` (128) | Element > `set-max-listpack-value` (64) |
| Sorted Set | LISTPACK | SKIPLIST + HASHTABLE | `zset-max-listpack-entries` (128) | Element > `zset-max-listpack-value` (64) |
| Hash | LISTPACK | HASHTABLE | `hash-max-listpack-entries` (512) | Value > `hash-max-listpack-value` (64) |
| Stream | Rax + Listpack | (same) | N/A (grows naturally) | N/A |

Default values shown in parentheses are from `src/config.c`.

## String Encoding

Strings have three encodings:

| Encoding | Condition | Storage |
|----------|-----------|---------|
| INT | Value is a 64-bit integer | Integer stored directly in robj |
| EMBSTR | Total embedded size <= 64 bytes | SDS embedded in robj allocation |
| RAW | Too large to embed, or modified EMBSTR | Separate SDS allocation |

EMBSTR is read-only by convention - any modification (APPEND, SETRANGE) converts to RAW first.

The embed decision is dynamic, computed by `shouldEmbedStringObject()` in `object.c`:

```c
static bool shouldEmbedStringObject(size_t val_len, const_sds key, long long expire) {
    if (val_len > sdsTypeMaxSize(SDS_TYPE_8)) return false;
    size_t key_len = sdslen(key);
    size_t size = sizeof(robj) - sizeof(void *);
    if (key) {
        size += sdsReqSize(key_len, sdsReqType(key_len)) + 1;
    }
    size += (expire != EXPIRY_NONE) * sizeof(long long);
    size += sdsReqSize(val_len, SDS_TYPE_8);
    return size <= 64;
}
```

The 64-byte limit (one cache line) accounts for the robj header, optional embedded key, optional expire, and the SDS value. For a value-only string without key or expire, the maximum embeddable string is roughly 50+ bytes (depending on robj size). When a key and expire are also embedded, less space remains for the value.

## List Encoding

Lists start as LISTPACK and convert to QUICKLIST when the listpack exceeds the configured limits.

**Config**: `list-max-listpack-size` (default: -2)

The value controls quicklist node fill factor, and the same value determines when a listpack-encoded list converts:

| Value | Meaning |
|-------|---------|
| -1 | Max 4 KB per node |
| -2 | Max 8 KB per node (default) |
| -3 | Max 16 KB per node |
| -4 | Max 32 KB per node |
| -5 | Max 64 KB per node |
| N > 0 | Max N entries per node |

**Conversion trigger** (in `listTypeTryConvertListpack`): When adding elements would cause the single listpack to exceed the configured size or count limit.

**Reverse conversion**: Lists CAN convert back from QUICKLIST to LISTPACK when shrinking. If a quicklist has only one node and that node's size/count is below half the threshold (to avoid oscillation), it converts back to a bare listpack.

## Set Encoding

Sets have three possible encodings with two separate conversion paths:

### INTSET Path

Sets start as INTSET when all elements are integers.

**Config**: `set-max-intset-entries` (default: 512)

**Conversion to HASHTABLE when**:
- A non-integer element is added
- Element count exceeds `set-max-intset-entries`

### LISTPACK Path

Sets use LISTPACK when elements include non-integers but the set is small.

**Configs**:
- `set-max-listpack-entries` (default: 128)
- `set-max-listpack-value` (default: 64 bytes)

**Conversion to HASHTABLE when**:
- Element count exceeds `set-max-listpack-entries`
- Any element exceeds `set-max-listpack-value` bytes

### Conversion Logic (from `t_set.c`)

```c
void setTypeConvert(robj *setobj, int enc);
```

When converting from INTSET to HASHTABLE, all integers are converted to SDS strings and inserted into the hashtable. When converting from LISTPACK, entries are read sequentially and added to the hashtable.

## Sorted Set Encoding

Sorted sets start as LISTPACK (key-value pairs: element, score, element, score, ...) and convert to SKIPLIST + HASHTABLE.

**Configs**:
- `zset-max-listpack-entries` (default: 128)
- `zset-max-listpack-value` (default: 64 bytes)

**Conversion to SKIPLIST when**:
- Element count exceeds `zset-max-listpack-entries`
- Any element exceeds `zset-max-listpack-value` bytes

```c
void zsetConvert(robj *zobj, int encoding);
void zsetConvertAndExpand(robj *zobj, int encoding, unsigned long cap);
```

The full encoding uses both structures simultaneously:
- **skiplist**: Score-ordered for range queries, rank operations
- **hashtable**: Element-to-score mapping for O(1) ZSCORE lookups

Both share the same SDS element strings.

**Reverse check**: `zsetConvertToListpackIfNeeded` can convert back to listpack if after bulk operations the set becomes small enough.

## Hash Encoding

Hashes start as LISTPACK (key, value, key, value, ...) and convert to HASHTABLE.

**Configs**:
- `hash-max-listpack-entries` (default: 512) - counts key-value pairs
- `hash-max-listpack-value` (default: 64 bytes) - applies to both keys and values

**Conversion to HASHTABLE when**:
- Number of fields exceeds `hash-max-listpack-entries`
- Any key or value exceeds `hash-max-listpack-value` bytes

```c
void hashTypeConvertListpack(robj *o, int enc);
void hashTypeConvert(robj *o, int enc);
```

## Configuration Reference

All threshold configs from `src/config.c`:

```
# Lists
list-max-listpack-size -2

# Sets
set-max-intset-entries 512
set-max-listpack-entries 128
set-max-listpack-value 64

# Sorted Sets
zset-max-listpack-entries 128
zset-max-listpack-value 64

# Hashes
hash-max-listpack-entries 512
hash-max-listpack-value 64
```

Legacy aliases are accepted: `list-max-ziplist-size`, `hash-max-ziplist-entries`, `hash-max-ziplist-value`, `zset-max-ziplist-entries`, `zset-max-ziplist-value`.

## Memory Impact

The choice of encoding significantly affects memory usage:

| Structure | Overhead Per Entry (approx) |
|-----------|---------------------------|
| Listpack | 2-11 bytes (encoding + backlen) |
| Intset | 2-8 bytes (raw integer, no overhead) |
| Hashtable | ~20-30 bytes (bucket slot + entry) |
| Skiplist node | ~40+ bytes (score + pointers + levels + embedded SDS) |
| Quicklist node | 32 bytes per node + listpack overhead per element |

For small collections (under the default thresholds), the compact encoding can use 5-10x less memory than the full encoding. This is why the defaults are set relatively high.

## Checking Current Encoding

Use `OBJECT ENCODING <key>` to see the current encoding:

```
> SET mykey "hello"
> OBJECT ENCODING mykey
"embstr"

> HSET myhash field value
> OBJECT ENCODING myhash
"listpack"

> ZADD myzset 1.0 member
> OBJECT ENCODING myzset
"listpack"
```

## See Also

- [../valkey-specific/object-lifecycle.md](../valkey-specific/object-lifecycle.md) - The `robj` struct whose `type` and `encoding` fields drive these transitions
- [listpack.md](listpack.md) - Compact encoding used by Lists, Hashes, Sets, and Sorted Sets
- [hashtable.md](hashtable.md) - Full encoding for Hashes, Sets, and the element-to-score map in Sorted Sets
- [quicklist.md](quicklist.md) - Full encoding for Lists
- [skiplist.md](skiplist.md) - Full encoding (score-ordered) for Sorted Sets
- [sds.md](sds.md) - The SDS string type underlying RAW and EMBSTR encodings
