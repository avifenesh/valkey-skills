# Pub/Sub (Ruby)

Use when implementing real-time message broadcasting in Ruby - chat, notifications, event distribution, or inter-process messaging. For durable message processing with consumer groups, use Streams instead.

GLIDE Ruby supports all three PubSub subscription modes (exact, pattern, sharded) plus introspection commands. The API follows redis-rb conventions.

## Subscription Modes

| Mode | Subscribe | Unsubscribe | Publish | Cluster Only |
|------|-----------|-------------|---------|--------------|
| Exact | `subscribe` | `unsubscribe` | `publish` | No |
| Pattern | `psubscribe` | `punsubscribe` | `publish` | No |
| Sharded | `ssubscribe` | `sunsubscribe` | `spublish` | Yes (Valkey 7.0+) |

## Subscribe and Publish

```ruby
require "valkey"

# Subscriber - dedicated client
subscriber = Valkey.new(host: "localhost", port: 6379)
subscriber.subscribe("news", "events")

# Publisher - separate client
publisher = Valkey.new(host: "localhost", port: 6379)
count = publisher.publish("events", "Hello subscribers!")
puts "Delivered to #{count} subscribers"
```

## Pattern Subscriptions

```ruby
subscriber = Valkey.new
subscriber.psubscribe("news.*", "events:*")

# Unsubscribe from specific patterns
subscriber.punsubscribe("news.*")

# Unsubscribe from all patterns
subscriber.punsubscribe
```

## Sharded PubSub (Cluster Mode)

Sharded channels are routed by hash slot. Requires Valkey 7.0+ and cluster mode.

```ruby
client = Valkey.new(
  nodes: [{ host: "node1.example.com", port: 6379 }],
  cluster_mode: true
)

# Subscribe to sharded channels
client.ssubscribe("shard-news", "shard-updates")

# Publish to sharded channel
client.spublish("shard-news", "Breaking news!")

# Unsubscribe
client.sunsubscribe("shard-news")
client.sunsubscribe  # all sharded channels
```

## PubSub Introspection

Query active channels and subscriber counts without entering subscriber mode:

```ruby
client = Valkey.new

# List active channels
channels = client.pubsub_channels
# => ["news", "events"]

# Filter by pattern
channels = client.pubsub_channels("news.*")
# => ["news.sports", "news.tech"]

# Subscriber counts for specific channels
counts = client.pubsub_numsub("news", "events")
# => ["news", 5, "events", 3]

# Number of active pattern subscriptions
pat_count = client.pubsub_numpat
# => 2

# Sharded channel introspection (cluster only)
sharded = client.pubsub_shardchannels
shard_counts = client.pubsub_shardnumsub("shard1", "shard2")
```

### Convenience Method

```ruby
# All introspection via pubsub() helper
client.pubsub(:channels)
client.pubsub(:channels, "news.*")
client.pubsub(:numsub, "ch1", "ch2")
client.pubsub(:numpat)
client.pubsub(:shardchannels)
client.pubsub(:shardnumsub, "shard1")
```

## PubSub Callback

Messages arrive via a callback at the FFI layer. The callback receives:

| Field | Type | Description |
|-------|------|-------------|
| `kind` | Integer | Message kind (exact, pattern, sharded) |
| `message` | String | The published payload |
| `channel` | String | Channel the message was published to |
| `pattern` | String | Matching pattern (pattern subscriptions only) |

## redis-rb Migration

The PubSub API follows redis-rb conventions:

```ruby
# redis-rb
redis = Redis.new
redis.subscribe("channel") do |on|
  on.message { |ch, msg| puts "#{ch}: #{msg}" }
end

# valkey-rb
valkey = Valkey.new
valkey.subscribe("channel")
# Messages delivered via callback mechanism
```

The subscribe/unsubscribe method signatures are identical. Message delivery mechanism differs - valkey-rb uses FFI callbacks through the Rust core rather than redis-rb's Ruby-level event loop.

## Important Notes

1. **Separate clients for pub and sub.** A subscribing client enters a special mode where regular commands are unavailable.
2. **Synchronous API.** Subscribe calls block the current thread in subscriber mode.
3. **Automatic reconnection.** On disconnect, GLIDE resubscribes to all channels automatically via the Rust core.
4. **Message loss during reconnect.** PubSub is at-most-once delivery. Use Streams for durability.
5. **Full sharded PubSub.** Unlike redis-rb, valkey-rb supports sharded subscribe/publish out of the box.
