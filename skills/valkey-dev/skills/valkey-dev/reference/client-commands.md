# Client Command Patterns: MULTI/EXEC, Blocking, Pub/Sub

Command patterns beyond the standard dispatch: transactions, blocking reads, pub/sub, keyspace notifications. The coordinated-failover `-REDIRECT` flow threads through all three - see `networking.md` for the full branch.

Type-handler statement order is load-bearing: type check + `lookupKey`, then state mutation (`dbDelete`, `hashTypeSet`, `listTypePush`), then `signalModifiedKey` + `notifyKeyspaceEvent`, then `addReply*`. The KSN-before-reply rule below enforces the last transition; the others follow from it.

## MULTI / EXEC (`src/multi.c`)

- Coordinated failover tears down transactions. During `CLUSTER FAILOVER` with `FAILOVER_IN_PROGRESS`, `processCommand`'s `-REDIRECT` branch calls `discardTransaction(c)` on `EXEC` and `flagTransaction` on non-EXEC commands. Queued commands do not carry over to the new primary.

## Blocking operations (`src/blocked.c`)

The Redis core (`blockForKeys`, `db->blocking_keys`, `signalKeyAsReady`, `handleClientsBlockedOnKeys` from `beforeSleep`, `pending_command` re-execution) is unchanged. The rules below are Valkey-specific.

- `FAILOVER_IN_PROGRESS` routes blocked clients to `blockPostponeClient` (resumed on promotion) or emits `-REDIRECT` for clients with `CLIENT_CAPA_REDIRECT`.
- Set `primary_host` before the redirect reply. MOVED/REDIRECT during failover is a three-way reply (MOVED in cluster mode, REDIRECT with `CLIENT_CAPA_REDIRECT`, UNBLOCKED+disconnect otherwise); a stale `primary_host` sends the client to a still-replica node.
- `canRedirectClient()` is standalone-only. Cluster nodes use `clusterRedirectBlockedClientIfNeeded`.
- `deny_blocking` is set inside scripts and transactions; module commands that would block are rejected synchronously. Keyspace-notification callbacks are the only legitimate exception.
- Reset the client timeout on `blockClient` creation. BLPOP, `CLUSTER SETSLOT`, and any deadline-scheduling path must write a fresh timeout so subsequent SHUTDOWN / role-change paths see an intact deadline.
- `BLOCKED_INUSE` accounting is one-increment / one-decrement in `server.blocked_clients`. Module clients (`c->flag.module` set) skip the counter in `blockClient` - unconditional decrement on reset underflows.
- `disconnectOrRedirectAllBlockedClients` may skip a `BLOCKED_INUSE` client only if the bgIterator caller guarantees `unblockClientsInUseOnKey` on completion. `blockedClientMayTimeout` returns 0 for this block type.
- Removing the read handler for the duration of a block requires a per-connection-type `is_closing` callback. Missing implementations on unix-socket, RDMA, and FreeBSD leak connection resources.
- Module blocking callbacks run on the main thread only. Background-thread mutation of `server.blocked_clients`, `bstate`, the unblocked queue, or key->client hashtables is a data race.

## Pub/Sub (`src/pubsub.c`)

Storage types:

| Structure | Type |
|-----------|------|
| `server.pubsub_channels` | `kvstore` |
| `server.pubsubshard_channels` | `kvstore` |
| `server.pubsub_patterns` | `dict` (still) |
| Per-client `pubsub_channels` / `pubsub_patterns` | `hashtable` |

- Iterate server-wide channel subscriptions through `kvstore` (slot-per-hashtable in cluster mode). Do not reintroduce flat `dict*` iteration on `server.pubsub_channels` or `server.pubsubshard_channels`.
- Pattern subscriptions still use `dict`. Legacy `dict*` APIs apply to `server.pubsub_patterns` only.
- `notifyKeyspaceEvent` does not propagate across the cluster. It calls `pubsubPublishMessage` directly, bypassing `clusterPropagatePublish`. Subscribers only see events for keys on the local node. Adding a cluster-propagate call here changes the visibility contract and needs a dedicated design review.

## Keyspace Notifications (`src/notify.c`)

- Notification BEFORE reply. `signalModifiedKey` + `notifyKeyspaceEvent` run before any `addReply*`. `addReply*` implicitly calls `prepareClientToWrite`, which installs the client on the pending-write queue and arms the write handler - once queued, the reply flushes before a notification-driven block takes effect.
- If a command must `addReply*` before notifying, buffer through `initDeferredReplyBuffer` - it holds the socket send until after notification and is a no-op when no module subscribes.
- Keyspace events describe the effect on the key, not the command. SREM/ZREM/HDEL that empty a key emit the sub-element-removed event first with the container still present, then `del` when the container is removed. Whole-key DEL runs `dbDelete` first, then `signalModifiedKey` + `notifyKeyspaceEvent`.
- `expire` fires at set-time (EXPIRE/PEXPIRE/EXPIREAT/PEXPIREAT with a positive future timeout). `expired` fires when the key is actually removed because its TTL elapsed. EXPIRE with a past/negative timeout takes the expiration path (fires `expired`, increments `expired_keys`), not DEL.
- A single command may emit multiple events. HSET can emit `hset` + `hexpire` + `hexpired` + `del` when SET-and-EXPIRE semantics collapse a field into an immediate delete. SETEX on strings suppresses `set` when the resulting value is already expired. Do not assume one event per command.
- Consumers must re-fetch on notification. Field-level events (`hset` vs `hexpire` vs `hdel`) are not consistently emitted across versions - treat KSN as "key was modified somehow".
- Module notifications always fire. `moduleNotifyKeyspaceEvent` runs regardless of the `notify-keyspace-events` mask. Do not gate it on the flag string.
- `A` flag expands to `g$lshzxetd`. It does NOT include `m` (KEY_MISS) or `n` (NEW). A diff that adds a letter to `A`'s expansion is a behavior change.
- `hexpired` is a Valkey addition. Fires on hash per-field TTL expiry via `dbReclaimExpiredFields`.
- HSETEX's "nothing was set" return-0 conflates intentional no-ops and no-notify cases (zero TTL, duplicate field args, ineligible fields). If a future change emits KSN for any of those, the return-value semantics must be reconciled with the documented contract - write-completion indicator and notification decision stay coupled.
- `publish(message, channel)` argument-order reversal across GLIDE bindings. Python / Node / Java reverse the arguments; Go / C# / PHP / Ruby keep `publish(channel, message)`. Verify per-language when touching pub/sub integration code.
