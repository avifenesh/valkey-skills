# Key API for Hash and Stream Types

Use when reading or writing hash fields, checking field existence, or working with streams - adding entries, iterating, deleting, and trimming.

Source: `src/module.c` (lines 5353-6065), `src/valkeymodule.h`

## Contents

- [HashSet](#hashset) (line 22)
- [HashGet](#hashget) (line 59)
- [HashSetStringRef](#hashsetstringref) (line 94)
- [HashHasStringRef](#hashhasstringref) (line 111)
- [Hash Flags](#hash-flags) (line 126)
- [StreamAdd](#streamadd) (line 139)
- [StreamDelete](#streamdelete) (line 175)
- [Stream Iterator](#stream-iterator) (line 185)
- [StreamTrim](#streamtrim) (line 228)
- [ValkeyModuleStreamID](#valkeymodulestreamid) (line 245)

---

## HashSet

```c
int ValkeyModule_HashSet(ValkeyModuleKey *key, int flags, ...);
```

Variadic function - pass field/value pairs terminated by NULL. Creates the hash if the key is empty and open for writing.

```c
/* Set field argv[1] to value argv[2] */
ValkeyModule_HashSet(key, VALKEYMODULE_HASH_NONE, argv[1], argv[2], NULL);
```

Delete a field by passing `VALKEYMODULE_HASH_DELETE` as the value:

```c
ValkeyModule_HashSet(key, VALKEYMODULE_HASH_NONE,
                     argv[1], VALKEYMODULE_HASH_DELETE, NULL);
```

With `VALKEYMODULE_HASH_CFIELDS`, field names are C strings:

```c
ValkeyModule_HashSet(key, VALKEYMODULE_HASH_CFIELDS,
                     "username", userval,
                     "email", emailval, NULL);
```

Returns the number of fields updated or deleted. With `COUNT_ALL`, also counts newly inserted fields. On error returns 0 and sets `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | Unknown flags or NULL key |
| `ENOTSUP` | Key is not a hash |
| `EBADF` | Key not opened for writing |
| `ENOENT` | No fields were counted (not necessarily an error) |

## HashGet

```c
int ValkeyModule_HashGet(ValkeyModuleKey *key, int flags, ...);
```

Variadic - pass field/value-pointer pairs terminated by NULL. Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the key is wrong type.

```c
ValkeyModuleString *val1, *val2;
ValkeyModule_HashGet(key, VALKEYMODULE_HASH_NONE,
                     argv[1], &val1,
                     argv[2], &val2, NULL);
/* val1/val2 are NULL if fields don't exist */
```

With `VALKEYMODULE_HASH_EXISTS`, use `int *` instead of `ValkeyModuleString **`:

```c
int exists;
ValkeyModule_HashGet(key, VALKEYMODULE_HASH_EXISTS,
                     argv[1], &exists, NULL);
```

With `VALKEYMODULE_HASH_CFIELDS`:

```c
ValkeyModuleString *username, *email;
ValkeyModule_HashGet(key, VALKEYMODULE_HASH_CFIELDS,
                     "username", &username,
                     "email", &email, NULL);
```

Returned strings must be freed with `ValkeyModule_FreeString()` or auto-managed.

## HashSetStringRef

```c
int ValkeyModule_HashSetStringRef(ValkeyModuleKey *key,
                                  ValkeyModuleString *field,
                                  const char *buf, size_t len);
```

Sets the value of a hash field to a non-owning string reference (stringRef) pointing to `buf`, which remains owned by the module. The engine stores a reference to the buffer instead of copying it, avoiding memory duplication - critical when the buffer size is large. For example, valkey-search uses this to avoid maintaining two copies of indexed vectors.

Returns `VALKEYMODULE_ERR` if `key`, `field`, or `buf` is NULL, if the key is empty (has no value), or if the key is not a hash.

```c
/* Share a large buffer with the hash without copying */
ValkeyModule_HashSetStringRef(key, fieldname, vector_buf, vector_len);
```

## HashHasStringRef

```c
int ValkeyModule_HashHasStringRef(ValkeyModuleKey *key,
                                  ValkeyModuleString *field);
```

Checks if the value of a hash field is a shared string reference (stringRef) rather than a regular value. Returns `VALKEYMODULE_ERR` if the key is NULL or not a hash.

```c
if (ValkeyModule_HashHasStringRef(key, fieldname)) {
    /* Field value is a shared stringRef - buffer is module-owned */
}
```

## Hash Flags

| Flag | Value | Effect |
|------|-------|--------|
| `VALKEYMODULE_HASH_NONE` | 0 | Default behavior |
| `VALKEYMODULE_HASH_NX` | `1<<0` | Set only if field does not exist |
| `VALKEYMODULE_HASH_XX` | `1<<1` | Set only if field already exists |
| `VALKEYMODULE_HASH_CFIELDS` | `1<<2` | Field names are C strings, not ValkeyModuleString |
| `VALKEYMODULE_HASH_EXISTS` | `1<<3` | HashGet: check existence (int *) instead of value |
| `VALKEYMODULE_HASH_COUNT_ALL` | `1<<4` | HashSet: count inserts in addition to updates |

`VALKEYMODULE_HASH_DELETE` is a special sentinel value `((ValkeyModuleString *)(long)1)` used as the value parameter in `HashSet` to delete a field.

## StreamAdd

```c
int ValkeyModule_StreamAdd(ValkeyModuleKey *key, int flags,
                           ValkeyModuleStreamID *id,
                           ValkeyModuleString **argv, long numfields);
```

Adds an entry to a stream. `argv` contains `numfields * 2` elements (field-value pairs). Creates the stream if the key is empty.

Flags:

| Flag | Value | Effect |
|------|-------|--------|
| `VALKEYMODULE_STREAM_ADD_AUTOID` | `1<<0` | Auto-assign ID (like `*` in XADD) |

When `AUTOID` is set, `id` receives the assigned ID (can be NULL if you don't need it). When not set, `id` is the requested ID and must be greater than all existing IDs.

Returns `VALKEYMODULE_ERR` with `errno`:

| errno | Cause |
|-------|-------|
| `EINVAL` | Invalid arguments |
| `ENOTSUP` | Key is wrong type |
| `EBADF` | Key not opened for writing |
| `EDOM` | ID is 0-0 or not greater than existing IDs |
| `EFBIG` | Stream reached maximum ID |
| `ERANGE` | Elements too large to store |

```c
ValkeyModuleStreamID id;
ValkeyModuleString *fields[] = {field1, value1, field2, value2};
ValkeyModule_StreamAdd(key, VALKEYMODULE_STREAM_ADD_AUTOID,
                       &id, fields, 2);
```

## StreamDelete

```c
int ValkeyModule_StreamDelete(ValkeyModuleKey *key, ValkeyModuleStreamID *id);
```

Deletes an entry by ID. Key must be open for writing with no active iterator.

Returns `VALKEYMODULE_ERR` with errno `EINVAL`, `ENOTSUP`, `EBADF`, or `ENOENT` (no entry with that ID).

## Stream Iterator

```c
int ValkeyModule_StreamIteratorStart(ValkeyModuleKey *key, int flags,
    ValkeyModuleStreamID *start, ValkeyModuleStreamID *end);
int ValkeyModule_StreamIteratorStop(ValkeyModuleKey *key);
int ValkeyModule_StreamIteratorNextID(ValkeyModuleKey *key,
    ValkeyModuleStreamID *id, long *numfields);
int ValkeyModule_StreamIteratorNextField(ValkeyModuleKey *key,
    ValkeyModuleString **field_ptr, ValkeyModuleString **value_ptr);
int ValkeyModule_StreamIteratorDelete(ValkeyModuleKey *key);
```

Iterator flags:

| Flag | Value | Effect |
|------|-------|--------|
| `VALKEYMODULE_STREAM_ITERATOR_EXCLUSIVE` | `1<<0` | Exclude start/end from range |
| `VALKEYMODULE_STREAM_ITERATOR_REVERSE` | `1<<1` | Iterate from end to start |

Pass NULL for `start`/`end` to iterate from the beginning/to the end of the stream.

Complete iteration example:

```c
ValkeyModule_StreamIteratorStart(key, 0, NULL, NULL);
ValkeyModuleStreamID id;
long numfields;
while (ValkeyModule_StreamIteratorNextID(key, &id, &numfields) ==
       VALKEYMODULE_OK) {
    ValkeyModuleString *field, *value;
    while (ValkeyModule_StreamIteratorNextField(key, &field, &value) ==
           VALKEYMODULE_OK) {
        /* process field and value */
        ValkeyModule_FreeString(ctx, field);
        ValkeyModule_FreeString(ctx, value);
    }
}
ValkeyModule_StreamIteratorStop(key);
```

`StreamIteratorDelete` deletes the current entry during iteration. Can be called after `NextID` or after any `NextField` calls. Sets the internal state so that repeated `Delete` calls without a new `NextID` return `ENOENT`.

## StreamTrim

```c
long long ValkeyModule_StreamTrimByLength(ValkeyModuleKey *key,
    int flags, long long length);
long long ValkeyModule_StreamTrimByID(ValkeyModuleKey *key,
    int flags, ValkeyModuleStreamID *id);
```

Trim flags:

| Flag | Value | Effect |
|------|-------|--------|
| `VALKEYMODULE_STREAM_TRIM_APPROX` | `1<<0` | Approximate trim (like `~` in XTRIM) |

`TrimByLength` keeps at most `length` entries. `TrimByID` removes entries with IDs less than `id`. Both return the number of deleted entries, or -1 on error with `errno` set (`EINVAL`, `ENOTSUP`, `EBADF`).

## ValkeyModuleStreamID

```c
typedef struct ValkeyModuleStreamID {
    uint64_t ms;
    uint64_t seq;
} ValkeyModuleStreamID;
```

Convert between strings and stream IDs:

```c
/* String to StreamID */
ValkeyModuleStreamID id;
ValkeyModule_StringToStreamID(argv[1], &id);

/* StreamID to String */
ValkeyModuleString *str = ValkeyModule_CreateStringFromStreamID(ctx, &id);
```

## See Also

- [key-generic.md](key-generic.md) - OpenKey, CloseKey, KeyType, ValueLength
- [key-sorted-set.md](key-sorted-set.md) - Sorted set operations
- [key-list.md](key-list.md) - List operations
- [string-objects.md](string-objects.md) - String conversion functions for stream IDs (CreateStringFromStreamID, StringToStreamID)
- [reply-building.md](reply-building.md) - Building hash/stream result replies
- [../lifecycle/memory.md](../lifecycle/memory.md) - AutoMemory for automatic cleanup of returned strings and key handles
- [../events/blocking-on-keys.md](../events/blocking-on-keys.md) - BlockClientOnKeys for XREAD-style blocking on streams
- [../advanced/calling-commands.md](../advanced/calling-commands.md) - Alternative: call HSET/XADD via ValkeyModule_Call
