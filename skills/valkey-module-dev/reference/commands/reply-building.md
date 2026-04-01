# Reply Building - ReplyWith* Functions, RESP2/RESP3, Postponed Lengths

Use when sending replies to clients from module commands, building arrays/maps/sets, or handling RESP2/RESP3 protocol differences.

Source: `src/module.c` (lines 3133-3670), `src/valkeymodule.h`

## Contents

- [Scalar Replies](#scalar-replies) (line 20)
- [String Replies](#string-replies) (line 37)
- [Error Replies](#error-replies) (line 49)
- [Collection Replies](#collection-replies) (line 83)
- [Postponed Length](#postponed-length) (line 115)
- [RESP3-Specific Replies](#resp3-specific-replies) (line 146)
- [Special Replies](#special-replies) (line 160)
- [Forwarding Replies](#forwarding-replies) (line 168)

---

## Scalar Replies

```c
int ValkeyModule_ReplyWithLongLong(ValkeyModuleCtx *ctx, long long ll);
int ValkeyModule_ReplyWithDouble(ValkeyModuleCtx *ctx, double d);
int ValkeyModule_ReplyWithLongDouble(ValkeyModuleCtx *ctx, long double ld);
int ValkeyModule_ReplyWithBool(ValkeyModuleCtx *ctx, int b);
```

All return `VALKEYMODULE_OK`. `ReplyWithDouble` sends a RESP3 Double type (plain string in RESP2). `ReplyWithBool` sends RESP3 Boolean (integer 1/0 in RESP2).

Common pattern - return directly from command:

```c
return ValkeyModule_ReplyWithLongLong(ctx, count);
```

## String Replies

```c
int ValkeyModule_ReplyWithString(ValkeyModuleCtx *ctx, ValkeyModuleString *str);
int ValkeyModule_ReplyWithStringBuffer(ValkeyModuleCtx *ctx, const char *buf, size_t len);
int ValkeyModule_ReplyWithCString(ValkeyModuleCtx *ctx, const char *buf);
int ValkeyModule_ReplyWithSimpleString(ValkeyModuleCtx *ctx, const char *msg);
int ValkeyModule_ReplyWithEmptyString(ValkeyModuleCtx *ctx);
```

`ReplyWithSimpleString` uses RESP `+` prefix - use for short non-binary strings like "OK". The bulk string functions (`ReplyWithString`, `ReplyWithStringBuffer`, `ReplyWithCString`) are for general binary-safe strings.

## Error Replies

```c
int ValkeyModule_ReplyWithError(ValkeyModuleCtx *ctx, const char *err);
int ValkeyModule_ReplyWithErrorFormat(ValkeyModuleCtx *ctx, const char *fmt, ...);
int ValkeyModule_ReplyWithCustomErrorFormat(ValkeyModuleCtx *ctx,
                                            int update_error_stats,
                                            const char *fmt, ...);
int ValkeyModule_WrongArity(ValkeyModuleCtx *ctx);
```

The error string must include the error code prefix. The API adds the leading `-`:

```c
/* Correct - include error code */
ValkeyModule_ReplyWithError(ctx, "ERR Wrong Type");

/* Wrong - missing error code */
ValkeyModule_ReplyWithError(ctx, "Wrong Type");
```

`ReplyWithCustomErrorFormat` works like `ReplyWithErrorFormat` but marks the error as a custom error (e.g., from Lua or a module). When `update_error_stats` is true, server error stats are updated after the reply is sent; when false, no stats are updated. Custom errors are subject to the `ERRORSTATS_LIMIT` - once the RAX of tracked errors reaches its limit, additional custom errors are aggregated under `errorstat_ERRORSTATS_OVERFLOW`.

```c
ValkeyModule_ReplyWithCustomErrorFormat(ctx, 1,
    "MYERR Custom error: %s", detail);
```

Arity check shorthand:

```c
if (argc != 3) return ValkeyModule_WrongArity(ctx);
```

## Collection Replies

```c
int ValkeyModule_ReplyWithArray(ValkeyModuleCtx *ctx, long len);
int ValkeyModule_ReplyWithMap(ValkeyModuleCtx *ctx, long len);
int ValkeyModule_ReplyWithSet(ValkeyModuleCtx *ctx, long len);
int ValkeyModule_ReplyWithAttribute(ValkeyModuleCtx *ctx, long len);
```

After starting a collection, emit the correct number of elements:

- **Array**: `len` calls to `ReplyWith*`
- **Map**: `len * 2` calls (key-value pairs)
- **Set**: `len` calls
- **Attribute**: `len * 2` calls (before the actual reply)

```c
ValkeyModule_ReplyWithArray(ctx, 3);
ValkeyModule_ReplyWithLongLong(ctx, 1);
ValkeyModule_ReplyWithLongLong(ctx, 2);
ValkeyModule_ReplyWithLongLong(ctx, 3);
```

RESP2 fallback: Map and Set degrade to flat arrays. Attribute returns `VALKEYMODULE_ERR` under RESP2.

Helper functions for empty/null collections:

```c
int ValkeyModule_ReplyWithEmptyArray(ValkeyModuleCtx *ctx);
int ValkeyModule_ReplyWithNullArray(ValkeyModuleCtx *ctx);
```

## Postponed Length

Use `VALKEYMODULE_POSTPONED_LEN` when element count is unknown at start:

```c
#define VALKEYMODULE_POSTPONED_LEN -1
```

Set the actual length later with the corresponding function:

```c
void ValkeyModule_ReplySetArrayLength(ValkeyModuleCtx *ctx, long len);
void ValkeyModule_ReplySetMapLength(ValkeyModuleCtx *ctx, long len);
void ValkeyModule_ReplySetSetLength(ValkeyModuleCtx *ctx, long len);
void ValkeyModule_ReplySetAttributeLength(ValkeyModuleCtx *ctx, long len);
```

Multiple postponed collections nest like a stack - each `ReplySet*Length` resolves the most recently opened one:

```c
/* Produce [1, [10, 20, 30]] */
ValkeyModule_ReplyWithArray(ctx, VALKEYMODULE_POSTPONED_LEN);
ValkeyModule_ReplyWithLongLong(ctx, 1);
ValkeyModule_ReplyWithArray(ctx, VALKEYMODULE_POSTPONED_LEN);
ValkeyModule_ReplyWithLongLong(ctx, 10);
ValkeyModule_ReplyWithLongLong(ctx, 20);
ValkeyModule_ReplyWithLongLong(ctx, 30);
ValkeyModule_ReplySetArrayLength(ctx, 3);  /* inner array */
ValkeyModule_ReplySetArrayLength(ctx, 2);  /* outer array */
```

## RESP3-Specific Replies

```c
int ValkeyModule_ReplyWithBigNumber(ValkeyModuleCtx *ctx,
                                    const char *bignum, size_t len);
int ValkeyModule_ReplyWithVerbatimString(ValkeyModuleCtx *ctx,
                                         const char *buf, size_t len);
int ValkeyModule_ReplyWithVerbatimStringType(ValkeyModuleCtx *ctx,
                                              const char *buf, size_t len,
                                              const char *ext);
```

`ReplyWithBigNumber` sends a RESP3 BigNumber (bulk string in RESP2). `ReplyWithVerbatimString` defaults to "txt" extension. `ReplyWithVerbatimStringType` lets you specify a 3-char type (e.g., "mkd" for markdown).

## Special Replies

```c
int ValkeyModule_ReplyWithNull(ValkeyModuleCtx *ctx);
```

Returns a null reply in both RESP2 and RESP3.

## Forwarding Replies

```c
int ValkeyModule_ReplyWithCallReply(ValkeyModuleCtx *ctx,
                                    ValkeyModuleCallReply *reply);
```

Forward the result of `ValkeyModule_Call()` directly to the client. Returns `VALKEYMODULE_ERR` if the reply is RESP3 but the client uses RESP2. Pass `0` as fmt flag in `ValkeyModule_Call()` to match the client's protocol version.

## See Also

- [registration.md](registration.md) - Registering commands that use these reply functions
- [string-objects.md](string-objects.md) - Creating ValkeyModuleString for ReplyWithString
- [../advanced/calling-commands.md](../advanced/calling-commands.md) - ValkeyModule_Call and forwarding CallReply
- [../lifecycle/context.md](../lifecycle/context.md) - Module context passed to reply functions
- [../lifecycle/memory.md](../lifecycle/memory.md) - AutoMemory tracks ValkeyModuleCallReply objects
- [../events/blocking-clients.md](../events/blocking-clients.md) - Reply callbacks for blocked clients
