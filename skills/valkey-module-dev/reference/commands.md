# Command Registration and Reply Building

Use when registering commands, defining subcommands, parsing arguments, building replies, accessing keys, calling other commands, or implementing blocking commands. Source: `src/valkeymodule.h`, `src/module.c`

## Contents

- Command Registration (line 19)
- Subcommands (line 68)
- Command Metadata (line 78)
- Argument Parsing (line 86)
- Reply Building (line 116)
- Key Access (line 158)
- Calling Other Commands (line 166)
- Blocking Commands (line 178)
- Replication (line 201)

---

## Command Registration

Register during `ValkeyModule_OnLoad`:

```c
int ValkeyModule_CreateCommand(
    ValkeyModuleCtx *ctx,
    const char *name,              // e.g., "mymod.set"
    ValkeyModuleCmdFunc cmdfunc,   // handler function
    const char *strflags,          // space-separated flags
    int firstkey,                  // 1-based index of first key arg (0 = no keys)
    int lastkey,                   // last key arg index (-1 = same as last arg)
    int keystep                    // step between key args (0 = no keys)
);
```

Handler signature - always return `VALKEYMODULE_OK`:

```c
int MyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc);
```

Errors are communicated via reply functions, never via the return value.

### Command Flags

| Flag | Meaning |
|------|---------|
| `"write"` | May modify the dataset |
| `"readonly"` | Returns data, never writes |
| `"admin"` | Administrative command |
| `"deny-oom"` | Deny during out-of-memory |
| `"fast"` | O(log N) or better time complexity |
| `"blocking"` | May block the client |
| `"no-cluster"` | Not designed for cluster mode |
| `"no-auth"` | Can run without authentication |
| `"allow-loading"` | Allow while server is loading |
| `"allow-busy"` | Allow while server is blocked by script |
| `"allow-stale"` | Allow on replicas with stale data |
| `"pubsub"` | Publishes on Pub/Sub channels |
| `"may-replicate"` | May generate replication traffic |
| `"no-mandatory-keys"` | All keys are optional |
| `"getkeys-api"` | Module provides custom key extraction |
| `"no-monitor"` | Exclude from MONITOR |
| `"no-commandlog"` | Exclude from command log |
| `"deny-script"` | Cannot be called from Lua scripts |

---

## Subcommands

```c
ValkeyModuleCommand *parent = ValkeyModule_GetCommand(ctx, "mymod.cmd");
ValkeyModule_CreateSubcommand(parent, "get", SubGet, "readonly fast", 1, 1, 1);
ValkeyModule_CreateSubcommand(parent, "set", SubSet, "write", 1, 1, 1);
```

---

## Command Metadata

Provide rich documentation visible in `COMMAND DOCS` via `ValkeyModule_SetCommandInfo`. Pass a `ValkeyModuleCommandInfo` struct with `.summary`, `.complexity`, `.since`, `.arity`, `.key_specs` (array of `ValkeyModuleCommandKeySpec`), and `.args` (array of `ValkeyModuleCommandArg`). Terminate spec/arg arrays with a zeroed entry.

Set ACL categories: `ValkeyModule_SetCommandACLCategories(ValkeyModule_GetCommand(ctx, "mymod.set"), "mymod")`.

---

## Argument Parsing

### String access

```c
size_t len;
const char *str = ValkeyModule_StringPtrLen(argv[1], &len);  // read-only pointer

long long val;
ValkeyModule_StringToLongLong(argv[2], &val);

double dval;
ValkeyModule_StringToDouble(argv[2], &dval);

long double ldval;
ValkeyModule_StringToLongDouble(argv[2], &ldval);
```

### Creating strings

`CreateString(ctx, buf, len)`, `CreateStringFromLongLong(ctx, val)`, `CreateStringPrintf(ctx, fmt, ...)`, `CreateStringFromString(ctx, other)`. Free with `FreeString(ctx, s)` unless auto-memory is enabled.

### Arity check

```c
if (argc != 3) return ValkeyModule_WrongArity(ctx);
```

---

## Reply Building

| Function | Reply type |
|----------|-----------|
| `ReplyWithLongLong(ctx, val)` | Integer |
| `ReplyWithDouble(ctx, val)` | Double |
| `ReplyWithSimpleString(ctx, str)` | Status (+OK style) |
| `ReplyWithCString(ctx, str)` | Bulk string (null-terminated) |
| `ReplyWithStringBuffer(ctx, buf, len)` | Bulk string (binary-safe) |
| `ReplyWithString(ctx, vmstr)` | Bulk string (ValkeyModuleString) |
| `ReplyWithNull(ctx)` | Null |
| `ReplyWithBool(ctx, val)` | Boolean (RESP3) |
| `ReplyWithError(ctx, msg)` | Error (prefix with ERR or type) |
| `ReplyWithErrorFormat(ctx, fmt, ...)` | Formatted error |
| `ReplyWithBigNumber(ctx, str, len)` | Big number (RESP3) |
| `ReplyWithVerbatimString(ctx, str, len)` | Verbatim string (RESP3) |

### Arrays and nested structures

Fixed-length:
```c
ValkeyModule_ReplyWithArray(ctx, 3);
ValkeyModule_ReplyWithLongLong(ctx, 1);
ValkeyModule_ReplyWithLongLong(ctx, 2);
ValkeyModule_ReplyWithLongLong(ctx, 3);
```

Dynamic-length:
```c
ValkeyModule_ReplyWithArray(ctx, VALKEYMODULE_POSTPONED_LEN);
int count = 0;
while (has_more()) {
    ValkeyModule_ReplyWithString(ctx, item);
    count++;
}
ValkeyModule_ReplySetArrayLength(ctx, count);
```

RESP3 maps and sets: `ReplyWithMap(ctx, count)`, `ReplyWithSet(ctx, count)`. Both support `VALKEYMODULE_POSTPONED_LEN`.

---

## Key Access

Open: `ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_READ | VALKEYMODULE_WRITE)`. Inspect: `ValkeyModule_KeyType(key)` returns `KEYTYPE_EMPTY`, `KEYTYPE_STRING`, `KEYTYPE_LIST`, `KEYTYPE_HASH`, `KEYTYPE_SET`, `KEYTYPE_ZSET`, `KEYTYPE_MODULE`, `KEYTYPE_STREAM`.

Open flags: `READ`, `WRITE`, `OPEN_KEY_NOTOUCH` (no LRU update), `OPEN_KEY_NONOTIFY`, `OPEN_KEY_NOSTATS`, `OPEN_KEY_NOEXPIRE`, `OPEN_KEY_NOEFFECTS` (all "no" flags). Expiry: `SetExpire(key, ms)`, `GetExpire(key)`, `SetAbsExpire(key, unix_ms)`. Delete: `DeleteKey(key)`. Close: `CloseKey(key)` (automatic with auto-memory).

---

## Calling Other Commands

```c
ValkeyModuleCallReply *reply = ValkeyModule_Call(ctx, "SET", "!scs", argv[1], "NX", argv[2]);
```

Format specifiers: `c` (C string), `s` (ValkeyModuleString), `l` (long long), `b` (buffer + len), `v` (ValkeyModuleString vector).

Behavior flags (prefix): `!` (replicate), `A` (no AOF, needs `!`), `R` (no replicas, needs `!`), `C` (ACL check), `S` (script mode), `W` (no writes), `M` (respect deny-oom), `E` (return errors as reply), `0` (auto RESP), `3` (force RESP3).

---

## Blocking Commands

```c
ValkeyModuleBlockedClient *bc = ValkeyModule_BlockClient(ctx, reply_cb, timeout_cb, free_cb, timeout_ms);
```

From a background thread, unblock with result:
```c
ValkeyModule_UnblockClient(bc, privdata);
```

The `reply_cb` receives `privdata` and sends the response. Always call `UnblockClient` even if the client disconnected.

### Blocking on keys

`BlockClientOnKeys` takes the same parameters plus `keys`, `numkeys`, `privdata`. The `reply_cb` fires when a watched key is signaled - return `VALKEYMODULE_ERR` to keep waiting. Signal readiness from write commands: `ValkeyModule_SignalKeyAsReady(ctx, keyname)`.

### Thread-safe contexts

For background threads: `GetThreadSafeContext(bc)` returns a context that must be locked/unlocked with `ThreadSafeContextLock`/`ThreadSafeContextUnlock` and freed with `FreeThreadSafeContext`. For detached contexts: `GetDetachedThreadSafeContext(ctx)`.

---

## Replication

Replicate a command explicitly:

```c
ValkeyModule_Replicate(ctx, "MYMOD.SET", "sls", argv[1], count, argv[2]);
```

Or replicate the exact command received:
```c
ValkeyModule_ReplicateVerbatim(ctx);
```
