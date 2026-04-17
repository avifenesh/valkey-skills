# Client Command Patterns: MULTI/EXEC, Blocking, Pub/Sub

Command patterns beyond the standard dispatch: transactions, blocking reads, and pub/sub. The coordinated-failover `-REDIRECT` flow threads through all three - see `networking.md` for the full branch.

## MULTI / EXEC (`src/multi.c`)

Agent-knowable from Redis. Only wrinkle: during `CLUSTER FAILOVER` with `FAILOVER_IN_PROGRESS`, `processCommand`'s `-REDIRECT` branch calls `discardTransaction(c)` on `EXEC` (and `flagTransaction` on non-EXEC commands). Your transaction gets torn down, not completed across the failover.

## Blocking operations (`src/blocked.c`)

`blockForKeys`, `db->blocking_keys`, `signalKeyAsReady`, `handleClientsBlockedOnKeys` from `beforeSleep`, `pending_command` re-execution - unchanged from Redis.

Valkey-specific branch: during `FAILOVER_IN_PROGRESS`, blocked clients go through `blockPostponeClient` instead of receiving a reply and resume once the replica is promoted. Otherwise `-REDIRECT` is emitted for clients with redirect capability.

## Pub/Sub (`src/pubsub.c`)

Base RESP3 push / RESP2 array mechanics and sharded pub/sub (`SSUBSCRIBE` / `SPUBLISH`) are unchanged.

Storage diverged:

| Structure | Type |
|-----------|------|
| `server.pubsub_channels` | `kvstore` |
| `server.pubsubshard_channels` | `kvstore` |
| `server.pubsub_patterns` | `dict` (still) |
| Per-client `pubsub_channels` / `pubsub_patterns` | `hashtable` |

Consequences:
- Iterating channel subscriptions on the server goes through the `kvstore` API (slot-per-hashtable in cluster mode).
- Pattern subscriptions still use `dict` - legacy `dict*` APIs apply.
- Per-client state moved to `hashtable` - diff-reviews on pub/sub code will see `hashtable*` where pre-Valkey code had `dict*`.

## Keyspace Notifications (`src/notify.c`)

Same `__keyspace@<db>__:<key>` / `__keyevent@<db>__:<event>` channels as Redis, same `notify-keyspace-events` flag string. Valkey additions:

- Flag `n` = "new key creation" notification (`NOTIFY_NEW`).
- Flag `A` expands to `g$lshzxetd` - explicitly **does not** include `m` (KEY_MISS) or `n` (NEW); enable those explicitly.
- New `hexpired` event on hash per-field TTL expiry (via `dbReclaimExpiredFields`).
- Module notifications (`moduleNotifyKeyspaceEvent`) always fire regardless of the mask.

**Grep hazard**: `notifyKeyspaceEvent` goes through `pubsubPublishMessage` directly without `clusterPropagatePublish` - so in cluster mode, subscribers only see events for keys that live on the local node.
