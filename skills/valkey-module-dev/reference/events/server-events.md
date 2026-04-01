# Server Events - SubscribeToServerEvent and Event Types

Use when subscribing to server lifecycle events such as replication role changes, persistence, client connections, shutdown, loading, configuration changes, or key removal.

Source: `src/module.c` (lines 11828-12264), `src/valkeymodule.h` (lines 519-849, 695-849)

## Contents

- Subscription API (line 18)
- Callback Signature (line 36)
- Event Types Reference (line 52)
- Data Structures (line 108)
- Unsubscribing (line 189)
- Usage Example (line 193)

---

## Subscription API

```c
int ValkeyModule_SubscribeToServerEvent(ValkeyModuleCtx *ctx,
                                        ValkeyModuleEvent event,
                                        ValkeyModuleEventCallback callback);
```

Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the context has no module reference or the event is unsupported. Pass `NULL` as the callback to unsubscribe from a previously registered event.

Each `ValkeyModuleEvent` is a struct with an `id` and `dataver` field. Use the predefined constants (e.g., `ValkeyModuleEvent_Shutdown`) rather than constructing the struct manually.

To check if a subevent is supported by the running server version:

```c
int ValkeyModule_IsSubEventSupported(ValkeyModuleEvent event, int64_t subevent);
```

## Callback Signature

```c
typedef void (*ValkeyModuleEventCallback)(ValkeyModuleCtx *ctx,
                                          ValkeyModuleEvent eid,
                                          uint64_t subevent,
                                          void *data);
```

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context - usable for calling other module APIs |
| `eid` | The event that fired; compare `eid.id` to distinguish events when one callback handles multiple |
| `subevent` | Event-specific sub-identifier (see tables below) |
| `data` | Pointer to event-specific data structure, or NULL |

## Event Types Reference

### Replication and Cluster Events

| Event Constant | ID | Subevents | Data |
|---|---|---|---|
| `ValkeyModuleEvent_ReplicationRoleChanged` | 0 | `REPLROLECHANGED_NOW_PRIMARY` (0), `REPLROLECHANGED_NOW_REPLICA` (1) | `ValkeyModuleReplicationInfo` |
| `ValkeyModuleEvent_ReplicaChange` | 6 | `REPLICA_CHANGE_ONLINE` (0), `REPLICA_CHANGE_OFFLINE` (1) | None |
| `ValkeyModuleEvent_PrimaryLinkChange` | 7 | `PRIMARY_LINK_UP` (0), `PRIMARY_LINK_DOWN` (1) | None |
| `ValkeyModuleEvent_AtomicSlotMigration` | 19 | `IMPORT_STARTED` (0), `EXPORT_STARTED` (1), `IMPORT_ABORTED` (2), `EXPORT_ABORTED` (3), `IMPORT_COMPLETED` (4), `EXPORT_COMPLETED` (5) | `ValkeyModuleAtomicSlotMigrationInfo` |

### Persistence and Loading Events

| Event Constant | ID | Subevents | Data |
|---|---|---|---|
| `ValkeyModuleEvent_Persistence` | 1 | `RDB_START` (0), `AOF_START` (1), `SYNC_RDB_START` (2), `ENDED` (3), `FAILED` (4), `SYNC_AOF_START` (5) | None |
| `ValkeyModuleEvent_Loading` | 3 | `RDB_START` (0), `AOF_START` (1), `REPL_START` (2), `ENDED` (3), `FAILED` (4) | None |
| `ValkeyModuleEvent_LoadingProgress` | 10 | `PROGRESS_RDB` (0), `PROGRESS_AOF` (1) | `ValkeyModuleLoadingProgress` |
| `ValkeyModuleEvent_ReplAsyncLoad` | 14 | `STARTED` (0), `ABORTED` (1), `COMPLETED` (2) | None |

SYNC_RDB_START and SYNC_AOF_START run in the foreground (SAVE, FLUSHALL, shutdown). Other persistence subevents run in a background fork child.

### Database and Key Events

| Event Constant | ID | Subevents | Data |
|---|---|---|---|
| `ValkeyModuleEvent_FlushDB` | 2 | `FLUSHDB_START` (0), `FLUSHDB_END` (1) | `ValkeyModuleFlushInfo` |
| `ValkeyModuleEvent_SwapDB` | 11 | None | `ValkeyModuleSwapDbInfo` |
| `ValkeyModuleEvent_Key` | 17 | `KEY_DELETED` (0), `KEY_EXPIRED` (1), `KEY_EVICTED` (2), `KEY_OVERWRITTEN` (3) | `ValkeyModuleKeyInfo` |

The `FlushDB_START` fires before the flush, so you can still query the keyspace in the callback.

### Client, Module, and Server Events

| Event Constant | ID | Subevents | Data |
|---|---|---|---|
| `ValkeyModuleEvent_ClientChange` | 4 | `CLIENT_CHANGE_CONNECTED` (0), `CLIENT_CHANGE_DISCONNECTED` (1) | `ValkeyModuleClientInfo` |
| `ValkeyModuleEvent_Shutdown` | 5 | None | None |
| `ValkeyModuleEvent_ModuleChange` | 9 | `MODULE_LOADED` (0), `MODULE_UNLOADED` (1) | `ValkeyModuleModuleChange` |
| `ValkeyModuleEvent_CronLoop` | 8 | None | `ValkeyModuleCronLoop` |
| `ValkeyModuleEvent_Config` | 16 | `CONFIG_CHANGE` (0) | `ValkeyModuleConfigChange` |
| `ValkeyModuleEvent_AuthenticationAttempt` | 18 | None | `ValkeyModuleAuthenticationInfo` |

### Process and Event Loop Events

| Event Constant | ID | Subevents | Data |
|---|---|---|---|
| `ValkeyModuleEvent_ForkChild` | 13 | `FORK_CHILD_BORN` (0), `FORK_CHILD_DIED` (1) | None |
| `ValkeyModuleEvent_EventLoop` | 15 | `EVENTLOOP_BEFORE_SLEEP` (0), `EVENTLOOP_AFTER_SLEEP` (1) | None |

### Deprecated Events

| Event Constant | ID | Notes |
|---|---|---|
| `ValkeyModuleEvent_ReplBackup` | 12 | Deprecated - never fired. Use `ReplAsyncLoad` instead. |

## Data Structures

All structures are versioned for ABI compatibility. Use the typedef alias (without `V1` suffix).

```c
typedef struct {
    uint64_t version;
    int primary;           /* true if primary, false if replica */
    char *primary_host;    /* hostname for NOW_REPLICA */
    int primary_port;      /* port for NOW_REPLICA */
    char *replid1;         /* Main replication ID */
    char *replid2;         /* Secondary replication ID */
    uint64_t repl1_offset; /* Main replication offset */
    uint64_t repl2_offset; /* Offset of replid2 validity */
} ValkeyModuleReplicationInfoV1;

typedef struct {
    uint64_t version;
    int32_t sync;   /* Synchronous or threaded flush */
    int32_t dbnum;  /* Flushed database, -1 for ALL */
} ValkeyModuleFlushInfoV1;

typedef struct {
    uint64_t version;
    uint64_t flags;   /* VALKEYMODULE_CLIENTINFO_FLAG_* */
    uint64_t id;      /* Client ID */
    char addr[46];    /* IPv4 or IPv6 address */
    uint16_t port;    /* TCP port */
    uint16_t db;      /* Selected DB */
} ValkeyModuleClientInfoV1;

typedef struct {
    uint64_t version;
    int32_t hz;       /* Approximate events per second */
} ValkeyModuleCronLoopV1;

typedef struct {
    uint64_t version;
    int32_t hz;       /* Approximate events per second */
    int32_t progress; /* 0-1024, or -1 if unknown */
} ValkeyModuleLoadingProgressV1;

typedef struct {
    uint64_t version;
    const char *module_name;
    int32_t module_version;
} ValkeyModuleModuleChangeV1;

typedef struct {
    uint64_t version;
    int32_t dbnum_first;
    int32_t dbnum_second;
} ValkeyModuleSwapDbInfoV1;

typedef struct {
    uint64_t version;
    ValkeyModuleKey *key; /* Opened key handle */
} ValkeyModuleKeyInfoV1;

typedef struct {
    uint64_t version;
    uint32_t num_changes;
    const char **config_names;
} ValkeyModuleConfigChangeV1;

typedef struct {
    uint64_t version;
    uint64_t client_id;                      /* Client ID */
    const char *username;                    /* Username used for authentication */
    const char *module_name;                 /* Module handling auth, NULL if core */
    ValkeyModuleAuthenticationResult result; /* GRANTED (0) or DENIED (1) */
} ValkeyModuleAuthenticationInfoV1;

typedef struct {
    uint64_t version;
    char job_name[41];                    /* Unique operation ID */
    ValkeyModuleSlotRange *slot_ranges;   /* Array of slot ranges */
    uint32_t num_slot_ranges;
} ValkeyModuleAtomicSlotMigrationInfoV1;
```

## Unsubscribing

Pass `NULL` as the callback to the same event to unsubscribe. All event subscriptions are automatically removed when the module is unloaded.

## Usage Example

```c
void onShutdown(ValkeyModuleCtx *ctx, ValkeyModuleEvent eid,
                uint64_t subevent, void *data) {
    ValkeyModule_Log(ctx, "warning", "Server shutting down - cleaning up");
    /* flush buffers, close connections, etc. */
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "mymodule", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    ValkeyModule_SubscribeToServerEvent(ctx, ValkeyModuleEvent_Shutdown, onShutdown);
    return VALKEYMODULE_OK;
}
```
