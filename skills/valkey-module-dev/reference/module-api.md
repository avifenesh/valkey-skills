# Module API Overview

Use when starting a new module, understanding the lifecycle, working with the context object, managing memory, subscribing to server events, creating timers, registering module configuration, or sending cluster messages.

Source: `src/valkeymodule.h`, `src/module.c`

---

## Module Lifecycle

A module is a shared library loaded via `dlopen`. The server calls one entry point:

```c
int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc);
```

The legacy `RedisModule_OnLoad` name is also accepted for backward compatibility with Redis 7.2 modules.

Optional unload hook (return `VALKEYMODULE_ERR` to prevent unloading):

```c
int ValkeyModule_OnUnload(ValkeyModuleCtx *ctx);
```

Every `OnLoad` must call `ValkeyModule_Init` before any other API function:

```c
ValkeyModule_Init(ctx, "mymodule", 1, VALKEYMODULE_APIVER_1);
```

Parameters: module name (unique), module version (your scheme), API version (use `VALKEYMODULE_APIVER_1`). Returns `VALKEYMODULE_ERR` if the name is taken.

---

## Context Object

Every API call receives `ValkeyModuleCtx *ctx`. It tracks the calling client, auto-memory queue, postponed replies, and pool allocator state.

Query server/client state with `ValkeyModule_GetContextFlags(ctx)`:

| Flag | Meaning |
|------|---------|
| `VALKEYMODULE_CTX_FLAGS_PRIMARY` | Instance is primary |
| `VALKEYMODULE_CTX_FLAGS_REPLICA` | Instance is replica |
| `VALKEYMODULE_CTX_FLAGS_CLUSTER` | Cluster mode enabled |
| `VALKEYMODULE_CTX_FLAGS_OOM` | Server is out of memory |
| `VALKEYMODULE_CTX_FLAGS_LUA` | Running inside Lua script |
| `VALKEYMODULE_CTX_FLAGS_MULTI` | Inside MULTI transaction |
| `VALKEYMODULE_CTX_FLAGS_LOADING` | Server loading data |
| `VALKEYMODULE_CTX_FLAGS_RESP3` | Client uses RESP3 |

---

## Memory Management

Three allocation strategies, chosen by lifetime:

**Auto-memory** - strings and keys freed when command returns:
```c
ValkeyModule_AutoMemory(ctx);
```

**Pool allocator** - bump allocator, freed when callback returns:
```c
void *ptr = ValkeyModule_PoolAlloc(ctx, bytes);
```

**Module allocator** - persistent, tracked in INFO memory:
```c
void *p = ValkeyModule_Alloc(size);
void *p = ValkeyModule_Calloc(count, size);
void *p = ValkeyModule_Realloc(ptr, newsize);
ValkeyModule_Free(p);
char *s = ValkeyModule_Strdup(str);
```

The `Try` variants (`TryAlloc`, `TryCalloc`, `TryRealloc`) return NULL on failure instead of aborting.

---

## Server Events

Subscribe during `OnLoad` to react to server lifecycle events:

```c
ValkeyModule_SubscribeToServerEvent(ctx, ValkeyModuleEvent_Loading, MyLoadingCallback);
```

Callback signature:
```c
void MyCallback(ValkeyModuleCtx *ctx, ValkeyModuleEvent eid,
                uint64_t subevent, void *data);
```

Key event types:

| Event | Subevent | When |
|-------|----------|------|
| `Loading` | `LOADING_RDB_START`, `AOF_START`, `END` | RDB/AOF loading phases |
| `ClientChange` | `CONNECTED`, `DISCONNECTED` | Client connect/disconnect |
| `Shutdown` | (none) | Server shutting down |
| `ReplicaChange` | `ONLINE`, `OFFLINE` | Replica sync state changes |
| `CronLoop` | (none) | Every server cron cycle (~100ms) |
| `PrimaryLinkChange` | `UP`, `DOWN` | Replica's link to primary |
| `ModuleChange` | `LOADED`, `UNLOADED` | Another module loaded/unloaded |
| `FlushDB` | `START`, `END` | Database flush |
| `SwapDB` | (none) | SWAPDB command (data has db IDs) |
| `Config` | (none) | CONFIG SET (data has changed params) |
| `Key` | (none) | Key written/deleted/expired/evicted |

### Keyspace Notifications

Subscribe to keyspace events (works regardless of `notify-keyspace-events` config):

```c
ValkeyModule_SubscribeToKeyspaceEvents(ctx, VALKEYMODULE_NOTIFY_ALL, MyNotifyCallback);
```

Notification types: `GENERIC`, `STRING`, `LIST`, `SET`, `HASH`, `ZSET`, `EXPIRED`, `EVICTED`, `STREAM`, `MODULE`, `LOADED`, `NEW`, `KEY_MISS`, `ALL`. Note: `KEY_MISS` and `NEW` are excluded from `ALL` - subscribe to them explicitly.

---

## Timers

Create one-shot timers from any context:

```c
ValkeyModuleTimerID ValkeyModule_CreateTimer(ctx, period_ms, MyTimerCallback, privdata);
```

Callback: `void MyTimerCallback(ValkeyModuleCtx *ctx, void *data)`.

Manage: `ValkeyModule_StopTimer(ctx, id, &data)` to cancel and retrieve privdata. `ValkeyModule_GetTimerInfo(ctx, id, &remaining, &data)` to inspect.

---

## Module Configuration

Register typed configuration parameters during `OnLoad`:

```c
ValkeyModule_RegisterStringConfig(ctx, "mymod-name", "default", flags, GetFunc, SetFunc, ApplyFunc, privdata);
ValkeyModule_RegisterBoolConfig(ctx, "mymod-enabled", 1, flags, GetFunc, SetFunc, ApplyFunc, privdata);
ValkeyModule_RegisterNumericConfig(ctx, "mymod-max", 100, flags, min, max, GetFunc, SetFunc, ApplyFunc, privdata);
ValkeyModule_RegisterEnumConfig(ctx, "mymod-mode", 0, flags, names, vals, count, GetFunc, SetFunc, ApplyFunc, privdata);
```

After registering all configs, call `ValkeyModule_LoadConfigs(ctx)` to apply values from `valkey.conf` or `MODULE LOAD` arguments.

Config flags: `VALKEYMODULE_CONFIG_DEFAULT` (0), `VALKEYMODULE_CONFIG_IMMUTABLE` (cannot change at runtime), `VALKEYMODULE_CONFIG_HIDDEN` (not shown in CONFIG GET), `VALKEYMODULE_CONFIG_MEMORY` (numeric is a memory value), `VALKEYMODULE_CONFIG_BITFLAGS` (enum allows bitwise OR).

Users read/write module configs with standard `CONFIG GET mymod-name` / `CONFIG SET mymod-name value`.

---

## Cluster Messaging

Send messages to other nodes via the cluster bus:

```c
ValkeyModule_RegisterClusterMessageReceiver(ctx, MSG_TYPE_ID, MyReceiveCallback);
ValkeyModule_SendClusterMessage(ctx, target_node_id, MSG_TYPE_ID, msg, len);
```

`target_node_id` = NULL broadcasts to all nodes. Message type IDs are module-private uint8_t values (0-255).

Receiver callback: `void MyReceive(ValkeyModuleCtx *ctx, const char *sender_id, uint8_t type, const unsigned char *payload, uint32_t len)`.

Query cluster topology: `ValkeyModule_GetClusterNodesList(ctx)`, `ValkeyModule_GetMyClusterID()`, `ValkeyModule_GetClusterNodeInfo(ctx, node_id, ip, primary_id, &port, &flags)`.

---

## Logging

`ValkeyModule_Log(ctx, level, fmt, ...)` - levels: `"debug"`, `"verbose"`, `"notice"`, `"warning"`. Inside RDB callbacks use `ValkeyModule_LogIOError(io, level, fmt, ...)`.

---

## Module Options

Set during `OnLoad` with `ValkeyModule_SetModuleOptions(ctx, flags)`: `HANDLE_IO_ERRORS` (RDB load can check `IsIOError` instead of crashing), `HANDLE_REPL_ASYNC_LOAD` (async replication loading), `NO_IMPLICIT_SIGNAL_MODIFIED` (manual `SignalModifiedKey`).

---

## Version Checks

`ValkeyModule_GetServerVersion()` returns encoded version (e.g., `0x00090003` for 9.0.3). `RMAPI_FUNC_SUPPORTED(ValkeyModule_SomeFunc)` checks if an API function is available at runtime.
