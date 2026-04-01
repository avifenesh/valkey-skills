# KeyTable - String Interning

Use when working with the KeyTable string interning system, understanding how JSON object keys are stored, debugging key reference counts, or investigating shard performance.

Source: `src/json/keytable.h`, `src/json/keytable.cc`, `src/json/json.cc` (hash_function)

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [KeyTable_Layout](#keytable_layout)
- [KeyTable_Handle](#keytable_handle)
- [PtrWithMetaData](#ptrwithmetadata)
- [Shard Architecture](#shard-architecture)
- [Hash Function](#hash-function)
- [Core Operations](#core-operations)
- [Ref Count Saturation](#ref-count-saturation)
- [Rehashing](#rehashing)
- [Thread Safety](#thread-safety)
- [Configuration](#configuration)
- [Stats and Diagnostics](#stats-and-diagnostics)

## Overview

The KeyTable is a global singleton that stores unique, immutable, reference-counted strings. It is used for JSON object member names - every `GenericMember::name` is a `KeyTable_Handle` pointing into this table rather than a standalone string allocation.

Benefits:
- Deduplication: Identical keys across all JSON documents share one copy.
- Fast equality: Two handles for the same string are the same pointer, so comparison is a single integer compare.
- Compact: 8 bytes per handle vs. 24+ bytes for a GenericValue string.

## Architecture

```
KeyTable (singleton)
  |
  +-- shards[0..numShards-1]    (KeyTable_Shard)
        |
        +-- entries[0..capacity-1]  (PtrWithMetaData<KeyTable_Layout>)
              |
              +-> KeyTable_Layout   (malloc'ed: hash + refcount + flags + length + text)
```

A string is hashed. The hash selects a shard. The shard's mutex is locked. The shard's hash table (open addressing, linear probing) is searched. If found, refcount is incremented. If not found, a new `KeyTable_Layout` is allocated, the table is updated, and a handle is returned.

## KeyTable_Layout

Each unique string is stored in a separately malloc'ed block with packed metadata:

```cpp
struct KeyTable_Layout {                    // __attribute__((packed))
    size_t original_hash;                   // 8 bytes - full 64-bit hash
    mutable uint32_t refCount:29;           // 29 bits - reference count
    uint32_t noescapeFlag:1;               // 1 bit - string needs no JSON escaping
    uint32_t lengthBytes:2;                // 2 bits - 0/1/2/3 = 1/2/3/4 length bytes
    char bytes[1];                          // variable: length bytes + text bytes
};
```

Total fixed overhead: 13 bytes (8 hash + 4 bitfield + 1 start of bytes array). The struct is `__attribute__((packed))` to prevent compiler padding to 8-byte boundaries.

**Length encoding**: The string length is stored in little-endian format using 1 to 4 bytes, depending on the string length:

| lengthBytes | Byte count | Max string length |
|-------------|------------|-------------------|
| 0 | 1 byte | 255 |
| 1 | 2 bytes | 65,535 |
| 2 | 3 bytes | 16,777,215 |
| 3 | 4 bytes | 4,294,967,295 |

The text follows immediately after the length bytes. Total allocation per string: `sizeof(KeyTable_Layout) + lengthBytes + len` (13 + 1..4 + len).

`makeLayout()` creates a new layout, copying the string. `getLength()` decodes the variable-length encoding. `getText()` returns `bytes + lengthBytes + 1`.

## KeyTable_Handle

An 8-byte handle returned to callers. Contains both a pointer to the `KeyTable_Layout` and the shard number, packed into a single `size_t`:

```cpp
struct KeyTable_Handle {
    PtrWithMetaData<KeyTable_Layout> theHandle;  // 8 bytes total
};
```

Public interface:
- `GetString()` - pointer to the interned text.
- `GetStringLength()` - length of the interned text.
- `GetStringView()` - `std::string_view` of the text.
- `GetHashcode()` - low 19 bits of the hash (from metadata).
- `IsNoescape()` - whether the string needs JSON escaping.

Handle semantics:
- Move-only: assignment into an empty handle moves ownership; copy is disallowed.
- `RawAssign()` performs an assignment into potentially uninitialized memory (used by GenericMember).
- Destructor asserts the handle is empty (cleared). Failing to destroy a handle is a leak that triggers an assertion.
- Equality comparison includes both pointer and metadata, making it a single integer compare.

## PtrWithMetaData

Template class that packs a pointer and up to 19 bits of metadata into a single `size_t`:

```cpp
template<typename T>
class PtrWithMetaData {
    size_t bits;   // pointer in low 48 bits, metadata rotated into high bits
    enum { METADATA_MASK = (1 << 19) - 1 };  // 524287
};
```

Exploits x86_64 and AArch64 properties:
- Upper 16 bits of pointers are unused (guaranteed zero for user-space).
- Malloc'ed memory is 8-byte aligned, so lowest 3 bits are zero.
- Total available bits: 16 + 3 = 19 bits for metadata.

Metadata is stored via circular right rotation: `ror(metadata, 16)` places the 19 metadata bits across the top 16 and bottom 3 bit positions. `getMetaData()` reverses with `ror(bits, 48)`.

Pointer extraction masks off the metadata: `bits & PTR_MASK` where `PTR_MASK = ~ror(METADATA_MASK, 16)`.

For KeyTable_Handle, the metadata stores the shard-local hashcode (low 19 bits of the full hash).

## Shard Architecture

The KeyTable is divided into configurable shards, each independently locked:

- **MAX_SHARDS**: 524,287 (= `METADATA_MASK`, limited by handle metadata bits).
- **MIN_SHARDS**: 1.
- **Default**: Configurable via `json.key-table-num-shards` (set before any data is loaded).

Each shard (`KeyTable_Shard`) contains:
- An open-addressed hash table using linear probing.
- A `std::mutex` for thread safety.
- Counters: size, bytes, handles, maxSearch, rehashes.
- Minimum table size: 4 entries.

Shard selection from hash: `(hash >> 40) % numShards` - uses high bits of the hash to avoid correlation with the shard-internal table index (which uses low bits).

Hashcode stored in handle: `hash & MAX_HASHCODE` - low 19 bits.

## Hash Function

FNV-1a 64-bit, XOR-folded to 38 bits:

```cpp
size_t hash_function(const char *text, size_t length) {
    size_t hsh = 14695981039346656037ull;     // FNV offset basis
    for (size_t i = 0; i < length; ++i) {
        hsh = (hsh ^ text[i]) * 1099511628211ull;  // FNV prime
    }
    return hsh ^ (hsh >> 38);  // XOR-fold to 38 bits
}
```

The 38-bit result provides 19 bits for shard selection (upper bits) and 19 bits for handle metadata (lower bits), with overlap available for per-shard table indexing.

The hash function is injected via `KeyTable::Config` and could be replaced, but FNV-1a is the only implementation used.

## Core Operations

**makeHandle(ptr, len, noescape)**:
1. Hash the string.
2. Compute shard number from hash.
3. Lock shard mutex.
4. Linear-probe the shard's hash table.
5. If found: increment refcount, increment handles counter, return handle.
6. If not found: allocate `KeyTable_Layout`, insert into table, return handle.

**destroyHandle(h)**:
1. Hash the handle's string (needed for shard lookup).
2. Assert the layout is not poisoned (double-free detection).
3. Lock shard mutex.
4. Decrement refcount. If still > 0, clear handle and return.
5. If refcount reaches 0: find entry in hash table, update stats, poison the original_hash field, free the layout memory, clear the entry, re-establish linear probing invariant by scanning forward.

**clone(h)**:
1. Hash the handle's string.
2. Lock shard mutex.
3. Increment refcount (saturating).
4. Return a new handle pointing to the same layout.

## Ref Count Saturation

The refcount is 29 bits, max value 536,870,911. Arithmetic is saturating:

- `incrRefCount()`: If at max, returns true (saturated) and does not increment. The `KeyTable::stuckKeys` atomic counter is incremented.
- `decrRefCount()`: If stuck (at max), does not decrement. The string will never be freed.

A deliberate design choice - a string used more than 2^29 times is considered permanent. The `stuckKeys` counter in `KeyTable::Stats` reports how many strings are in this state.

Poison value `0xdeadbeeffeedfead` is written to `original_hash` when a layout is freed, enabling detection of use-after-free in `destroyHandle`.

## Rehashing

Per-shard hash table rehashing is synchronous (full rebuild while mutex is held):

- **Grow**: When `loadFactor() > maxLoad` (0.85), capacity increases by `capacity * grow` (100%).
- **Shrink**: When `loadFactor() < minLoad` (0.25) and capacity > 4, capacity decreases by `capacity * shrink` (50%).

For tables smaller than 2^19 entries, rehashing uses the 19-bit hash stored in each entry's `PtrWithMetaData` metadata - no extra cache miss. For larger tables, the full hash must be fetched from the `KeyTable_Layout::original_hash` field, causing additional cache misses. A warning is logged when a shard grows past 2^19.

The trade-off is: more shards = smaller per-shard tables = faster rehash but more memory overhead. Target: keep shard tables under 2^19 entries.

## Thread Safety

- Each shard has its own `std::mutex`. Operations on different shards are fully concurrent.
- The handle itself (pointer + metadata) is immutable once created. Reading `GetString()`, `GetStringLength()`, etc. requires no lock.
- `setFactors()` grabs all shard locks sequentially to ensure consistency.
- Stats collection (`getStats()`) locks each shard in sequence, summing contributions. Slight inaccuracies possible under concurrent mutation.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `json.key-table-num-shards` | (varies) | Number of shards. Can only change before data is loaded. |
| KeyTable::Factors.minLoad | 0.25 | Below this load factor, shrink |
| KeyTable::Factors.maxLoad | 0.85 | Above this load factor, grow |
| KeyTable::Factors.shrink | 0.5 | Fraction to shrink by |
| KeyTable::Factors.grow | 1.0 | Fraction to grow by |

Factors are validated by `isValidFactors()` before applying. Key constraint: `shrink <= 1.0 - minLoad` (shrunk table must still hold all entries).

## Stats and Diagnostics

`KeyTable::Stats` (read via `getStats()`, resets maxSearch/rehashes after read):

| Field | Meaning |
|-------|---------|
| size | Total unique strings |
| bytes | Total bytes of string text |
| handles | Outstanding handle count |
| maxTableSize | Largest shard table |
| minTableSize | Smallest shard table |
| totalTable | Sum of all shard capacities |
| stuckKeys | Strings with saturated refcount |
| maxSearch | Longest probe sequence since last read |
| rehashes | Rehash count since last read |

`LongStats` provides run-length distribution across shard tables (expensive, debug only).

`validate()` and `validate_counts()` are unit-test functions that verify all invariants across all shards.
