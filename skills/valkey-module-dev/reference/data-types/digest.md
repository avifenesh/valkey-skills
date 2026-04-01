# Digest Callback - DEBUG DIGEST Interface for Module Types

Use when implementing the digest callback for DEBUG DIGEST support, adding elements to a key digest with DigestAddStringBuffer or DigestAddLongLong, choosing the correct ordering pattern (set-like, hash-like, list-like) for your data structure, or verifying data consistency across replicas.

Source: `src/module.c` (lines 7677-7811)

## Contents

- [Overview](#overview)
- [Callback signature](#callback-signature)
- [DigestAddStringBuffer](#digestaddstringbuffer)
- [DigestAddLongLong](#digestaddlonglong)
- [DigestEndSequence](#digestendsequence)
- [Ordering patterns](#ordering-patterns)
- [Key and db accessors](#key-and-db-accessors)
- [Complete example](#complete-example)

---

## Overview

The `DEBUG DIGEST` command computes a hash fingerprint of a key's value. This is used to compare values across replicas or after migration to verify data consistency. Without a digest callback, module type keys are skipped by `DEBUG DIGEST`.

The digest mechanism uses two internal buffers - an accumulator (`o`) for ordered elements within a sequence, and a final hash (`x`) that combines sequences via XOR. This design makes the digest order-independent across sequences (for unordered collections like sets) while preserving order within each sequence (for ordered pairs like hash field-value).

## Callback Signature

```c
typedef void (*ValkeyModuleTypeDigestFunc)(ValkeyModuleDigest *digest, void *value);
```

| Parameter | Description |
|---|---|
| `digest` | Opaque digest context - pass to `DigestAdd*` and `DigestEndSequence` |
| `value` | Your module type value (cast to your struct) |

## DigestAddStringBuffer

```c
void ValkeyModule_DigestAddStringBuffer(ValkeyModuleDigest *md, const char *ele, size_t len);
```

Adds a raw byte buffer to the current digest sequence. Each call mixes the element into the ordered accumulator. Call this for each element that forms part of an ordered group before ending the sequence.

## DigestAddLongLong

```c
void ValkeyModule_DigestAddLongLong(ValkeyModuleDigest *md, long long ll);
```

Convenience wrapper that converts a `long long` to its string representation and adds it to the digest. Equivalent to formatting the integer as a string and calling `DigestAddStringBuffer`.

## DigestEndSequence

```c
void ValkeyModule_DigestEndSequence(ValkeyModuleDigest *md);
```

Marks the end of one ordered group of elements. The accumulated hash for this sequence is XOR'd into the final digest, and the accumulator is reset. The XOR operation makes the final result independent of the order in which sequences are added.

## Ordering Patterns

The correct call pattern depends on the data structure's ordering semantics.

**Set-like (unordered elements):** Each element is its own independent sequence. Order of elements does not affect the final digest.

```c
// Each element stands alone - wrap each in its own sequence
for (each element) {
    ValkeyModule_DigestAddStringBuffer(md, element, len);
    ValkeyModule_DigestEndSequence(md);
}
```

**Hash-like (unordered pairs of ordered key-value):** Within each pair, key comes before value (order matters). Across pairs, order does not matter.

```c
// Key-value pairs: ordered within, unordered across
for (each key, value) {
    ValkeyModule_DigestAddStringBuffer(md, key, key_len);
    ValkeyModule_DigestAddStringBuffer(md, value, val_len);
    ValkeyModule_DigestEndSequence(md);
}
```

**List-like (fully ordered):** All elements form a single sequence. A single `EndSequence` at the end.

```c
// All elements in one ordered sequence
for (each element) {
    ValkeyModule_DigestAddStringBuffer(md, element, len);
}
ValkeyModule_DigestEndSequence(md);
```

**Tree/sorted structure:** If your structure has a defined iteration order but no inherent positional dependency between non-adjacent elements, treat it like a set (each element as its own sequence). If position matters (array semantics), use the list pattern.

## Key and Db Accessors

These functions retrieve metadata about the key being digested:

```c
const ValkeyModuleString *ValkeyModule_GetKeyNameFromDigest(ValkeyModuleDigest *dig);
```

Returns the name of the key currently being digested.

```c
int ValkeyModule_GetDbIdFromDigest(ValkeyModuleDigest *dig);
```

Returns the database ID of the key. These are useful for conditional digest logic, though most modules do not need them.

## Complete Example

From the built-in `hellotype` module (`src/modules/hellotype.c`) - a linked list of integers uses the list-like pattern since element order matters:

```c
void HelloTypeDigest(ValkeyModuleDigest *md, void *value) {
    struct HelloTypeObject *hto = value;
    struct HelloTypeNode *node = hto->head;
    while (node) {
        ValkeyModule_DigestAddLongLong(md, node->value);
        node = node->next;
    }
    ValkeyModule_DigestEndSequence(md);
}
```

All elements are added as a single sequence, so the digest depends on the order of elements in the list.

A more complex example for a hash-like structure:

```c
void MyHash_Digest(ValkeyModuleDigest *md, void *value) {
    MyHash *h = value;
    for (int i = 0; i < h->size; i++) {
        MyEntry *e = &h->entries[i];
        ValkeyModule_DigestAddStringBuffer(md, e->field, e->field_len);
        ValkeyModule_DigestAddStringBuffer(md, e->value, e->value_len);
        ValkeyModule_DigestEndSequence(md);
    }
}
```

## See Also

- [registration.md](registration.md) - Setting the digest callback in ValkeyModuleTypeMethods
- [rdb-callbacks.md](rdb-callbacks.md) - RDB persistence callbacks for the same data types
- [io-context.md](io-context.md) - Similar metadata accessors (GetKeyNameFromIO, GetDbIdFromIO)
- [../testing.md](../testing.md) - Testing modules including DEBUG DIGEST verification
- [../advanced/replication.md](../advanced/replication.md) - Replication where digest checks verify consistency
