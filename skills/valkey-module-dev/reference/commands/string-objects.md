# String Objects - ValkeyModuleString Creation, Parsing, Comparison, Lifetime

Use when creating, parsing, comparing, or manipulating ValkeyModuleString objects in module commands.

Source: `src/module.c` (lines 2740-3132), `src/valkeymodule.h`

## Contents

- [Creating Strings](#creating-strings) (line 18)
- [Lifetime Management](#lifetime-management) (line 44)
- [Extracting Data](#extracting-data) (line 74)
- [Type Conversions](#type-conversions) (line 88)
- [Comparison and Modification](#comparison-and-modification) (line 111)
- [Memory Optimization](#memory-optimization) (line 130)

---

## Creating Strings

```c
ValkeyModuleString *ValkeyModule_CreateString(ValkeyModuleCtx *ctx,
                                              const char *ptr, size_t len);
ValkeyModuleString *ValkeyModule_CreateStringPrintf(ValkeyModuleCtx *ctx,
                                                    const char *fmt, ...);
ValkeyModuleString *ValkeyModule_CreateStringFromLongLong(ValkeyModuleCtx *ctx,
                                                          long long ll);
ValkeyModuleString *ValkeyModule_CreateStringFromULongLong(ValkeyModuleCtx *ctx,
                                                           unsigned long long ull);
ValkeyModuleString *ValkeyModule_CreateStringFromDouble(ValkeyModuleCtx *ctx,
                                                        double d);
ValkeyModuleString *ValkeyModule_CreateStringFromLongDouble(ValkeyModuleCtx *ctx,
                                                            long double ld,
                                                            int humanfriendly);
ValkeyModuleString *ValkeyModule_CreateStringFromString(ValkeyModuleCtx *ctx,
                                                        const ValkeyModuleString *str);
ValkeyModuleString *ValkeyModule_CreateStringFromStreamID(ValkeyModuleCtx *ctx,
                                                          const ValkeyModuleStreamID *id);
```

The `ctx` parameter is optional (pass NULL) when creating strings outside command context. With NULL ctx, automatic memory management is unavailable and you must call `FreeString` manually.

`CreateString` copies the buffer - no reference is retained to the input.

## Lifetime Management

```c
void ValkeyModule_FreeString(ValkeyModuleCtx *ctx, ValkeyModuleString *str);
void ValkeyModule_RetainString(ValkeyModuleCtx *ctx, ValkeyModuleString *str);
ValkeyModuleString *ValkeyModule_HoldString(ValkeyModuleCtx *ctx,
                                            ValkeyModuleString *str);
```

**FreeString**: Safe to call even with automatic memory enabled - removes the string from the auto-free pool. Not thread safe for strings from client args.

**RetainString**: Keeps a string alive past the callback return. Use when:
1. Automatic memory is enabled
2. You create/receive a string
3. It needs to outlive the callback (e.g., stored in a custom data type)

**HoldString**: Safer alternative to `RetainString` - always succeeds. More efficient than `CreateStringFromString` since it avoids copying when possible. Limitation: cannot use `StringAppendBuffer` on the returned string.

Both `RetainString` and `HoldString` are not thread safe for strings originating from client arguments.

**When to use which**:

| Scenario | Function |
|----------|----------|
| Store in data structure (auto-memory on) | `RetainString` or `HoldString` |
| Need to append to string later | `RetainString` |
| Just need a reference, no append | `HoldString` (preferred) |
| String from NULL context | No retain needed, just don't free |

## Extracting Data

```c
const char *ValkeyModule_StringPtrLen(const ValkeyModuleString *str, size_t *len);
```

Returns a read-only pointer and length. Never modify the returned buffer. If `str` is NULL, returns an error message string.

```c
size_t len;
const char *buf = ValkeyModule_StringPtrLen(argv[1], &len);
```

## Type Conversions

```c
int ValkeyModule_StringToLongLong(const ValkeyModuleString *str, long long *ll);
int ValkeyModule_StringToULongLong(const ValkeyModuleString *str,
                                   unsigned long long *ull);
int ValkeyModule_StringToDouble(const ValkeyModuleString *str, double *d);
int ValkeyModule_StringToLongDouble(const ValkeyModuleString *str, long double *ld);
int ValkeyModule_StringToStreamID(const ValkeyModuleString *str,
                                  ValkeyModuleStreamID *id);
```

All return `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` on parse failure. Strict parsing - no whitespace allowed.

```c
long long count;
if (ValkeyModule_StringToLongLong(argv[2], &count) == VALKEYMODULE_ERR) {
    return ValkeyModule_ReplyWithError(ctx, "ERR invalid count");
}
```

`StringToStreamID` accepts `+` and `-` as special stream IDs.

## Comparison and Modification

```c
int ValkeyModule_StringCompare(const ValkeyModuleString *a,
                               const ValkeyModuleString *b);
int ValkeyModule_StringAppendBuffer(ValkeyModuleCtx *ctx,
                                    ValkeyModuleString *str,
                                    const char *buf, size_t len);
```

`StringCompare` returns a negative, zero, or positive integer (byte-by-byte comparison via `memcmp` semantics, no encoding/collation). Do not assume the value is exactly -1 or 1.

`StringAppendBuffer` appends to a string in place. The string must have refcount 1 (not shared). Returns `VALKEYMODULE_ERR` if the string is shared. Cannot be used on strings obtained via `HoldString`.

```c
ValkeyModuleString *s = ValkeyModule_CreateString(ctx, "hello", 5);
ValkeyModule_StringAppendBuffer(ctx, s, " world", 6);
```

## Memory Optimization

```c
void ValkeyModule_TrimStringAllocation(ValkeyModuleString *str);
```

Reallocates strings to remove excess memory. Important for retained strings from client argv buffers, which may have over-allocated network buffers.

Call guidelines:
- Call explicitly after `RetainString` or `HoldString` for long-lived strings
- Must be called before the string is accessible to other threads
- Not thread safe

```c
ValkeyModule_RetainString(ctx, argv[1]);
ValkeyModule_TrimStringAllocation(argv[1]);
/* Now safe to store and access from other threads (with GIL for argv strings) */
```

## See Also

- [reply-building.md](reply-building.md) - Using strings in replies (ReplyWithString)
- [key-string.md](key-string.md) - String key operations (StringSet, StringDMA)
- [key-generic.md](key-generic.md) - Opening keys that return ValkeyModuleString
- [registration.md](registration.md) - Command argv is ValkeyModuleString array
- [../lifecycle/context.md](../lifecycle/context.md) - Context for automatic string memory management
- [../lifecycle/memory.md](../lifecycle/memory.md) - Manual memory management for strings outside auto-memory
