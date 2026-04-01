# Client Introspection - Identity, Info, Names, and Server State

Use when inspecting the current client, looking up client details by ID, managing client names, checking ACL usernames, querying memory pressure, or redacting sensitive command arguments.

Source: `src/module.c` (lines 3782-3995, 4185-4198, 10482-10498, 11440-11451), `src/valkeymodule.h` (lines 678-722)

## Contents

- [GetClientId](#getclientid)
- [ValkeyModuleClientInfo Struct](#valkeymoduleclientinfo-struct)
- [GetClientInfoById](#getclientinfobyid)
- [Client Info Flags](#client-info-flags)
- [GetClientNameById](#getclientnamebyid)
- [SetClientNameById](#setclientnamebyid)
- [GetClientUserNameById](#getclientusernamebyid)
- [MustObeyClient](#mustobeyclient)
- [AvoidReplicaTraffic](#avoidreplicatraffic)
- [GetUsedMemoryRatio](#getusedmemoryratio)
- [RedactClientCommandArgument](#redactclientcommandargument)

---

## GetClientId

```c
unsigned long long ValkeyModule_GetClientId(ValkeyModuleCtx *ctx);
```

Returns the unique ID of the client executing the current command. IDs are monotonically increasing - clients connecting later always receive higher IDs. Valid IDs range from 1 to 2^64-1. Returns 0 when no client is available in the current context.

The returned ID can identify whether a command is running during AOF loading:

```c
uint64_t id = ValkeyModule_GetClientId(ctx);
if (ValkeyModule_IsAOFClient(id)) {
    /* Command is being replayed from AOF */
}
```

The `ValkeyModule_IsAOFClient(id)` macro (defined in `valkeymodule.h`) checks whether the ID equals `UINT64_MAX`, the sentinel value used for the AOF client.

Within command filters, use `ValkeyModule_CommandFilterGetClientId` instead - it accepts a `ValkeyModuleCommandFilterCtx` rather than a `ValkeyModuleCtx`.

## ValkeyModuleClientInfo Struct

```c
#define VALKEYMODULE_CLIENTINFO_VERSION 1

typedef struct ValkeyModuleClientInfo {
    uint64_t version; /* Version of this structure for ABI compat. */
    uint64_t flags;   /* VALKEYMODULE_CLIENTINFO_FLAG_* */
    uint64_t id;      /* Client ID. */
    char addr[46];    /* IPv4 or IPv6 address. */
    uint16_t port;    /* TCP port. */
    uint16_t db;      /* Selected DB. */
} ValkeyModuleClientInfoV1;

#define ValkeyModuleClientInfo ValkeyModuleClientInfoV1
```

Always initialize with the version macro before passing to `GetClientInfoById`:

```c
ValkeyModuleClientInfo ci = VALKEYMODULE_CLIENTINFO_INITIALIZER_V1;
```

The `version` field tells the server which struct layout to populate, providing ABI compatibility across server upgrades.

## GetClientInfoById

```c
int ValkeyModule_GetClientInfoById(void *ci, uint64_t id);
```

Populates a `ValkeyModuleClientInfo` struct with details about the client identified by `id`. Returns `VALKEYMODULE_OK` if the client exists, `VALKEYMODULE_ERR` otherwise.

Pass NULL for `ci` to check whether a client exists without retrieving details.

```c
ValkeyModuleClientInfo ci = VALKEYMODULE_CLIENTINFO_INITIALIZER_V1;
uint64_t client_id = ValkeyModule_GetClientId(ctx);
int retval = ValkeyModule_GetClientInfoById(&ci, client_id);
if (retval == VALKEYMODULE_OK) {
    ValkeyModule_Log(ctx, "notice",
        "Client %llu from %s:%d on db %d flags=0x%llx",
        ci.id, ci.addr, ci.port, ci.db,
        (unsigned long long)ci.flags);
}
```

## Client Info Flags

Flags returned in `ValkeyModuleClientInfo.flags`:

| Flag | Bit | Description |
|------|-----|-------------|
| `VALKEYMODULE_CLIENTINFO_FLAG_SSL` | 1<<0 | Client using TLS connection |
| `VALKEYMODULE_CLIENTINFO_FLAG_PUBSUB` | 1<<1 | Client in Pub/Sub mode |
| `VALKEYMODULE_CLIENTINFO_FLAG_BLOCKED` | 1<<2 | Client blocked in a command |
| `VALKEYMODULE_CLIENTINFO_FLAG_TRACKING` | 1<<3 | Client-side caching tracking enabled |
| `VALKEYMODULE_CLIENTINFO_FLAG_UNIXSOCKET` | 1<<4 | Client using Unix domain socket |
| `VALKEYMODULE_CLIENTINFO_FLAG_MULTI` | 1<<5 | Client in MULTI transaction |
| `VALKEYMODULE_CLIENTINFO_FLAG_READONLY` | 1<<6 | Client in read-only mode (replicas) |
| `VALKEYMODULE_CLIENTINFO_FLAG_PRIMARY` | 1<<7 | Fake client applying replicated commands from primary |
| `VALKEYMODULE_CLIENTINFO_FLAG_REPLICA` | 1<<8 | Client is a replica |
| `VALKEYMODULE_CLIENTINFO_FLAG_MONITOR` | 1<<9 | Client is in MONITOR mode |
| `VALKEYMODULE_CLIENTINFO_FLAG_MODULE` | 1<<10 | Client is a module connection |
| `VALKEYMODULE_CLIENTINFO_FLAG_AUTHENTICATED` | 1<<11 | Client has been authenticated |
| `VALKEYMODULE_CLIENTINFO_FLAG_EVER_AUTHENTICATED` | 1<<12 | Client was authenticated at some point |
| `VALKEYMODULE_CLIENTINFO_FLAG_FAKE` | 1<<13 | Fake client internal to Valkey |

Note: Flags from `VALKEYMODULE_CLIENTINFO_FLAG_PRIMARY` onward were added in Valkey 9.1.

```c
ValkeyModuleClientInfo ci = VALKEYMODULE_CLIENTINFO_INITIALIZER_V1;
ValkeyModule_GetClientInfoById(&ci, client_id);

if (ci.flags & VALKEYMODULE_CLIENTINFO_FLAG_SSL) {
    /* Client connected over TLS */
}
if (ci.flags & VALKEYMODULE_CLIENTINFO_FLAG_REPLICA) {
    /* Client is a replica - may want to skip expensive operations */
}
```

## GetClientNameById

```c
ValkeyModuleString *ValkeyModule_GetClientNameById(ValkeyModuleCtx *ctx,
                                                    uint64_t id);
```

Returns the name set via `CLIENT SETNAME` for the given client ID. Returns NULL if the client does not exist or has no name. The returned string is auto-memory managed.

## SetClientNameById

```c
int ValkeyModule_SetClientNameById(uint64_t id, ValkeyModuleString *name);
```

Sets the name of the client identified by `id`, equivalent to the client calling `CLIENT SETNAME`. Returns `VALKEYMODULE_OK` on success. On failure returns `VALKEYMODULE_ERR` with errno:

| errno | Cause |
|-------|-------|
| `ENOENT` | Client does not exist |
| `EINVAL` | Name contains invalid characters |

```c
ValkeyModuleString *name = ValkeyModule_CreateString(ctx, "worker-1", 8);
uint64_t id = ValkeyModule_GetClientId(ctx);
if (ValkeyModule_SetClientNameById(id, name) == VALKEYMODULE_ERR) {
    ValkeyModule_Log(ctx, "warning", "Failed to set client name: %s",
                     strerror(errno));
}
```

## GetClientUserNameById

```c
ValkeyModuleString *ValkeyModule_GetClientUserNameById(ValkeyModuleCtx *ctx,
                                                        uint64_t id);
```

Returns the ACL username of the client identified by `id`. The returned string is auto-memory managed. Returns NULL with errno on failure:

| errno | Cause |
|-------|-------|
| `ENOENT` | Client does not exist |
| `ENOTSUP` | Client is not using an ACL user |

```c
uint64_t id = ValkeyModule_GetClientId(ctx);
ValkeyModuleString *user = ValkeyModule_GetClientUserNameById(ctx, id);
if (user) {
    size_t len;
    const char *name = ValkeyModule_StringPtrLen(user, &len);
    ValkeyModule_Log(ctx, "notice", "Command from user: %.*s", (int)len, name);
}
```

## MustObeyClient

```c
int ValkeyModule_MustObeyClient(ValkeyModuleCtx *ctx);
```

Returns 1 if the current command comes from the primary client or the AOF client - contexts where commands must never be rejected. Returns 0 otherwise, or if the context or client is NULL.

Use this to skip validation on replicas so they do not diverge from the primary:

```c
int MyCommand_Handler(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (!ValkeyModule_MustObeyClient(ctx)) {
        /* Validate arguments, check preconditions */
        if (argc < 3) return ValkeyModule_WrongArity(ctx);
    }
    /* Execute the command unconditionally */
    /* ... */
}
```

## AvoidReplicaTraffic

```c
int ValkeyModule_AvoidReplicaTraffic(void);
```

Returns non-zero when the server is pausing replica traffic. Modules with background tasks that generate writes - garbage collection, periodic flushes, timer callbacks - should check this and defer work when it returns true. Generating replication data during a pause makes it harder for replicas to catch up.

```c
int my_timer_callback(ValkeyModuleCtx *ctx, void *data) {
    if (ValkeyModule_AvoidReplicaTraffic()) {
        /* Reschedule - don't generate replication traffic now */
        ValkeyModule_CreateTimer(ctx, 1000, my_timer_callback, data);
        return VALKEYMODULE_OK;
    }
    /* Safe to perform background writes */
    /* ... */
}
```

## GetUsedMemoryRatio

```c
float ValkeyModule_GetUsedMemoryRatio(void);
```

Returns the ratio of currently used memory to the configured `maxmemory` limit:

| Return value | Meaning |
|-------------|---------|
| 0 | No memory limit configured |
| 0 < r < 1 | Percentage of memory used (normalized 0-1) |
| 1 | Memory limit reached |
| > 1 | Memory usage exceeds configured limit |

```c
float ratio = ValkeyModule_GetUsedMemoryRatio();
if (ratio > 0.9f && ratio <= 1.0f) {
    ValkeyModule_Log(ctx, "warning",
        "Memory usage at %.0f%% - consider eviction", ratio * 100);
}
if (ratio > 1.0f) {
    /* Over limit - reject new allocations or trigger cleanup */
}
```

## RedactClientCommandArgument

```c
int ValkeyModule_RedactClientCommandArgument(ValkeyModuleCtx *ctx, int pos);
```

Redacts the command argument at position `pos` so it is obfuscated in SLOWLOG, MONITOR output, and server logs. Position 0 (the command name) cannot be redacted. Can be called multiple times for different positions. Returns `VALKEYMODULE_ERR` if the position is out of range or invalid.

```c
/* Custom AUTH command: redact the password argument */
int MyAuth_Handler(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);
    /* argv[0] = command, argv[1] = username, argv[2] = password */
    ValkeyModule_RedactClientCommandArgument(ctx, 2);
    /* ... verify credentials ... */
}
```
