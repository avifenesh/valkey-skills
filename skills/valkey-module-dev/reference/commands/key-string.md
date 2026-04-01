# Key API for String Type - StringSet, StringDMA, StringTruncate

Use when reading or writing string values in keys using the low-level key API, or when performing direct memory access (DMA) on string key values.

Source: `src/module.c` (lines 4501-4612), `src/valkeymodule.h`

## Contents

- [StringSet](#stringset) (line 17)
- [StringDMA](#stringdma) (line 31)
- [StringTruncate](#stringtruncate) (line 60)
- [DMA Access Pattern](#dma-access-pattern) (line 91)
- [Value Length](#value-length) (line 127)

---

## StringSet

```c
int ValkeyModule_StringSet(ValkeyModuleKey *key, ValkeyModuleString *str);
```

Sets the string value of a key. Deletes any existing value first. Returns `VALKEYMODULE_ERR` if the key is not open for writing or has an active iterator.

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_WRITE);
ValkeyModule_StringSet(key, argv[2]);
ValkeyModule_CloseKey(key);
```

## StringDMA

```c
char *ValkeyModule_StringDMA(ValkeyModuleKey *key, size_t *len, int mode);
```

Returns a direct pointer to the string value's internal buffer. The `mode` parameter is a bitwise OR of:

| Mode | Effect |
|------|--------|
| `VALKEYMODULE_READ` | Read-only access to the buffer |
| `VALKEYMODULE_WRITE` | Read-write access (unshares the string internally) |

Returns NULL if the key contains a non-string value (wrong type). For empty/missing keys, returns a read-only pointer to a static empty string literal with `*len` set to 0 - do not write to this pointer even in `VALKEYMODULE_WRITE` mode.

DMA rules:

1. Do not call any other key-writing function while using the DMA pointer
2. After calling `StringTruncate`, call `StringDMA` again to get a fresh pointer
3. If length is 0, do not access any bytes - use `StringTruncate` first to allocate

```c
size_t len;
char *buf = ValkeyModule_StringDMA(key, &len, VALKEYMODULE_READ | VALKEYMODULE_WRITE);
if (buf && len > 0) {
    buf[0] = 'X';  /* Modify first byte in-place */
}
```

## StringTruncate

```c
int ValkeyModule_StringTruncate(ValkeyModuleKey *key, size_t newlen);
```

Resizes the string value of a key:

- If `newlen > current length`, pads with zero bytes
- If `newlen < current length`, truncates
- If key is empty and `newlen > 0`, creates a new zero-filled string key
- If key is empty and `newlen == 0`, does nothing (returns OK)

Maximum size: 512 MB (`512 * 1024 * 1024` bytes).

Returns `VALKEYMODULE_ERR` if:
- Key not open for writing
- Key exists but is not a string type
- Requested size exceeds 512 MB

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_WRITE);
/* Create a 100-byte zero-filled string */
ValkeyModule_StringTruncate(key, 100);
/* Get DMA pointer to write into it */
size_t len;
char *buf = ValkeyModule_StringDMA(key, &len, VALKEYMODULE_WRITE);
memcpy(buf, data, 100);
ValkeyModule_CloseKey(key);
```

## DMA Access Pattern

The typical DMA workflow for building binary values:

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_WRITE);

/* Allocate space */
ValkeyModule_StringTruncate(key, desired_size);

/* Get write pointer */
size_t len;
char *ptr = ValkeyModule_StringDMA(key, &len, VALKEYMODULE_WRITE);

/* Write data directly */
memcpy(ptr, source_data, desired_size);

/* If you need to resize, re-acquire the pointer */
ValkeyModule_StringTruncate(key, new_size);
ptr = ValkeyModule_StringDMA(key, &len, VALKEYMODULE_WRITE);

ValkeyModule_CloseKey(key);
```

For read-only access to existing string values:

```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_READ);
if (ValkeyModule_KeyType(key) == VALKEYMODULE_KEYTYPE_STRING) {
    size_t len;
    const char *ptr = ValkeyModule_StringDMA(key, &len, VALKEYMODULE_READ);
    /* Read from ptr[0..len-1] */
}
ValkeyModule_CloseKey(key);
```

## Value Length

Use `ValkeyModule_ValueLength(key)` from the generic key API to get the byte length of a string value without DMA. See [key-generic.md](key-generic.md).

## See Also

- [key-generic.md](key-generic.md) - OpenKey, KeyType, ValueLength, expiry
- [string-objects.md](string-objects.md) - ValkeyModuleString creation and parsing (distinct from key string values)
- [key-list.md](key-list.md) - List key operations
- [key-hash-stream.md](key-hash-stream.md) - Hash and stream key operations
- [../advanced/calling-commands.md](../advanced/calling-commands.md) - Alternative to DMA: call SET/GET via ValkeyModule_Call
- [../lifecycle/memory.md](../lifecycle/memory.md) - Memory management for DMA buffers and key handles
