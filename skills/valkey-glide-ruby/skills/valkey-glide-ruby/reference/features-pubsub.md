# Pub/Sub (Ruby)

Use when wiring publish/subscribe in valkey-rb. Assumes redis-rb familiarity - only divergence is documented.

## Divergence from redis-rb

| | redis-rb | valkey-rb |
|---|---|---|
| `subscribe("ch") { \|on\| on.message { } }` block form | yes | **no - block is ignored** |
| Channel args | varargs | varargs (same) |
| Message delivery | block via connection loop | **`pubsub_callback` module method on the FFI side** |
| Sharded `ssubscribe` / `spublish` | not implemented | **implemented** |
| Introspection via `pubsub(:channels)` | yes | yes, plus `pubsub_channels` / `pubsub_numsub` / `pubsub_numpat` / `pubsub_shardchannels` / `pubsub_shardnumsub` direct methods |

## Canonical shape - override pubsub_callback, then subscribe

```ruby
require "valkey"

# Override the callback BEFORE creating the client
class Valkey
  module PubSubCallback
    def pubsub_callback(_client_ptr, kind, msg_ptr, msg_len, chan_ptr, chan_len, pat_ptr, pat_len)
      message = msg_ptr.read_string(msg_len)
      channel = chan_ptr.read_string(chan_len)
      pattern = pat_ptr.read_string(pat_len) if pat_len.positive?

      # your handling here
      puts "[#{channel}] (#{kind}) #{message}"
    end
  end
end

subscriber = Valkey.new
subscriber.subscribe("news", "events")       # varargs
```

The callback fires on the FFI thread. Keep it non-blocking. Heavy work should enqueue onto your own queue for a worker thread to drain.

## Publish

```ruby
publisher = Valkey.new
count = publisher.publish("events", "Hello subscribers!")   # channel, message
```

Standard `(channel, message)` order - not reversed.

## Pattern subscriptions

```ruby
subscriber = Valkey.new
subscriber.psubscribe("news.*", "events:*")   # varargs

subscriber.punsubscribe                        # no args = all patterns
subscriber.punsubscribe("news.*")              # specific pattern
```

The `pubsub_callback` you overrode receives pattern subscriptions with a non-zero `pat_len`; check it to tell pattern vs exact delivery.

## Sharded PubSub (cluster)

Unlike redis-rb, valkey-rb implements sharded PubSub:

```ruby
cluster = Valkey.new(
  nodes: [{ host: "node1.example.com", port: 6379 }],
  cluster_mode: true
)

cluster.ssubscribe("shard-news", "shard-updates")
cluster.spublish("shard-news", "hi")    # standard order
cluster.sunsubscribe                    # all sharded channels
cluster.sunsubscribe("shard-news")      # specific
```

Requires Valkey 7.0+ server.

## Introspection

Direct methods (no subscriber mode required):

```ruby
valkey.pubsub_channels                   # all active
valkey.pubsub_channels("news.*")         # filtered
valkey.pubsub_numsub("ch1", "ch2")       # => ["ch1", 5, "ch2", 3]
valkey.pubsub_numpat                     # pattern count
valkey.pubsub_shardchannels              # sharded active
valkey.pubsub_shardnumsub("s1", "s2")
```

Convenience dispatcher:

```ruby
valkey.pubsub(:channels)                 # -> pubsub_channels
valkey.pubsub(:numsub, "ch1", "ch2")     # -> pubsub_numsub
valkey.pubsub(:numpat)                   # -> pubsub_numpat
```

## Unsubscribe shapes

```ruby
valkey.unsubscribe                       # all exact channels
valkey.unsubscribe("news", "events")     # specific (varargs)
valkey.punsubscribe                      # all patterns
valkey.punsubscribe("news.*")            # specific pattern
valkey.sunsubscribe                      # all sharded
valkey.sunsubscribe("shard-news")
```

## Important notes

1. **Separate clients for pub and sub.** A subscribing client is in subscriber mode and cannot issue non-pubsub commands from the outer thread.
2. **Automatic resubscribe on reconnect.** Rust core restores subscriptions.
3. **At-most-once delivery.** Messages during a reconnect gap are lost. Use Streams for durability.
4. **`pubsub_callback` runs on an FFI-managed thread.** Treat it like a signal handler - minimal, non-blocking.
5. **Raw pointer parameters.** `msg_ptr`, `chan_ptr`, `pat_ptr` are `FFI::Pointer`. Call `read_string(len)` to materialize.
