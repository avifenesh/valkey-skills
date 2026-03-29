# Pub/Sub Commands

Use when you need real-time message broadcasting - chat, notifications, live updates, event distribution, or inter-service communication. Pub/Sub is fire-and-forget: messages are delivered only to currently connected subscribers. For durable messaging, use Streams instead.

---

## Channel Pub/Sub

### SUBSCRIBE

```
SUBSCRIBE channel [channel ...]
```

Subscribes the client to one or more channels. The client enters subscriber mode and receives messages published to those channels. While in subscriber mode, the client can only execute SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE, SUNSUBSCRIBE, PING, and RESET.

```
SUBSCRIBE notifications:user:1000 chat:room:42
-- Reading messages...
-- 1) "subscribe"
-- 2) "notifications:user:1000"
-- 3) (integer) 1
```

Messages arrive as three-element arrays: message type, channel name, and payload.

### UNSUBSCRIBE

```
UNSUBSCRIBE [channel [channel ...]]
```

Unsubscribes from the specified channels. Without arguments, unsubscribes from all channels.

```
UNSUBSCRIBE notifications:user:1000
```

### PUBLISH

```
PUBLISH channel message
```

Publishes a message to a channel. Returns the number of subscribers that received the message. Does not queue messages - if no subscribers are listening, the message is lost.

**Complexity**: O(N+M) where N is the number of subscribers and M is the number of pattern subscribers

```
PUBLISH notifications:user:1000 '{"type":"new_message","from":"user:2000"}'
-- (integer) 1
```

---

## Pattern Pub/Sub

### PSUBSCRIBE

```
PSUBSCRIBE pattern [pattern ...]
```

Subscribes to channels matching a glob-style pattern. Supported patterns: `*` (any string), `?` (single char), `[...]` (character class).

```
-- Subscribe to all user notifications
PSUBSCRIBE notifications:user:*

-- Subscribe to all chat rooms
PSUBSCRIBE chat:room:?

-- Messages arrive as four-element arrays:
-- 1) "pmessage"
-- 2) "notifications:user:*"    (pattern that matched)
-- 3) "notifications:user:1000" (actual channel)
-- 4) "message body"
```

### PUNSUBSCRIBE

```
PUNSUBSCRIBE [pattern [pattern ...]]
```

Unsubscribes from the specified patterns. Without arguments, unsubscribes from all patterns.

---

## Sharded Pub/Sub

Sharded pub/sub routes messages only within the cluster shard that owns the channel. This avoids broadcasting across all nodes, dramatically reducing cluster bus traffic.

### SSUBSCRIBE

```
SSUBSCRIBE shardchannel [shardchannel ...]
```

Subscribes to one or more shard channels. Messages are only delivered within the shard that owns the channel's hash slot. Available since 7.0.

```
SSUBSCRIBE orders:region:us-east
```

### SUNSUBSCRIBE

```
SUNSUBSCRIBE [shardchannel [shardchannel ...]]
```

Unsubscribes from shard channels. Without arguments, unsubscribes from all shard channels.

### SPUBLISH

```
SPUBLISH shardchannel message
```

Publishes a message to a shard channel. Only subscribers connected to the shard owning that channel receive the message. Returns the number of subscribers that received it.

**Complexity**: O(N) where N is the number of subscribers on that shard

```
SPUBLISH orders:region:us-east '{"order_id":5678,"status":"shipped"}'
-- (integer) 2
```

---

## Introspection

### PUBSUB CHANNELS

```
PUBSUB CHANNELS [pattern]
```

Lists active channels (channels with at least one subscriber). With a pattern, filters by glob match.

```
PUBSUB CHANNELS
-- 1) "notifications:user:1000"
-- 2) "chat:room:42"

PUBSUB CHANNELS "chat:*"
-- 1) "chat:room:42"
```

### PUBSUB NUMSUB

```
PUBSUB NUMSUB [channel [channel ...]]
```

Returns the number of subscribers for the specified channels. Does not count pattern subscribers.

```
PUBSUB NUMSUB notifications:user:1000 chat:room:42
-- 1) "notifications:user:1000"
-- 2) (integer) 3
-- 3) "chat:room:42"
-- 4) (integer) 1
```

### PUBSUB NUMPAT

```
PUBSUB NUMPAT
```

Returns the total number of active pattern subscriptions across all clients.

```
PUBSUB NUMPAT
-- (integer) 5
```

### PUBSUB SHARDCHANNELS

```
PUBSUB SHARDCHANNELS [pattern]
```

Lists active shard channels (channels with at least one shard subscriber). With a pattern, filters by glob match.

```
PUBSUB SHARDCHANNELS "orders:*"
-- 1) "orders:region:us-east"
```

### PUBSUB SHARDNUMSUB

```
PUBSUB SHARDNUMSUB [shardchannel [shardchannel ...]]
```

Returns the number of shard subscribers for the specified shard channels.

```
PUBSUB SHARDNUMSUB orders:region:us-east
-- 1) "orders:region:us-east"
-- 2) (integer) 2
```

---

## Regular vs Sharded Pub/Sub

| Feature | Regular | Sharded |
|---------|---------|---------|
| Commands | SUBSCRIBE / PUBLISH | SSUBSCRIBE / SPUBLISH |
| Cluster behavior | Broadcasts to all nodes | Routes within owning shard only |
| Bus traffic | High (all nodes relay) | Low (single shard) |
| Pattern matching | PSUBSCRIBE supported | Not supported |
| Availability | All versions | 7.0+ |
| Use case | Global events, few channels | High-throughput per-entity events |

---

## Important Constraints

**Fire-and-forget delivery**: Messages are not persisted. If no subscriber is listening when a message is published, the message is lost. For guaranteed delivery, use Streams with consumer groups.

**Subscriber mode restrictions**: Once a client enters subscriber mode (via SUBSCRIBE, PSUBSCRIBE, or SSUBSCRIBE), it can only execute subscription management commands, PING, and RESET. All other commands are rejected. Use a separate connection for publishing and general commands.

**Connection requirements**: Use dedicated connections for subscribers. Do not share a subscriber connection with non-subscription work. Most client libraries manage this automatically.

**Pattern cost**: PSUBSCRIBE patterns are checked against every PUBLISH. With many patterns, this adds overhead. Prefer exact channel names when performance matters.

---

## Practical Patterns

**Real-time notifications**:
```
-- Subscriber (dedicated connection per user)
SUBSCRIBE notifications:user:1000

-- Publisher (from any connection)
PUBLISH notifications:user:1000 '{"type":"message","from":"user:2000","text":"Hello"}'
```

**Broadcast with pattern matching**:
```
-- Subscribe to all system alerts
PSUBSCRIBE alerts:*

-- Different publishers for different alert types
PUBLISH alerts:cpu "Server CPU at 95%"
PUBLISH alerts:memory "Server memory at 90%"
PUBLISH alerts:disk "Disk usage at 85%"
```

**Cluster-efficient per-entity events**:
```
-- Each order gets shard-local updates (no cluster-wide broadcast)
SSUBSCRIBE orders:5678
SPUBLISH orders:5678 '{"status":"shipped","carrier":"fedex"}'
```

**Cache invalidation**:
```
-- App servers subscribe to invalidation channel
SUBSCRIBE cache:invalidate

-- When data changes, publish the affected key
PUBLISH cache:invalidate "user:1000:profile"
-- All app servers clear their local cache for that key
```

**Chat room**:
```
-- Join room
SUBSCRIBE chat:room:42

-- Send message (from a separate connection)
PUBLISH chat:room:42 '{"user":"alice","text":"Hello everyone!"}'

-- Monitor all rooms
PSUBSCRIBE chat:room:*
```

---

## See Also

- [Pub/Sub Patterns](../patterns/pubsub-patterns.md) - fan-out messaging, sharded pub/sub, keyspace notifications
- [Stream Commands](streams.md) - durable messaging alternative to pub/sub with consumer groups
- [Caching Patterns](../patterns/caching.md) - cache invalidation via pub/sub channels
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - field expiration events published via keyspace notifications
- [Cluster Enhancements](../valkey-features/cluster-enhancements.md) - sharded pub/sub in cluster mode
- [Performance Best Practices](../best-practices/performance.md) - dedicated connections for subscribers
- [Cluster Best Practices](../best-practices/cluster.md) - sharded pub/sub for cluster-efficient messaging
- [Anti-Patterns](../anti-patterns/quick-reference.md) - pub/sub for durable messaging is an anti-pattern
