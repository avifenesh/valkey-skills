# Pub/Sub (C#)

Use when implementing real-time message broadcasting in C# - chat, notifications, event distribution, or live data feeds. For durable message processing with consumer groups, use Streams instead.

GLIDE C# supports all three PubSub subscription modes with full async/await, dynamic subscribe/unsubscribe, callback-based message delivery, and automatic reconnection with resubscription.

## Contents

- Subscription Modes (line 18)
- Static Subscriptions (at Client Creation) (line 26)
- Dynamic Subscriptions (Runtime) (line 61)
- Sharded PubSub (Cluster Only) (line 92)
- Publishing (line 106)
- Subscription Introspection (line 118)
- Reconciliation Interval (line 137)
- Important Notes (line 141)

## Subscription Modes

| Mode | Methods | Description | Cluster Only |
|------|---------|-------------|--------------|
| Exact | `SubscribeAsync` / `UnsubscribeAsync` | Specific channel names | No |
| Pattern | `PSubscribeAsync` / `PUnsubscribeAsync` | Glob patterns (e.g., `news.*`) | No |
| Sharded | `SSubscribeAsync` / `SUnsubscribeAsync` | Slot-scoped channels | Yes (Valkey 7.0+) |

## Static Subscriptions (at Client Creation)

Configure PubSub subscriptions in the builder with a callback:

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .WithPubSubSubscriptionConfig(new StandalonePubSubSubscriptionConfig()
        .WithChannel("alerts")
        .WithPattern("log:*")
        .WithCallback((msg, ctx) => {
            Console.WriteLine($"[{msg.Channel}] {msg.Message}");
        }))
    .Build();

await using var subscriber = await GlideClient.CreateClient(config);
```

For cluster mode, use `ClusterPubSubSubscriptionConfig`:

```csharp
var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithPubSubSubscriptions(new ClusterPubSubSubscriptionConfig()
        .WithChannel("events")
        .WithShardedChannel("shard-topic")
        .WithCallback((msg, ctx) => {
            Console.WriteLine($"[{msg.Channel}] {msg.Message}");
        }))
    .Build();
```

## Dynamic Subscriptions (Runtime)

Subscribe and unsubscribe after client creation. Two modes:

- **Blocking** - waits for server confirmation (with optional timeout)
- **Lazy** - returns immediately, reconciliation happens in background

```csharp
// Blocking subscribe - waits for confirmation
await client.SubscribeAsync("news", TimeSpan.FromSeconds(5));
await client.SubscribeAsync(new[] { "events", "alerts" }, TimeSpan.FromSeconds(5));
await client.PSubscribeAsync("user:*", TimeSpan.FromSeconds(5));

// Lazy subscribe - returns immediately
await client.SubscribeLazyAsync("updates");
await client.PSubscribeLazyAsync("logs:*");

// Blocking unsubscribe
await client.UnsubscribeAsync("news", TimeSpan.FromSeconds(5));
await client.PUnsubscribeAsync("user:*", TimeSpan.FromSeconds(5));

// Unsubscribe from all
await client.UnsubscribeAsync(TimeSpan.FromSeconds(5));

// Lazy unsubscribe
await client.UnsubscribeLazyAsync("updates");
await client.UnsubscribeLazyAsync(); // all channels
```

Pass `TimeSpan.Zero` for indefinite timeout on blocking methods.

## Sharded PubSub (Cluster Only)

```csharp
// Subscribe to sharded channels
await clusterClient.SSubscribeAsync("shard-news", TimeSpan.FromSeconds(5));
await clusterClient.SSubscribeLazyAsync("shard-updates");

// Publish to sharded channel
await clusterClient.SPublishAsync("shard-news", "Breaking news!");

// Unsubscribe
await clusterClient.SUnsubscribeAsync("shard-news", TimeSpan.FromSeconds(5));
```

## Publishing

```csharp
// Regular publish (standalone or cluster)
long receivers = await client.PublishAsync("events", "Hello subscribers!");

// Sharded publish (cluster only)
long receivers = await clusterClient.SPublishAsync("shard-topic", "Hello shard!");
```

Always use a separate client for publishing - a subscribing client enters a special mode.

## Subscription Introspection

```csharp
// List active channels
ISet<string> channels = await client.PubSubChannelsAsync();
ISet<string> newsChannels = await client.PubSubChannelsAsync("news.*");

// Subscriber counts
var counts = await client.PubSubNumSubAsync(new[] { "news", "events" });
long patternCount = await client.PubSubNumPatAsync();

// Desired vs actual state
PubSubState state = await client.GetSubscriptionsAsync();
var desiredChannels = state.Desired[PubSubChannelMode.Exact];
var actualPatterns = state.Actual[PubSubChannelMode.Pattern];
```

Cluster clients also have `PubSubShardChannelsAsync()` and `PubSubShardNumSubAsync()`.

## Reconciliation Interval

`builder.WithPubSubReconciliationInterval(TimeSpan.FromSeconds(1))` - how often the synchronizer reconciles desired vs actual subscriptions. Default is 3 seconds.

## Important Notes

1. **Separate clients for pub and sub.** A subscribing client cannot execute regular commands.
2. **RESP3 required.** PubSub push notifications need RESP3 (the default protocol).
3. **Automatic reconnection.** On disconnect, GLIDE resubscribes to all desired channels automatically.
4. **Message loss during reconnect.** PubSub is at-most-once delivery. Use Streams for durability.
5. **Drain messages promptly.** The internal buffer is unbounded when using polling/callback modes.
