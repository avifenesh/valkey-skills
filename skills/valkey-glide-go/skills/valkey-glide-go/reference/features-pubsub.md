# Pub/Sub (Go)

Use when working with publish/subscribe. Covers what differs from `go-redis`'s `rdb.Subscribe(ctx, channels...)` + `pubsub.ReceiveMessage(ctx)` pattern - the subscription model diverges significantly.

## Divergence from go-redis

| go-redis | GLIDE Go |
|----------|---------|
| `pubsub := rdb.Subscribe(ctx, "ch1", "ch2")` runtime | Either static config (`WithSubscriptionConfig`) OR dynamic `client.Subscribe(ctx, ...)` (GLIDE 2.3+) |
| `msg, err := pubsub.ReceiveMessage(ctx)` loop | Callback on the subscription config OR `client.GetPubSubMessage(ctx)` / `client.TryGetPubSubMessage()` - cannot mix |
| `rdb.Publish(ctx, channel, message)` | `client.Publish(ctx, channel, message)` - **SAME ORDER** (Go matches the Redis convention; Python/Node reverse it, Go does NOT) |
| Manual reconnect + resubscribe in your loop | Automatic via synchronizer; `client.GetSubscriptions(ctx)` exposes desired vs actual state |
| `ClusterClient.Subscribe` does sharded differently | Sharded subscriptions: `ShardedClusterChannelMode` in config, `SSubscribe` / `SSubscribeLazy` for runtime (`ClusterClient` only); sharded publishing: `Publish(ctx, channel, message, sharded bool)` 4th-arg flag |

Static subscriptions require RESP3 (default). Using RESP2 causes client creation to fail with `ConfigurationError`.

## Subscription Modes

| Mode | Subscribe/Unsubscribe | Description |
|------|----------------------|-------------|
| Exact | `Subscribe` / `Unsubscribe` | Specific channel names |
| Pattern | `PSubscribe` / `PUnsubscribe` | Glob patterns (e.g., `news.*`) |
| Sharded | `SSubscribe` / `SUnsubscribe` | Slot-scoped, cluster-only (Valkey 7.0+) |

Sharded subscriptions are `ClusterClient`-only. They route by hash slot so the subscription is managed by the node owning the channel's slot.

## Configuration-Time Subscriptions (Immutable)

Set subscriptions at client creation. These are active for the client's lifetime and restored on reconnect.

### Standalone

```go
import (
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

subCfg := config.NewStandaloneSubscriptionConfig().
    WithSubscription(config.ExactChannelMode, "news").
    WithSubscription(config.ExactChannelMode, "events").
    WithSubscription(config.PatternChannelMode, "user:*").
    WithCallback(func(msg *models.PubSubMessage, ctx any) {
        fmt.Printf("Channel: %s, Message: %s\n", msg.Channel, msg.Message)
    }, nil)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithSubscriptionConfig(subCfg)

subscriber, err := glide.NewClient(cfg)
```

### Cluster

```go
subCfg := config.NewClusterSubscriptionConfig().
    WithSubscription(config.ExactClusterChannelMode, "news").
    WithSubscription(config.PatternClusterChannelMode, "user:*").
    WithSubscription(config.ShardedClusterChannelMode, "orders")

cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithSubscriptionConfig(subCfg)

subscriber, err := glide.NewClusterClient(cfg)
```

Channel mode constants:

| Standalone | Cluster |
|-----------|---------|
| `config.ExactChannelMode` | `config.ExactClusterChannelMode` |
| `config.PatternChannelMode` | `config.PatternClusterChannelMode` |
| - | `config.ShardedClusterChannelMode` |

## Dynamic Subscriptions (GLIDE 2.3+)

Runtime subscribe/unsubscribe after client creation. Two variants per method:

| Method | Behavior |
|--------|----------|
| `Subscribe(ctx, channels)` | Non-blocking (lazy), returns immediately |
| `SubscribeBlocking(ctx, channels, timeoutMs)` | Waits for server confirmation |

### Subscribe (Non-Blocking)

```go
err := client.Subscribe(ctx, []string{"channel1", "channel2"})
err = client.PSubscribe(ctx, []string{"news.*", "updates.*"})

// Cluster-only: sharded channels
err = clusterClient.SSubscribe(ctx, []string{"orders"})
```

### Subscribe (Blocking)

```go
// Wait up to 5 seconds for confirmation
err := client.SubscribeBlocking(ctx, []string{"channel1"}, 5000)
err = client.PSubscribeBlocking(ctx, []string{"news.*"}, 5000)
```

### Unsubscribe

```go
err := client.Unsubscribe(ctx, []string{"channel1"})
err = client.PUnsubscribe(ctx, []string{"news.*"})

// Unsubscribe from ALL exact channels
err = client.UnsubscribeAll(ctx)
err = client.PUnsubscribeAll(ctx)

// Cluster-only: sharded unsubscribe
err = clusterClient.SUnsubscribe(ctx, []string{"orders"})
err = clusterClient.SUnsubscribeAll(ctx)
```

Blocking variants: `UnsubscribeBlocking`, `PUnsubscribeBlocking`, `SUnsubscribeBlocking`, `SUnsubscribeAllBlocking`.

## Receiving Messages

Two approaches: callback or queue.

### Callback

Set during subscription configuration. Called for every message. Must be thread-safe.

```go
callback := func(msg *models.PubSubMessage, ctx any) {
    fmt.Printf("[%s] %s\n", msg.Channel, msg.Message)
    if !msg.Pattern.IsNil() {
        fmt.Printf("  matched pattern: %s\n", msg.Pattern.Value())
    }
}

subCfg := config.NewStandaloneSubscriptionConfig().
    WithSubscription(config.ExactChannelMode, "news").
    WithCallback(callback, nil)
```

### Queue (Polling)

When no callback is set, messages go to an internal queue.

```go
queue, err := client.GetQueue()
if err != nil {
    // No subscriptions configured
}

// Non-blocking poll
msg := queue.Pop()
if msg != nil {
    fmt.Printf("Got: %s on %s\n", msg.Message, msg.Channel)
}

// Blocking wait (returns a channel)
msgCh := queue.WaitForMessage()
msg = <-msgCh

// Signal channel for select-based consumption
signalCh := make(chan struct{}, 1)
queue.RegisterSignalChannel(signalCh)
defer queue.UnregisterSignalChannel(signalCh)

select {
case <-signalCh:
    msg := queue.Pop()
    // process msg
case <-ctx.Done():
    return
}
```

Drain the queue regularly - the internal buffer is unbounded and grows if not consumed.

## PubSubMessage Type

```go
type PubSubMessage struct {
    Message string
    Channel string
    Pattern Result[string]  // non-nil for pattern-matched messages
}
```

## Publishing

```go
// Standalone: returns number of receivers
count, err := client.Publish(ctx, "news", "breaking update")

// Cluster: set sharded=true for SPUBLISH, false for PUBLISH
count, err := clusterClient.Publish(ctx, "news", "update", false)
count, err = clusterClient.Publish(ctx, "orders", "new-order", true) // sharded
```

## Dedicated subscriber client

Dedicated subscriber client is RECOMMENDED for high-volume subscriptions to avoid head-of-line effects with regular command traffic, but NOT required - GLIDE multiplexes pubsub alongside commands on the core side. The "enters special mode" framing from go-redis / traditional Redis clients does not strictly apply.

## Introspection

Query active PubSub state without subscribing:

```go
// List active channels (exact subscriptions across all clients)
channels, err := client.PubSubChannels(ctx)

// Filter by glob pattern
channels, err = client.PubSubChannelsWithPattern(ctx, "news.*")

// Count pattern subscriptions (PUBSUB NUMPAT)
patCount, err := client.PubSubNumPat(ctx)

// Subscriber count per channel (PUBSUB NUMSUB)
subs, err := client.PubSubNumSub(ctx, "channel1", "channel2")
// subs: map[string]int64{"channel1": 3, "channel2": 1}

// Cluster-only: sharded channel introspection
shardChannels, err := clusterClient.PubSubShardChannels(ctx)
shardChannels, err = clusterClient.PubSubShardChannelsWithPattern(ctx, "orders.*")
shardSubs, err := clusterClient.PubSubShardNumSub(ctx, "orders")
```

## Subscription State

Query the client's own subscription state:

```go
state, err := client.GetSubscriptions(ctx)
// state.DesiredSubscriptions - what the client wants to be subscribed to
// state.ActualSubscriptions - what the server confirms
if _, ok := state.ActualSubscriptions[models.Exact]["channel1"]; ok {
    fmt.Println("Subscribed to channel1")
}
```

## Reconciliation and Reconnection

The PubSub synchronizer reconciles desired vs actual subscriptions at a configurable interval (default: 3 seconds). Configure via `config.NewAdvancedClientConfiguration().WithPubSubReconciliationIntervalMs(5000)`.

When a connection drops, GLIDE reconnects, clears actual subscriptions for the disconnected node, and the reconciler resubscribes to all desired channels. For sharded subscriptions, slot migration is handled automatically.

Monitor sync health: `client.GetStatistics()["subscription_out_of_sync_count"]`. During reconnection, messages can be lost (RESP at-most-once delivery). Use Valkey Streams for stronger guarantees.
