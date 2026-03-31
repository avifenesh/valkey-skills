# Pub/Sub Patterns

Use when implementing real-time messaging, event broadcasting, or notification systems. Covers standard pub/sub, sharded pub/sub in cluster, and keyspace notifications for event-driven architectures.

## Contents

- Fan-Out Messaging (line 17)
- Sharded Pub/Sub (Cluster Mode) (line 82)
- Keyspace Notifications (line 123)
- Pub/Sub vs Streams Comparison (line 214)
- Channel Naming Patterns (line 243)
- Production Tips (line 277)
- See Also (line 288)

---

## Fan-Out Messaging

The classic pub/sub pattern: one publisher sends a message, and all subscribers on that channel receive it immediately.

### Basic Pattern

```
# Subscriber (Connection 1)
SUBSCRIBE notifications:user:1000

# Publisher (Connection 2)
PUBLISH notifications:user:1000 '{"type":"message","from":"user:2000","text":"Hello"}'

# Pattern subscription - matches any user
PSUBSCRIBE notifications:user:*
```

**Critical**: Pub/sub is fire-and-forget (at-most-once delivery). Messages are lost if no subscriber is listening when the message is published. For durable messaging, use Streams instead.

### Code Examples

**Node.js (ioredis)**:
```javascript
// Subscriber (dedicated connection - cannot use for other commands)
const sub = new Redis();
sub.subscribe('notifications:user:1000');
sub.on('message', (channel, message) => {
  const event = JSON.parse(message);
  handleNotification(event);
});

// Publisher (regular connection)
const pub = new Redis();
await pub.publish(
  'notifications:user:1000',
  JSON.stringify({ type: 'message', from: 'user:2000' })
);
```

**Python**:
```python
# Subscriber
pubsub = redis.pubsub()
await pubsub.subscribe("notifications:user:1000")

async for message in pubsub.listen():
    if message["type"] == "message":
        event = json.loads(message["data"])
        await handle_notification(event)

# Publisher
await redis.publish(
    "notifications:user:1000",
    json.dumps({"type": "message", "from": "user:2000"})
)
```

### Important Rules

- **Subscriber connections are monopolized** - they can only receive messages, not run regular commands. Use a separate connection for subscribing.
- **No message buffering** - if a subscriber disconnects and reconnects, it misses all messages published during the gap.
- **Pattern subscriptions are expensive** - each published message is matched against all patterns (O(N) where N = total pattern subscriptions across all clients). Prefer exact `SUBSCRIBE` when possible.

---

## Sharded Pub/Sub (Cluster Mode)

Standard `PUBLISH` broadcasts messages to ALL cluster nodes, regardless of which node owns the channel. This wastes network bandwidth in large clusters.

Sharded pub/sub (`SPUBLISH`/`SSUBSCRIBE`) routes messages through hash slots, so they only reach the node that owns the channel's slot.

```
# Sharded subscriber
SSUBSCRIBE orders:region:us-east

# Sharded publisher
SPUBLISH orders:region:us-east '{"order_id":5678,"status":"shipped"}'
```

### When to Use Sharded Pub/Sub

| Scenario | Use Standard | Use Sharded |
|----------|-------------|-------------|
| Few channels, few nodes | Yes | Optional |
| Many channels, large cluster | No | Yes |
| Channel-per-entity (user, order) | No | Yes - naturally maps to slots |
| Global broadcast (system alerts) | Yes | No |
| High message throughput | Check bandwidth | Yes - reduces cross-node traffic |

### Hash Tag Patterns for Co-Location

```
# These land on the same shard
SSUBSCRIBE {user:1000}:notifications
SSUBSCRIBE {user:1000}:activity
```

### Cluster Configuration

```
# Allow sharded pub/sub when cluster is not fully covered
cluster-allow-pubsubshard-when-down yes    # Default
```

---

## Keyspace Notifications

Valkey can publish events when keys are created, modified, deleted, expired, or evicted. This enables event-driven architectures without explicit publishing.

### Enable Notifications

Notifications are disabled by default (they add CPU overhead per matching operation):

```
# Enable expired key events
CONFIG SET notify-keyspace-events Ex

# Enable all events (expensive - use sparingly)
CONFIG SET notify-keyspace-events KEA
```

### Event Flag Reference

| Flag | Events |
|------|--------|
| `K` | Keyspace notifications (`__keyspace@<db>__:<key>`) |
| `E` | Keyevent notifications (`__keyevent@<db>__:<event>`) |
| `g` | Generic: DEL, EXPIRE, RENAME |
| `$` | String commands |
| `l` | List commands |
| `s` | Set commands |
| `h` | Hash commands |
| `z` | Sorted set commands |
| `x` | Expired events |
| `e` | Evicted events |
| `t` | Stream commands |
| `m` | Key miss events (must enable explicitly) |
| `n` | New key creation (must enable explicitly) |
| `A` | Alias for `g$lshzxetd` (all except `m` and `n`) |

At least one of `K` or `E` must be present alongside event type flags.

### Common Use Cases

**Cache invalidation on expiration**:
```
CONFIG SET notify-keyspace-events Ex

# Subscribe to expiration events in database 0
SUBSCRIBE __keyevent@0__:expired
# Receives key name when any key expires
```

**React to specific key changes**:
```
CONFIG SET notify-keyspace-events Kg$

# Subscribe to all events on keys matching a pattern
PSUBSCRIBE __keyspace@0__:order:*
# Receives: channel = "__keyspace@0__:order:5678", message = "set"
```

**Trigger on new key creation** (Valkey-specific `n` flag):
```
CONFIG SET notify-keyspace-events KEn

SUBSCRIBE __keyevent@0__:new
# Receives key name whenever a new key is created
```

### Code Example

**Node.js**:
```javascript
// Enable expired notifications
await redis.config('SET', 'notify-keyspace-events', 'Ex');

// Subscribe to expired events
const sub = new Redis();
sub.subscribe('__keyevent@0__:expired');
sub.on('message', (channel, expiredKey) => {
  console.log(`Key expired: ${expiredKey}`);
  // Trigger cleanup, refresh, or notification
});
```

### Limitations

- Notifications are delivered via pub/sub - fire-and-forget semantics apply
- If no subscriber is listening, the event is lost
- In cluster mode, notifications are local to each node (subscribe on every node)
- Enabling many event types on high-throughput instances has measurable CPU cost
- Enable only the specific flags you need

---

## Pub/Sub vs Streams Comparison

| Feature | Pub/Sub | Streams |
|---------|---------|---------|
| Delivery | At-most-once | At-least-once (with ACK) |
| Persistence | No - messages are ephemeral | Yes - messages stored on disk |
| Consumer groups | No | Yes |
| Message history | No - missed is lost | Yes - replay from any point |
| Backpressure | None - slow consumers miss messages | Consumer controls read rate |
| Latency | Lowest (direct push) | Very low (poll with BLOCK) |
| Fan-out | Built-in (all subscribers get every message) | Multiple consumer groups on same stream |
| Memory | None (messages not stored) | Grows until trimmed |

### When to Choose Each

**Use Pub/Sub when**:
- Real-time notifications where message loss is acceptable
- Chat presence indicators, typing indicators
- Live dashboard updates
- Broadcasting config changes across services

**Use Streams when**:
- Every message must be processed (job queues, event sourcing)
- Multiple consumer groups need independent processing
- Message history or replay is needed
- Backpressure handling is required

---

## Channel Naming Patterns

### Entity-Based Channels

```
notifications:user:1000
events:order:5678
updates:product:999
```

### Hierarchical Channels with Pattern Subscribe

```
# Publish to specific channel
PUBLISH events:order:created '{"order_id":5678}'
PUBLISH events:order:shipped '{"order_id":5678}'

# Subscribe to all order events
PSUBSCRIBE events:order:*

# Subscribe to all events
PSUBSCRIBE events:*
```

### Cluster-Friendly Sharded Channels

```
# Use hash tags for related channels on the same shard
SSUBSCRIBE {user:1000}:notifications
SSUBSCRIBE {user:1000}:presence
```

---

## Production Tips

- **Dedicate connections for subscribers** - subscribed connections cannot run regular commands
- **Use separate connection pools** for pub/sub and regular commands
- **Monitor subscriber memory** - slow subscribers accumulate buffered messages. The default hard limit is 32 MB per subscriber before disconnection.
- **Prefer `SUBSCRIBE` over `PSUBSCRIBE`** when channel names are known - pattern matching has O(N) cost per published message
- **Set client output buffer limits** appropriately for your subscriber throughput
- **Handle reconnection** in your subscriber code - re-subscribe to all channels after a disconnect

---

## See Also

- [Pub/Sub Commands](../basics/data-types.md) - SUBSCRIBE, PUBLISH, SSUBSCRIBE, SPUBLISH reference
- [Stream Commands](../basics/data-types.md) - durable messaging alternative to pub/sub
- [Queue Patterns](queues.md) - stream-based queues for reliable message processing
- [Session Patterns](sessions.md) - keyspace notifications for session expiration handling
- [Caching Patterns](caching.md) - client-side caching with server-assisted invalidation
- [Counter Patterns](counters.md) - keyspace notifications on counter changes
- [Key Best Practices](../best-practices/keys.md) - channel naming conventions
- [Cluster Best Practices](../best-practices/cluster.md) - sharded pub/sub routing and hash slot considerations
- [Performance Best Practices](../best-practices/performance.md) - subscriber memory and buffer limits
- [High Availability Best Practices](../best-practices/high-availability.md) - reconnection and resubscription during failover
- [Memory Best Practices](../best-practices/memory.md) - subscriber output buffer memory impact
- [Security: Auth and ACL](../security/auth-and-acl.md) - channel-level ACL restrictions for pub/sub
- Clients Overview (see valkey-glide skill) - dedicated subscriber connections and PubSub state restoration
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - pub/sub for durable messaging, blocking commands on shared connections
- valkey-ops [configuration/pubsub](../../../valkey-ops/reference/configuration/pubsub.md) - buffer limits, sharded pub/sub config, pattern performance
- valkey-ops [performance/client-caching](../../../valkey-ops/reference/performance/client-caching.md) - CLIENT TRACKING configuration
