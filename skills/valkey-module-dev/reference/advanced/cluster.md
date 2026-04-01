# Cluster API - Messaging, Node Info, Slot Operations

Use when building cluster-aware modules, sending inter-node messages, querying cluster topology, or computing key-to-slot mappings.

Source: `src/module.c` (lines 9294-9598), `src/valkeymodule.h`

## Contents

- [Cluster Messaging](#cluster-messaging)
- [Node Discovery](#node-discovery)
- [Node Information](#node-information)
- [Cluster Flags](#cluster-flags)
- [Slot Operations](#slot-operations)

---

## Cluster Messaging

Register a receiver for custom module-to-module cluster messages:

```c
void ValkeyModule_RegisterClusterMessageReceiver(
    ValkeyModuleCtx *ctx,
    uint8_t type,
    ValkeyModuleClusterMessageReceiver callback);
```

The `type` is a uint8_t message identifier (0-254). Each module can register one callback per type. Calling again with the same type replaces the callback. Passing NULL as the callback unregisters the receiver.

Callback signature:

```c
void my_receiver(ValkeyModuleCtx *ctx,
                 const char *sender_id,    /* 40-byte node ID, null-terminated since 8.1 */
                 uint8_t type,
                 const unsigned char *payload,
                 uint32_t len);
```

Send a message to one or all nodes:

```c
int ValkeyModule_SendClusterMessage(ValkeyModuleCtx *ctx,
                                    const char *target_id,
                                    uint8_t type,
                                    const char *msg,
                                    uint32_t len);
```

- `target_id` - a `VALKEYMODULE_NODE_ID_LEN`-byte node ID, or NULL to broadcast to all nodes
- Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if node is unknown or not connected
- Cluster protocol overhead is approximately 30 bytes per message (since Valkey 8.1)

```c
/* Broadcast a notification to all cluster nodes */
const char *payload = "cache_invalidate";
ValkeyModule_SendClusterMessage(ctx, NULL, MY_MSG_TYPE,
                                payload, strlen(payload));

/* Send to a specific node */
ValkeyModule_SendClusterMessage(ctx, node_id, MY_MSG_TYPE,
                                payload, strlen(payload));
```

`RegisterClusterMessageReceiver` is a no-op when cluster mode is disabled. `SendClusterMessage` returns `VALKEYMODULE_ERR` when cluster mode is disabled.

## Node Discovery

```c
const char *ValkeyModule_GetMyClusterID(void);
```

Returns this node's 40-byte cluster ID, or NULL if cluster mode is disabled.

```c
size_t ValkeyModule_GetClusterSize(void);
```

Returns the total number of known nodes (including those in handshake, noaddress, etc.). Returns 0 if cluster mode is disabled. Active node count may be lower.

```c
char **ValkeyModule_GetClusterNodesList(ValkeyModuleCtx *ctx, size_t *numnodes);
void ValkeyModule_FreeClusterNodesList(char **ids);
```

Returns an array of node ID strings, each `VALKEYMODULE_NODE_ID_LEN` bytes. The array must be freed with `FreeClusterNodesList`.

```c
size_t count;
char **ids = ValkeyModule_GetClusterNodesList(ctx, &count);
for (size_t j = 0; j < count; j++) {
    ValkeyModule_Log(ctx, "notice", "Node %.*s",
                     VALKEYMODULE_NODE_ID_LEN, ids[j]);
}
ValkeyModule_FreeClusterNodesList(ids);
```

Returns NULL if cluster mode is disabled.

## Node Information

```c
int ValkeyModule_GetClusterNodeInfo(ValkeyModuleCtx *ctx,
                                    const char *id,
                                    char *ip,
                                    char *primary_id,
                                    int *port,
                                    int *flags);
```

Populates info for the node with the given ID. Any output parameter can be NULL. The `ip` buffer must hold at least `NET_IP_STR_LEN` bytes. The `primary_id` buffer must hold at least `VALKEYMODULE_NODE_ID_LEN` bytes (zeroed if node is a primary or has no primary).

Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the node ID is invalid or unknown.

For client-aware IP resolution (IPv4 vs IPv6):

```c
int ValkeyModule_GetClusterNodeInfoForClient(ValkeyModuleCtx *ctx,
                                              uint64_t client_id,
                                              const char *node_id,
                                              char *ip,
                                              char *primary_id,
                                              int *port,
                                              int *flags);
```

Node flags:

| Flag | Description |
|------|-------------|
| `VALKEYMODULE_NODE_MYSELF` | This node |
| `VALKEYMODULE_NODE_PRIMARY` | Node is a primary |
| `VALKEYMODULE_NODE_REPLICA` | Node is a replica |
| `VALKEYMODULE_NODE_PFAIL` | Possibly failing (local view) |
| `VALKEYMODULE_NODE_FAIL` | Cluster consensus: failing |
| `VALKEYMODULE_NODE_NOFAILOVER` | Replica configured to never failover |

Node ID length constant: `VALKEYMODULE_NODE_ID_LEN` (40 bytes).

## Cluster Flags

```c
void ValkeyModule_SetClusterFlags(ValkeyModuleCtx *ctx, uint64_t flags);
```

Modify cluster behavior for modules that use the cluster message bus as a custom distributed system:

| Flag | Description |
|------|-------------|
| `VALKEYMODULE_CLUSTER_FLAG_NONE` | Default behavior |
| `VALKEYMODULE_CLUSTER_FLAG_NO_FAILOVER` | Disable automatic failover and replica migration |
| `VALKEYMODULE_CLUSTER_FLAG_NO_REDIRECTION` | Accept any key regardless of slot ownership (slots still propagated but not enforced) |

## Slot Operations

```c
unsigned int ValkeyModule_ClusterKeySlot(ValkeyModuleString *key);
unsigned int ValkeyModule_ClusterKeySlotC(const char *key, size_t keylen);
```

Compute the cluster hash slot for a key. Works even if cluster mode is disabled.

```c
const char *ValkeyModule_ClusterCanonicalKeyNameInSlot(unsigned int slot);
```

Returns a short string that hashes to the given slot, suitable as a key or hash tag. Returns NULL if the slot number is invalid (>= 16384).

```c
unsigned int slot = ValkeyModule_ClusterKeySlot(keyname);
const char *tag = ValkeyModule_ClusterCanonicalKeyNameInSlot(slot);
/* tag can be used as "{tag}:suffix" to ensure same-slot keys */
```

## See Also

- [calling-commands.md](calling-commands.md) - Cluster-aware command execution and EPERM/EROFS/ENETDOWN errors
- [pubsub.md](pubsub.md) - PublishMessageShard for shard-scoped messaging
- [../events/server-events.md](../events/server-events.md) - Cluster topology change events
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - Module initialization
