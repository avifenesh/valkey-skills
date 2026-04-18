# go-redis to GLIDE Advanced Patterns

Use when migrating go-redis transactions, pipelines, Pub/Sub, or checking Go API maturity status.

## Transactions and Pipelines

**go-redis:**
```go
// Transaction
_, err := rdb.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
    pipe.Set(ctx, "k1", "v1", 0)
    pipe.Get(ctx, "k1")
    return nil
})

// Pipeline
_, err := rdb.Pipelined(ctx, func(pipe redis.Pipeliner) error {
    pipe.Set(ctx, "k1", "v1", 0)
    pipe.Set(ctx, "k2", "v2", 0)
    return nil
})
```

**GLIDE:**
```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

// Transaction (atomic)
tx := pipeline.NewStandaloneBatch(true)
tx.Set("k1", "v1")
tx.Get("k1")
results, err := client.Exec(ctx, *tx, true)

// Pipeline (non-atomic)
pipe := pipeline.NewStandaloneBatch(false)
pipe.Set("k1", "v1")
pipe.Set("k2", "v2")
results, err := client.Exec(ctx, *pipe, false)
```

---

## Pub/Sub

**go-redis:**
```go
pubsub := rdb.Subscribe(ctx, "channel")
pubsub.PSubscribe(ctx, "events:*")
ch := pubsub.Channel()
for msg := range ch {
    fmt.Printf("[%s] %s\n", msg.Channel, msg.Payload)
}
```

**GLIDE (static subscriptions - at client creation):**
```go
import (
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
    "github.com/valkey-io/valkey-glide/go/v2/models"
)

subCfg := config.NewStandaloneSubscriptionConfig().
    WithSubscription(config.ExactChannelMode, "channel").
    WithSubscription(config.PatternChannelMode, "events:*").
    WithCallback(func(msg *models.PubSubMessage, ctx any) {
        fmt.Printf("[%s] %s\n", msg.Channel, msg.Message)
    }, nil)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithSubscriptionConfig(subCfg)

subscriber, err := glide.NewClient(cfg)
```

**GLIDE (dynamic subscriptions - GLIDE 2.3+):**

Go uses a single method name with a `timeoutMs` parameter for blocking, and `*Lazy` variants for non-blocking. There is no separate `SubscribeBlocking` for exact channels; the blocking variant is just `Subscribe(ctx, channels, timeoutMs)`:

```go
// Blocking - waits for server confirmation; timeoutMs=0 blocks indefinitely
err := client.Subscribe(ctx, []string{"channel"}, 5000)
err = client.PSubscribe(ctx, []string{"events:*"}, 5000)
err = clusterClient.SSubscribe(ctx, []string{"shard-topic"}, 5000)  // cluster only

// Non-blocking - returns immediately; reconciliation happens async
err = client.SubscribeLazy(ctx, []string{"channel"})
err = client.PSubscribeLazy(ctx, []string{"events:*"})
err = clusterClient.SSubscribeLazy(ctx, []string{"shard-topic"})

// Unsubscribe variants mirror the same pattern
err = client.Unsubscribe(ctx, []string{"channel"}, 5000)          // nil = unsubscribe all
err = client.UnsubscribeLazy(ctx, []string{"channel"})
err = client.PUnsubscribe(ctx, []string{"events:*"}, 5000)
err = client.PUnsubscribeLazy(ctx, nil)                            // all patterns

// Receive via queue (when no callback configured)
queue, err := client.GetQueue()
msg := queue.Pop()                    // non-blocking, returns nil if empty
msgCh := queue.WaitForMessage()       // blocking - returns receive-only channel
msg = <-msgCh
```

go-redis uses a Go channel-based approach (`pubsub.Channel()`). GLIDE uses callbacks (set at creation time via `WithCallback`) OR queue-based polling (`GetQueue` + `Pop` / `WaitForMessage`). They are mutually exclusive on one client.

GLIDE multiplexes subscriptions alongside commands - a dedicated subscriber client is recommended for high-volume subscriptions but not strictly required. Auto-resubscribe on reconnect + topology change is handled by the synchronizer.

---

## Go API Maturity Timeline

| Version | Feature |
|---------|---------|
| 2.0 | GA release (June 2025), PubSub support |
| 2.2 | `go mod vendor` support |
| 2.3 | Dynamic PubSub, ACL commands, cluster management commands |

The team minimized interface usage in favor of concrete types after community feedback that returning interfaces was non-idiomatic Go.
