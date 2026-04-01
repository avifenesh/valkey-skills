# Pub/Sub Subsystem

Use when working on message broadcasting, channel subscriptions, pattern matching, or sharded pub/sub in cluster mode.

Source: `src/pubsub.c`

## Contents

- Data Structures (line 22)
- Subscribe Flow (line 78)
- Unsubscribe Flow (line 97)
- Message Delivery (line 112)
- Command Implementations (line 138)
- Sharded Pub/Sub (line 152)
- Client Lifecycle (line 162)
- RESP Protocol Differences (line 173)
- Counting Functions (line 177)
- See Also (line 186)

---

## Data Structures

### Server-Side Channel Storage

Global channels and shard channels are stored in separate `kvstore` instances. Pattern subscriptions use a plain dict.

```c
// In struct server (server.h)
kvstore *pubsub_channels;      // Map channels to list of subscribed clients
dict *pubsub_patterns;         // A dict of pubsub_patterns
kvstore *pubsubshard_channels; // Map shard channels in every slot to list of subscribed clients
unsigned int pubsub_clients;   // Number of clients in Pub/Sub mode
```

Each channel entry in the kvstore is a `hashtable` of client pointers. The channel name (robj) is stored in the hashtable's metadata:

```c
*(robj **)hashtableMetadata(clients) = channel;
```

### Client-Side Subscription Tracking

Each subscribing client has a lazily-allocated `ClientPubSubData`:

```c
typedef struct ClientPubSubData {
    hashtable *pubsub_channels;      // channels via SUBSCRIBE
    hashtable *pubsub_patterns;      // patterns via PSUBSCRIBE
    hashtable *pubsubshard_channels; // shard channels via SSUBSCRIBE
    uint64_t client_tracking_redirection;
    rax *client_tracking_prefixes;
} ClientPubSubData;
```

Initialized on first subscribe via `initClientPubSubData()`. Freed on disconnect via `freeClientPubSubData()`, which unsubscribes from everything first.

### Pubsub Type Abstraction

Global and shard pub/sub share the same code path through a `pubsubtype` struct that provides polymorphic dispatch:

```c
typedef struct pubsubtype {
    int shard;
    hashtable *(*clientPubSubChannels)(client *);
    int (*subscriptionCount)(client *);
    kvstore **serverPubSubChannels;
    robj **subscribeMsg;
    robj **unsubscribeMsg;
    robj **messageBulk;
} pubsubtype;
```

Two static instances exist:
- `pubSubType` - global channels, stored in slot 0 of `server.pubsub_channels`
- `pubSubShardType` - shard channels, stored by hash slot in `server.pubsubshard_channels`

## Subscribe Flow

### pubsubSubscribeChannel(client *c, robj *channel, pubsubtype type)

1. Attempt insert into client's channel hashtable via `hashtableFindPositionForInsert()`.
2. If already subscribed, skip - just send the acknowledgment reply.
3. If new subscription:
   - For shard channels in cluster mode, compute `slot = getKeySlot(channel)`.
   - Look up the channel in the server-side kvstore. If not found, create a new `hashtable` for tracking subscriber clients.
   - Add the client to the channel's client hashtable.
   - Add the channel to the client's subscription hashtable.
4. Send subscribe confirmation with current subscription count.

Returns 1 if newly subscribed, 0 if already subscribed.

### pubsubSubscribePattern(client *c, robj *pattern)

Pattern subscriptions use `server.pubsub_patterns` (a dict, not kvstore). Each pattern key maps to a `hashtable` of subscribed clients. Pattern matching uses `stringmatchlen()` (glob-style).

## Unsubscribe Flow

### pubsubUnsubscribeChannel(client *c, robj *channel, int notify, pubsubtype type)

1. Remove channel from client's hashtable.
2. Remove client from the channel's server-side client hashtable.
3. If the channel has zero subscribers, delete the channel entry from the kvstore entirely - this prevents memory abuse from creating millions of channels.
4. Optionally send unsubscribe notification.

The channel robj is protected with `incrRefCount` during unsubscribe because it might be the same pointer stored in the hash tables being modified.

### pubsubShardUnsubscribeAllChannelsInSlot(unsigned int slot)

Bulk unsubscribe for cluster slot migration. Iterates all shard channels in a slot, unsubscribes every client, and removes the channel entries.

## Message Delivery

### pubsubPublishMessageInternal(robj *channel, robj *message, pubsubtype type)

Two-phase delivery:

**Phase 1 - Exact channel match:**
1. For shard channels, compute slot from channel name.
2. Look up the channel in the kvstore to find the subscriber hashtable.
3. Iterate all subscribed clients, send message via `addReplyPubsubMessage()`.

**Phase 2 - Pattern match (global only, skipped for shard):**
1. Iterate `server.pubsub_patterns` dict.
2. For each pattern, test with `stringmatchlen()` against the channel name.
3. On match, iterate that pattern's client hashtable, send via `addReplyPubsubPatMessage()` (includes the matched pattern in the reply).

Returns total receiver count.

### pubsubPublishMessage(robj *channel, robj *message, int sharded)

Thin wrapper selecting `pubSubShardType` or `pubSubType` and calling `pubsubPublishMessageInternal`.

### pubsubPublishMessageAndPropagateToCluster(robj *channel, robj *message, int sharded)

Called by PUBLISH and SPUBLISH commands. Publishes locally, then if cluster is enabled calls `clusterPropagatePublish()` to forward to other nodes.

## Command Implementations

| Command | Function | Notes |
|---------|----------|-------|
| SUBSCRIBE | `subscribeCommand` | Rejects if CLIENT_DENY_BLOCKING (except in MULTI) |
| UNSUBSCRIBE | `unsubscribeCommand` | No args = unsubscribe all |
| PSUBSCRIBE | `psubscribeCommand` | Same deny-blocking check |
| PUNSUBSCRIBE | `punsubscribeCommand` | No args = unsubscribe all patterns |
| PUBLISH | `publishCommand` | Delegates to sentinel in sentinel mode |
| SSUBSCRIBE | `ssubscribeCommand` | Shard-level, always rejects deny-blocking |
| SUNSUBSCRIBE | `sunsubscribeCommand` | No args = unsubscribe all shard channels |
| SPUBLISH | `spublishCommand` | Shard-level publish |
| PUBSUB | `pubsubCommand` | Introspection: CHANNELS, NUMSUB, NUMPAT, SHARDCHANNELS, SHARDNUMSUB |

## Sharded Pub/Sub

Shard channels are scoped to a hash slot. Key differences from global pub/sub:

- Channel stored in `server.pubsubshard_channels` keyed by `keyHashSlot()`.
- Pattern matching is not applied - shard pub/sub ignores patterns entirely.
- `pubsubShardUnsubscribeAllChannelsInSlot()` handles slot migration cleanup.
- `SPUBLISH` propagates via cluster bus with the sharded flag.
- Clients use `SSUBSCRIBE`/`SUNSUBSCRIBE` (not SUBSCRIBE/PSUBSCRIBE).

## Client Lifecycle

When a client subscribes to anything, `markClientAsPubSub()` sets `c->flag.pubsub = 1` and increments `server.pubsub_clients`. On full unsubscribe (zero total subscriptions), `unmarkClientAsPubSub()` reverses this.

On client disconnect, `freeClientPubSubData()` calls:
- `pubsubUnsubscribeAllChannels(c, 0)` - global channels
- `pubsubUnsubscribeShardAllChannels(c, 0)` - shard channels
- `pubsubUnsubscribeAllPatterns(c, 0)` - patterns

The `notify=0` parameter skips sending unsubscribe replies to the disconnecting client.

## RESP Protocol Differences

RESP2 clients receive array replies (`shared.mbulkhdr[3]`). RESP3 clients receive push-type replies (`addReplyPushLen`). The `c->flag.pushing` flag is temporarily set during reply construction to handle this correctly.

## Counting Functions

- `serverPubsubSubscriptionCount()` - total global channels + patterns on server
- `serverPubsubShardSubscriptionCount()` - total shard channels on server
- `clientSubscriptionsCount(c)` - client's global channels + patterns
- `clientShardSubscriptionsCount(c)` - client's shard channels
- `clientTotalPubSubSubscriptionCount(c)` - all of the above combined
- `pubsubTotalSubscriptions()` - patterns + global channels + shard channels server-wide
