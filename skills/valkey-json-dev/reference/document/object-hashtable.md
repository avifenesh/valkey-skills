# Object Dual-Mode Storage

Use when working with JSON object member storage, investigating hash table conversion thresholds, or debugging member lookup/insertion performance.

Source: `src/rapidjson/document.h` (GenericMemberHT, GenericMemberIterator, GenericValue private methods)

## Contents

- [Overview](#overview)
- [Vector Mode](#vector-mode)
- [Hash Table Mode](#hash-table-mode)
- [Conversion Threshold](#conversion-threshold)
- [GenericMemberHT Structure](#genericmemberht-structure)
- [Hash Table Layout](#hash-table-layout)
- [Lookup Mechanics](#lookup-mechanics)
- [Insertion](#insertion)
- [Removal and Rehashing](#removal-and-rehashing)
- [Iteration Order](#iteration-order)
- [48-Bit Pointer Optimization](#48-bit-pointer-optimization)
- [Configuration](#configuration)
- [Stats Tracking](#stats-tracking)

## Overview

JSON objects store their members in one of two modes, selected automatically based on member count:

- **Vector mode** (kObjectVecFlag) - Array of `GenericMember` structs, O(n) lookup, compact for small objects.
- **Hash table mode** (kObjectHTFlag) - Open-addressed hash table of `GenericMemberHT` structs with a doubly-linked list for insertion-order iteration, O(1) amortized lookup.

The mode is encoded in the JValue flags field. `kObjectVecFlag = kObjectType` (0x0003), `kObjectHTFlag = kObjectType | kHashTableFlag` (0x2003). The `IsObjectHT()` method tests the `kHashTableFlag` bit (0x2000).

## Vector Mode

Default for small objects. Members are stored as a contiguous array of `GenericMember` (each containing a `KeyTable_Handle name` + `GenericValue value`).

```cpp
struct ObjectData {
    SizeType size;      // current member count
    SizeType capacity;  // allocated slots
    union {
        Member *members;
        MemberHT *membersHT;
    } u;
};
```

Capacity grows by 50% when full (formula: `capacity + (capacity + 1) / 2`), starting at `kDefaultObjectCapacity` (16). Vector mode uses `GetMembersPointerVec()` / `SetMembersPointerVec()` accessors.

Lookup (`DoFindMemberVec`): Linear scan comparing KeyTable_Handle equality (pointer comparison, O(1) per element). Total: O(n).

Duplicate detection on insert (`DoAddMemberVec`): If the new key's refcount is 1 (meaning it was just created in KeyTable and cannot exist elsewhere), duplicate scan is skipped entirely. Otherwise, linear scan.

## Hash Table Mode

Used for larger objects. Members are stored in an open-addressed hash table using linear probing. Each slot is a `GenericMemberHT` - a `GenericMember` plus prev/next linked-list indices.

The hash table vector has `capacity + 1` entries. Entry 0 is the list head (never a real member). Entries 1 through capacity are hash table slots.

## Conversion Threshold

Conversion from vector to hash table is controlled by `HashTableFactors::minHTSize` (default: 32):

```cpp
struct HashTableFactors {
    size_t minHTSize = 32;   // minimum member count before hash table kicks in
    float minLoad = 0.25;    // shrink trigger
    float maxLoad = 0.85;    // grow trigger
    float shrink = 0.5;      // reduce by 50%
    float grow = 1.0;        // grow by 100%
};
```

Conversion triggers:

1. **DoAddMember** - When adding a member and `data_.o.size >= minHTSize` while in vector mode, the object is converted to a hash table via `RehashHT()`.
2. **DoReserveMembers** - When reserving capacity and `newCapacity > minHTSize`, vector mode is converted to hash table.
3. **SetObjectRaw** (during parse) - If `numPairs > minHTSize`, creates hash table directly.

Once converted, an object stays in hash table mode. There is no downward conversion back to vector.

The minHTSize is configurable via `json.hash-table-min-size` at runtime. The global `hashTableFactors` struct is shared by all objects.

## GenericMemberHT Structure

```cpp
template <typename Encoding, typename Allocator>
class GenericMemberHT : public GenericMember<Encoding, Allocator> {
public:
    SizeType prev;   // index of previous member in insertion order
    SizeType next;   // index of next member in insertion order
};
```

`GenericMember` contains `KeyTable_Handle name` (8 bytes) + `GenericValue value` (24 bytes). `GenericMemberHT` adds two `SizeType` (uint32_t) fields = 8 bytes. Total per slot: 40 bytes.

In vector mode, `GenericMember` is 32 bytes per slot.

## Hash Table Layout

The allocated memory is `sizeof(MemberHT) * (capacity + 1)`, zeroed with `memset`. Slot 0 is the list head:

- `ListHead().next` points to the first inserted member.
- `ListHead().prev` points to the last inserted member.
- `ListHead().value` stores a pointer to the allocator (cast to uint64_t) - a cheat to make the allocator available for auto-shrink during remove, since the remove API does not pass an allocator.

Empty slots are identified by a null `KeyTable_Handle` (`!members[ix].name`).

Hash index computation (`HTIndex`):

```cpp
SizeType HTIndex(KeyTable_Handle& h) const {
    size_t hsh = (data_.o.capacity < KeyTable_Handle::MAX_HASHCODE)
            ? h.GetHashcode()            // fast: 19-bit hash from handle metadata
            : h->getOriginalHash();      // slow: full hash from KeyTable_Layout
    return (hsh % data_.o.capacity) + 1; // +1 to skip ListHead
}
```

When capacity fits in 19 bits (< 524287), the hash stored in the handle metadata is used directly. For larger tables, the full hash is fetched from the KeyTable_Layout, causing an extra cache miss.

## Lookup Mechanics

**Vector mode** (`DoFindMemberVec`):

Linear scan from `MemberBegin()` to `MemberEnd()`, comparing `KeyTable_Handle` equality. Since handles for the same string are identical pointers, comparison is a single integer compare.

**Hash table mode** (`DoFindMemberHT`):

1. Compute starting index via `HTIndex(h)`.
2. Linear probe: if slot is empty, not found. If slot's handle equals search handle, found.
3. Wrap around via `IncrIndex()` (index > capacity wraps to 1, skipping ListHead at 0).

The `findInsertion` parameter controls behavior on empty slot: when true (insertion), returns the empty slot position; when false (lookup), returns `MemberEnd()`.

## Insertion

`DoAddMemberHT`:

1. Check load factor. If `loadFactor() > maxLoad` (0.85), rehash up by `capacity * (1 + grow)`.
2. Call `DoFindMemberHT(name, true)` to find the target slot.
3. If the slot already has the same key (duplicate), overwrite the value and destroy the handle.
4. If the slot is empty, insert: assign name and value, link into the doubly-linked list at the tail.

```cpp
newMember.prev = endix;
newMember.next = 0;          // tail points to ListHead (index 0)
m[endix].next = i.index;     // old tail's next = new member
ListHead().prev = i.index;   // ListHead's prev = new tail
```

## Removal and Rehashing

`DoRemoveMemberHT`:

1. Unlink the member from the doubly-linked list (fix prev/next pointers).
2. Decrement size, call destructor on the member.
3. Scan forward from the removed slot to re-establish the linear-probing invariant - entries that were displaced past the now-empty slot may need to move down.
4. After removal, if `loadFactor() < minLoad` (0.25) and capacity > MIN_HT_SIZE (4), rehash down by `shrink` (50%).

Rehash (`RehashHT`):

1. Save current object into a temporary.
2. Construct a new hash table with the target capacity.
3. Move all members from the old table into the new one by iterating the linked list.
4. Free the old table memory.

Both grow and shrink use full rehash - there is no incremental rehashing.

## Iteration Order

Iteration follows the doubly-linked list, preserving insertion order:

```cpp
MemberIterator::Next() { index = isHashTable() ? atHT().next : index+1; }
MemberIterator::Prev() { index = isHashTable() ? atHT().prev : index-1; }
```

`MemberBegin()` returns index `ListHead().next`. `MemberEnd()` returns index 0 (the ListHead sentinel).

The iterator transparently handles both modes. `NodeSize()` returns `sizeof(PlainTypeHT)` or `sizeof(PlainType)` depending on the mode, used for accurate memory size accounting.

## 48-Bit Pointer Optimization

When `RAPIDJSON_48BITPOINTER_OPTIMIZATION` is enabled, pointers in the Data union use only 48 bits (exploiting x86_64 virtual address limits), reducing the Data union from 24 to 16 bytes. The `Flag::payload` shrinks from 22 to 14 bytes, reducing `ShortString::MaxSize` from 21 to 13 characters.

Object/array element pointers use `RAPIDJSON_GETPOINTER` / `RAPIDJSON_SETPOINTER` macros that pack/unpack 48-bit pointers.

## Configuration

Runtime-tunable via CONFIG SET:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `json.hash-table-min-size` | 32 | Member count threshold for vector-to-HT conversion |

The `HashTableFactors` struct fields (minLoad, maxLoad, shrink, grow) are validated via `isValid()` to ensure shrink does not make the table too small to fit existing entries.

## Stats Tracking

Global `HashTableStats` (atomic counters):

| Counter | Meaning |
|---------|---------|
| rehashUp | Hash table grew beyond maxLoad |
| rehashDown | Hash table shrank below minLoad |
| convertToHT | Vector mode converted to hash table |
| reserveHT | Reserve call triggered hash table creation |

Accessible via `JSON.DEBUG` commands.

## See Also

- [jdocument.md](jdocument.md) - JValue/JDocument type hierarchy and flag definitions
- [keytable.md](keytable.md) - KeyTable_Handle used for member name comparison
- [memory-layers.md](memory-layers.md) - Allocator backing hash table memory
- [rdb-format.md](../persistence/rdb-format.md) - RDB serialization encodes object mode
- [defrag.md](../persistence/defrag.md) - Defragmentation traverses object members
