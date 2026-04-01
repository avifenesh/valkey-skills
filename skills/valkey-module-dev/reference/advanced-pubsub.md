# Pub/Sub - Publish Messages from Modules

Use when publishing messages to channels or shard channels from within a module, notifying subscribers of module-side events, or choosing between the module publish API and calling the PUBLISH command via ValkeyModule_Call.

Source: `src/module.c` (lines 3997-4007), `src/valkeymodule.h` (lines 1701-1706), `src/pubsub.c` (lines 641-647)

## Contents

- [ValkeyModule_PublishMessage](#valkeymodule_publishmessage)
- [ValkeyModule_PublishMessageShard](#valkeymodule_publishmessageshard)
- [Channel vs Shard Channel Semantics](#channel-vs-shard-channel-semantics)
- [Cluster Propagation](#cluster-propagation)
- [Module API vs PUBLISH Command](#module-api-vs-publish-command)
- [Usage Example](#usage-example)

---

## ValkeyModule_PublishMessage

```c
int ValkeyModule_PublishMessage(ValkeyModuleCtx *ctx,
                                ValkeyModuleString *channel,
                                ValkeyModuleString *message);
```

Publishes a message to all clients subscribed to the given channel. This is the module-API equivalent of the `PUBLISH` command.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context. Not used internally but required by the API signature. |
| `channel` | Channel name to publish to. |
| `message` | Message payload to deliver to subscribers. |

**Return value:** The number of clients that received the message on the local node. In a cluster, this count reflects only local delivery - it does not include clients connected to other nodes that also received the message via cluster propagation.

Internally this calls `pubsubPublishMessageAndPropagateToCluster(channel, message, 0)`, which:

1. Delivers the message to all locally connected clients subscribed to the exact channel name.
2. Delivers the message to all locally connected clients whose pattern subscriptions (via PSUBSCRIBE) match the channel name.
3. In cluster mode, propagates the message to all other nodes in the cluster via the cluster bus.

```c
/* Publish a status update when a background job completes */
void onJobComplete(ValkeyModuleCtx *ctx, const char *job_id) {
    ValkeyModuleString *channel = ValkeyModule_CreateStringPrintf(ctx,
        "mymod:jobs:%s", job_id);
    ValkeyModuleString *msg = ValkeyModule_CreateString(ctx, "done", 4);

    int receivers = ValkeyModule_PublishMessage(ctx, channel, msg);
    ValkeyModule_Log(ctx, "verbose", "Published to %d local receivers", receivers);

    ValkeyModule_FreeString(ctx, channel);
    ValkeyModule_FreeString(ctx, msg);
}
```

## ValkeyModule_PublishMessageShard

```c
int ValkeyModule_PublishMessageShard(ValkeyModuleCtx *ctx,
                                     ValkeyModuleString *channel,
                                     ValkeyModuleString *message);
```

Publishes a message to all clients subscribed to the given shard channel via SSUBSCRIBE. This is the module-API equivalent of the `SPUBLISH` command.

Parameters and return value are identical to `ValkeyModule_PublishMessage`. The difference is in the delivery scope.

Internally this calls `pubsubPublishMessageAndPropagateToCluster(channel, message, 1)`, which:

1. Delivers the message to all locally connected clients subscribed to the shard channel.
2. Does not check pattern subscriptions. Shard channels ignore PSUBSCRIBE patterns entirely.
3. In cluster mode, propagates the message only to nodes in the same shard (the primary and its replicas) rather than to the entire cluster.

```c
/* Notify shard-local subscribers about a key update */
void notifyShardUpdate(ValkeyModuleCtx *ctx, ValkeyModuleString *key) {
    ValkeyModuleString *channel = ValkeyModule_CreateStringPrintf(ctx,
        "mymod:update:{%s}", ValkeyModule_StringPtrLen(key, NULL));
    ValkeyModuleString *msg = ValkeyModule_CreateString(ctx, "changed", 7);

    ValkeyModule_PublishMessageShard(ctx, channel, msg);

    ValkeyModule_FreeString(ctx, channel);
    ValkeyModule_FreeString(ctx, msg);
}
```

## Channel vs Shard Channel Semantics

The two publish functions differ in three ways:

| Aspect | PublishMessage (global) | PublishMessageShard (shard) |
|--------|------------------------|-----------------------------|
| Subscribe command | SUBSCRIBE | SSUBSCRIBE |
| Pattern matching | Yes - PSUBSCRIBE patterns checked | No - patterns ignored |
| Cluster propagation | All nodes in the cluster | Only nodes in the same shard |

- `PublishMessage` - for notifications that any client in the cluster should receive, regardless of which node they are connected to. Matches the classic PUBLISH/SUBSCRIBE model.
- `PublishMessageShard` - for notifications relevant only to a specific hash slot's data. Shard channels are cheaper in cluster mode because the message only travels within the shard. Clients must connect to the node that owns the slot and use SSUBSCRIBE.

Shard channels are a cluster-mode concept. In standalone mode, both functions behave similarly - they deliver to locally subscribed clients. The distinction in pattern matching still applies: `PublishMessageShard` never checks pattern subscriptions even in standalone mode.

## Cluster Propagation

Both functions propagate messages across the cluster when `cluster-enabled` is set to `yes`. The propagation is handled automatically through the cluster bus - no extra module code is required.

For global publish (`PublishMessage`), the message is sent to every other node in the cluster. Each receiving node delivers the message to its own locally connected subscribers.

For shard publish (`PublishMessageShard`), the channel name is hashed to determine the owning slot. The message is sent only to nodes that serve that slot - the primary and its replicas. This makes shard channels significantly more efficient in large clusters.

In standalone (non-cluster) mode, no propagation occurs. Messages are delivered only to clients connected to the single server. Replication to replicas is handled at the command level by the server when publish calls are made within a command context.

## Module API vs PUBLISH Command

Modules can also publish messages by calling the PUBLISH or SPUBLISH commands through `ValkeyModule_Call`:

```c
/* Using ValkeyModule_Call - less efficient, more overhead */
ValkeyModuleCallReply *reply = ValkeyModule_Call(ctx, "PUBLISH", "ss",
    channel, message);
ValkeyModule_FreeCallReply(reply);
```

Advantages over ValkeyModule_Call:

- **No command overhead.** The API calls the internal publish function directly, bypassing command parsing, ACL checks, and call reply allocation.
- **Direct return value.** The receiver count is returned as an int rather than wrapped in a CallReply that must be parsed and freed.
- **No context flags needed.** ValkeyModule_Call requires careful handling of format specifiers and propagation flags. The publish APIs handle propagation internally.
- **Simpler error handling.** The publish APIs always succeed - there is no error path to check.

Use ValkeyModule_Call for PUBLISH only if you need specific propagation control through format specifiers (e.g., the `"0"` flag to suppress replication), which is rare.

## Usage Example

A complete module that publishes events when keys are modified:

```c
#include "valkeymodule.h"

int cmd_set_and_notify(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);

    /* Set the key value */
    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1],
        VALKEYMODULE_WRITE);
    ValkeyModule_StringSet(key, argv[2]);
    ValkeyModule_CloseKey(key);

    /* Publish a notification on a global channel */
    ValkeyModuleString *channel = ValkeyModule_CreateStringPrintf(ctx,
        "mymod:changed");
    int receivers = ValkeyModule_PublishMessage(ctx, channel, argv[1]);
    ValkeyModule_FreeString(ctx, channel);

    ValkeyModule_ReplyWithLongLong(ctx, receivers);
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv,
                        int argc) {
    UNUSED(argv);
    UNUSED(argc);

    if (ValkeyModule_Init(ctx, "notify", 1, VALKEYMODULE_APIVER_1)
        == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "notify.set", cmd_set_and_notify,
        "write", 1, 1, 1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```
