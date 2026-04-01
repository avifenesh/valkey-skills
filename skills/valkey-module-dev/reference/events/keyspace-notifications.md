# Keyspace Notifications - Subscribe, Emit, and React to Key Changes

Use when subscribing to keyspace events (key modifications, expirations, evictions), emitting custom notifications from module commands, or scheduling safe write operations inside notification callbacks.

Source: `src/module.c` (lines 9055-9291), `src/valkeymodule.h` (lines 240-264)

## Contents

- SubscribeToKeyspaceEvents (line 20)
- Notification Type Flags (line 36)
- Callback Signature and Behavior (line 59)
- NotifyKeyspaceEvent (line 85)
- GetNotifyKeyspaceEvents (line 104)
- AddPostNotificationJob (line 112)
- Nested Notifications (line 143)
- Usage Example (line 154)

---

## SubscribeToKeyspaceEvents

```c
int ValkeyModule_SubscribeToKeyspaceEvents(ValkeyModuleCtx *ctx,
                                           int types,
                                           ValkeyModuleNotificationFunc callback);
```

Registers a callback to receive keyspace notifications matching the given type mask. Returns `VALKEYMODULE_OK` on success.

Key differences from the server's built-in keyspace notification mechanism:

- Module notifications work regardless of the `notify-keyspace-events` configuration setting. No server-level configuration is required.
- The module does not distinguish between key events and keyspace events. Filtering by key must be done within the callback.
- Subscriptions persist until the module is unloaded. There is no explicit unsubscribe API.

## Notification Type Flags

The `types` parameter is a bitmask of one or more of these flags:

| Flag | Value | Description |
|------|-------|-------------|
| `VALKEYMODULE_NOTIFY_GENERIC` | `1<<2` | Generic commands: DEL, EXPIRE, RENAME |
| `VALKEYMODULE_NOTIFY_STRING` | `1<<3` | String commands: SET, APPEND, INCR |
| `VALKEYMODULE_NOTIFY_LIST` | `1<<4` | List commands: LPUSH, RPOP, etc. |
| `VALKEYMODULE_NOTIFY_SET` | `1<<5` | Set commands: SADD, SREM, etc. |
| `VALKEYMODULE_NOTIFY_HASH` | `1<<6` | Hash commands: HSET, HDEL, etc. |
| `VALKEYMODULE_NOTIFY_ZSET` | `1<<7` | Sorted set commands: ZADD, ZREM, etc. |
| `VALKEYMODULE_NOTIFY_EXPIRED` | `1<<8` | Key expiration events |
| `VALKEYMODULE_NOTIFY_EVICTED` | `1<<9` | Key eviction events |
| `VALKEYMODULE_NOTIFY_STREAM` | `1<<10` | Stream commands: XADD, XDEL, etc. |
| `VALKEYMODULE_NOTIFY_KEY_MISS` | `1<<11` | Key-miss events (read commands on missing keys) |
| `VALKEYMODULE_NOTIFY_LOADED` | `1<<12` | Key loaded from persistence (module-only) |
| `VALKEYMODULE_NOTIFY_MODULE` | `1<<13` | Module type events |
| `VALKEYMODULE_NOTIFY_NEW` | `1<<14` | New key creation |
| `VALKEYMODULE_NOTIFY_ALL` | combined | All standard types |

`VALKEYMODULE_NOTIFY_ALL` is the OR of GENERIC, STRING, LIST, SET, HASH, ZSET, EXPIRED, EVICTED, STREAM, and MODULE. It intentionally excludes KEY_MISS, LOADED, and NEW.

## Callback Signature and Behavior

```c
typedef int (*ValkeyModuleNotificationFunc)(ValkeyModuleCtx *ctx,
                                            int type,
                                            const char *event,
                                            ValkeyModuleString *key);
```

| Parameter | Description |
|-----------|-------------|
| `ctx` | Notification context - cannot be used to send replies to clients |
| `type` | The event type bit that matched the registration mask |
| `event` | The command name that triggered the notification (e.g., "set", "del") |
| `key` | The affected key name |

The context's selected database matches the database where the event occurred.

**Critical constraints:**

- Callbacks execute synchronously in the server's main thread. Keep them fast.
- Do not perform write operations inside the callback. Write operations during a notification can cause replication and AOF inconsistencies.
- Use `ValkeyModule_AddPostNotificationJob` for safe write reactions.
- The `VALKEYMODULE_NOTIFY_LOADED` flag fires during RDB/AOF loading. The key string cannot be retained - use `ValkeyModule_CreateStringFromString` to make a copy.
- `VALKEYMODULE_NOTIFY_KEY_MISS` fires from read commands. Performing writes from within this notification will cause the read command to be replicated to AOF/replica, which is incorrect.

## NotifyKeyspaceEvent

```c
int ValkeyModule_NotifyKeyspaceEvent(ValkeyModuleCtx *ctx,
                                     int type,
                                     const char *event,
                                     ValkeyModuleString *key);
```

Emit a keyspace notification from a module command. This triggers the standard notification dispatch, notifying both module subscribers and pub/sub keyspace notification subscribers.

| Parameter | Description |
|-----------|-------------|
| `type` | One of the `VALKEYMODULE_NOTIFY_*` flags |
| `event` | Event name string (e.g., "mycommand.update") |
| `key` | The key the event relates to |

Returns `VALKEYMODULE_ERR` if `ctx` or `ctx->client` is NULL.

## GetNotifyKeyspaceEvents

```c
int ValkeyModule_GetNotifyKeyspaceEvents(void);
```

Returns the server's configured `notify-keyspace-events` bitmask. Use this for additional filtering if your module should only react when the server's own keyspace notification system is enabled for a given event type.

## AddPostNotificationJob

```c
int ValkeyModule_AddPostNotificationJob(ValkeyModuleCtx *ctx,
                                        ValkeyModulePostNotificationJobFunc callback,
                                        void *privdata,
                                        void (*free_privdata)(void *));
```

Schedules a write-safe callback to execute after the current notification processing completes. The job runs atomically alongside the notification - it is part of the same execution unit.

The callback signature:

```c
typedef void (*ValkeyModulePostNotificationJobFunc)(ValkeyModuleCtx *ctx,
                                                    void *privdata);
```

**Return values:**

| Return | Condition |
|--------|-----------|
| `VALKEYMODULE_OK` | Job scheduled successfully |
| `VALKEYMODULE_ERR` | Called during AOF/RDB loading, or on a read-only replica |

**Important notes:**

- Jobs may trigger further keyspace notifications, which may register more jobs. The server makes no attempt to detect infinite loops - this is a logical bug the module must prevent.
- The `free_privdata` callback can be NULL if no cleanup is needed.
- The job callback receives a temporary client context with the correct database selected.

## Nested Notifications

By default, a keyspace notification callback is marked as active and will not be re-entered by its own side effects. To allow nested notifications, set the module option:

```c
ValkeyModule_SetModuleOptions(ctx,
    VALKEYMODULE_OPTIONS_ALLOW_NESTED_KEYSPACE_NOTIFICATIONS);
```

This enables the same subscriber to be notified about events triggered by its own actions. Use with care to avoid infinite recursion.

## Usage Example

```c
int onKeyChange(ValkeyModuleCtx *ctx, int type, const char *event,
                ValkeyModuleString *key) {
    if (type & VALKEYMODULE_NOTIFY_EXPIRED) {
        const char *keyname = ValkeyModule_StringPtrLen(key, NULL);
        ValkeyModule_Log(ctx, "notice", "Key expired: %s", keyname);
    }
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "mymodule", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    ValkeyModule_SubscribeToKeyspaceEvents(ctx,
        VALKEYMODULE_NOTIFY_EXPIRED | VALKEYMODULE_NOTIFY_EVICTED,
        onKeyChange);
    return VALKEYMODULE_OK;
}
```
