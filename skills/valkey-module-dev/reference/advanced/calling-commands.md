# Calling Commands - ValkeyModule_Call and CallReply Handling

Use when executing Valkey commands from within a module, parsing reply objects, or handling async (blocking) command calls.

Source: `src/module.c` (lines 6066-6889), `src/valkeymodule.h`

## Contents

- [ValkeyModule_Call](#valkeymodule_call)
- [Format Specifiers](#format-specifiers)
- [Error Codes](#error-codes)
- [CallReply Types](#callreply-types)
- [Reading Replies](#reading-replies)
- [RESP3 Reply Types](#resp3-reply-types)
- [Promise Replies](#promise-replies)
- [Freeing Replies](#freeing-replies)

---

## ValkeyModule_Call

```c
ValkeyModuleCallReply *ValkeyModule_Call(ValkeyModuleCtx *ctx,
                                        const char *cmdname,
                                        const char *fmt, ...);
```

Executes any Valkey command from module code. The `fmt` string specifies argument types and behavioral flags. Returns a `ValkeyModuleCallReply` on success, or NULL with errno set on failure.

```c
/* Example: increment key by 10 */
ValkeyModuleCallReply *reply = ValkeyModule_Call(ctx, "INCRBY", "sc", argv[1], "10");
if (ValkeyModule_CallReplyType(reply) == VALKEYMODULE_REPLY_INTEGER) {
    long long val = ValkeyModule_CallReplyInteger(reply);
}
ValkeyModule_FreeCallReply(reply);
```

## Format Specifiers

Argument type specifiers - each consumes one or more varargs:

| Specifier | Type | Description |
|-----------|------|-------------|
| `c` | `char *` | Null-terminated C string |
| `s` | `ValkeyModuleString *` | Module string object |
| `b` | `char *, size_t` | Binary buffer with length (two args) |
| `l` | `long long` | Integer value |
| `v` | `ValkeyModuleString **, size_t` | Vector of module strings with count (two args) |

Behavioral modifier flags - no corresponding arguments:

| Flag | Constant | Description |
|------|----------|-------------|
| `!` | `ARGV_REPLICATE` | Replicate command to AOF and replicas |
| `A` | `ARGV_NO_AOF` | Suppress AOF propagation (requires `!`) |
| `R` | `ARGV_NO_REPLICAS` | Suppress replica propagation (requires `!`) |
| `3` | `ARGV_RESP_3` | Return RESP3 reply (e.g. HGETALL returns map) |
| `0` | `ARGV_RESP_AUTO` | Match client's protocol version |
| `C` | `ARGV_RUN_AS_USER` | Run with context user's ACL checks |
| `S` | `ARGV_SCRIPT_MODE` | Script-mode restrictions (deny-script, min-replicas) |
| `W` | `ARGV_NO_WRITES` | Reject write commands |
| `M` | `ARGV_RESPECT_DENY_OOM` | Reject deny-oom commands when over maxmemory |
| `E` | `ARGV_CALL_REPLIES_AS_ERRORS` | Return errors as CallReply objects instead of NULL |
| `D` | `ARGV_DRY_RUN` | Validate without executing (implies `E`) |
| `K` | `ARGV_ALLOW_BLOCK` | Allow blocking commands, returns promise reply |
| `X` | `ARGV_CALL_REPLY_EXACT` | Exact reply types (distinguishes simple/bulk strings) |

```c
/* Replicate to replicas only, run as user, RESP3 */
reply = ValkeyModule_Call(ctx, "HGETALL", "!RC3s", argv[1]);
```

## Error Codes

When `ValkeyModule_Call` returns NULL, errno indicates the reason:

| errno | Meaning |
|-------|---------|
| `EBADF` | Invalid format specifier |
| `EINVAL` | Wrong command arity |
| `ENOENT` | Command does not exist |
| `EPERM` | Key in non-local cluster slot |
| `EROFS` | Write in cluster readonly state |
| `ENETDOWN` | Cluster is down |
| `ENOTSUP` | No ACL user for context (with `C` flag) |
| `EACCES` | ACL permission denied |
| `ENOSPC` | Write or deny-oom command blocked |
| `ESPIPE` | Command not allowed in script mode |

With the `E` flag, these errors are returned as `ValkeyModuleCallReply` objects with type `VALKEYMODULE_REPLY_ERROR` instead of NULL.

## CallReply Types

```c
int ValkeyModule_CallReplyType(ValkeyModuleCallReply *reply);
```

| Type Constant | Description |
|---------------|-------------|
| `VALKEYMODULE_REPLY_STRING` | Bulk string |
| `VALKEYMODULE_REPLY_ERROR` | Error message |
| `VALKEYMODULE_REPLY_INTEGER` | 64-bit integer |
| `VALKEYMODULE_REPLY_ARRAY` | Array of replies |
| `VALKEYMODULE_REPLY_NULL` | Null reply |
| `VALKEYMODULE_REPLY_SIMPLE_STRING` | Simple string (with `X` flag) |
| `VALKEYMODULE_REPLY_ARRAY_NULL` | Null array (with `X` flag) |
| `VALKEYMODULE_REPLY_MAP` | RESP3 map |
| `VALKEYMODULE_REPLY_SET` | RESP3 set |
| `VALKEYMODULE_REPLY_BOOL` | RESP3 boolean |
| `VALKEYMODULE_REPLY_DOUBLE` | RESP3 double |
| `VALKEYMODULE_REPLY_BIG_NUMBER` | RESP3 big number |
| `VALKEYMODULE_REPLY_VERBATIM_STRING` | RESP3 verbatim string |
| `VALKEYMODULE_REPLY_ATTRIBUTE` | RESP3 attribute |
| `VALKEYMODULE_REPLY_PROMISE` | Async promise (with `K` flag) |
| `VALKEYMODULE_REPLY_UNKNOWN` | Unknown type |

## Reading Replies

```c
size_t ValkeyModule_CallReplyLength(ValkeyModuleCallReply *reply);
const char *ValkeyModule_CallReplyStringPtr(ValkeyModuleCallReply *reply, size_t *len);
long long ValkeyModule_CallReplyInteger(ValkeyModuleCallReply *reply);
ValkeyModuleCallReply *ValkeyModule_CallReplyArrayElement(ValkeyModuleCallReply *reply, size_t idx);
ValkeyModuleString *ValkeyModule_CreateStringFromCallReply(ValkeyModuleCallReply *reply);
```

`CreateStringFromCallReply` works with string, error, simple string, and integer reply types. Returns NULL for other types.

## RESP3 Reply Types

```c
double ValkeyModule_CallReplyDouble(ValkeyModuleCallReply *reply);
int ValkeyModule_CallReplyBool(ValkeyModuleCallReply *reply);
const char *ValkeyModule_CallReplyBigNumber(ValkeyModuleCallReply *reply, size_t *len);
const char *ValkeyModule_CallReplyVerbatim(ValkeyModuleCallReply *reply,
                                           size_t *len, const char **format);

ValkeyModuleCallReply *ValkeyModule_CallReplySetElement(ValkeyModuleCallReply *reply, size_t idx);

int ValkeyModule_CallReplyMapElement(ValkeyModuleCallReply *reply, size_t idx,
                                     ValkeyModuleCallReply **key,
                                     ValkeyModuleCallReply **val);

ValkeyModuleCallReply *ValkeyModule_CallReplyAttribute(ValkeyModuleCallReply *reply);

int ValkeyModule_CallReplyAttributeElement(ValkeyModuleCallReply *reply, size_t idx,
                                            ValkeyModuleCallReply **key,
                                            ValkeyModuleCallReply **val);
```

Map and attribute element accessors return `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if index is out of range or wrong type. The `key` and `val` output pointers may be NULL if not needed.

## Promise Replies

When using the `K` flag, blocking commands return `VALKEYMODULE_REPLY_PROMISE`:

```c
void ValkeyModule_CallReplyPromiseSetUnblockHandler(
    ValkeyModuleCallReply *reply,
    ValkeyModuleOnUnblocked on_unblock,
    void *private_data);

int ValkeyModule_CallReplyPromiseAbort(ValkeyModuleCallReply *reply,
                                       void **private_data);
```

The unblock handler must be set immediately after the call (without releasing the GIL). Inside the handler, only these operations are allowed:

- `ValkeyModule_Call` - call additional commands
- `ValkeyModule_OpenKey` - open keys
- Replication APIs

Client-facing APIs (`Reply*`, `BlockClient`, `GetCurrentUserName`) are not allowed in the handler. The module must handle role changes (primary to replica) by aborting pending promises via server events or disconnect callbacks.

`CallReplyPromiseAbort` returns `VALKEYMODULE_OK` if aborted successfully, `VALKEYMODULE_ERR` if execution already finished. On success, the unblock handler is guaranteed not to fire.

Promise replies must be freed while the GIL is locked.

## Freeing Replies

```c
void ValkeyModule_FreeCallReply(ValkeyModuleCallReply *reply);
```

Frees the reply and all nested replies (for arrays, maps, sets). With auto-memory management enabled, replies are freed automatically when the context is destroyed - but explicit freeing is recommended for large replies to reduce memory pressure.

```c
const char *ValkeyModule_CallReplyProto(ValkeyModuleCallReply *reply, size_t *len);
```

Returns a pointer to the raw RESP protocol of the reply, useful for forwarding replies directly.

## See Also

- [replication.md](replication.md) - Replication via Call flags (`!`, `A`, `R`) vs Replicate API
- [acl.md](acl.md) - ACL checking with the `C` flag
- [../commands/reply-building.md](../commands/reply-building.md) - Building replies to send to clients
- [../commands/registration.md](../commands/registration.md) - Registering commands that use Call
- [threading.md](threading.md) - Using ValkeyModule_Call from background threads with the GIL
