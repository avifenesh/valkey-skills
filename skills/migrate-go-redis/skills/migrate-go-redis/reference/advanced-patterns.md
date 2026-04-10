# go-redis to GLIDE Advanced Patterns

Use when migrating go-redis transactions, pipelines, Pub/Sub, or checking Go API maturity status.

## Contents

- Transactions and Pipelines (line 12)
- Pub/Sub (line 44)
- Go API Maturity Timeline (line 108)

---

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
```go
// Non-blocking subscribe (lazy)
err := client.Subscribe(ctx, []string{"channel"})
err = client.PSubscribe(ctx, []string{"events:*"})

// Blocking subscribe - waits for server confirmation
err = client.SubscribeBlocking(ctx, []string{"channel"}, 5000)
err = client.PSubscribeBlocking(ctx, []string{"events:*"}, 5000)

// Receive via queue (when no callback configured)
queue, err := client.GetQueue()
msg := queue.Pop()                    // non-blocking, returns nil if empty
msgCh := queue.WaitForMessage()       // blocking, returns a channel
msg = <-msgCh

// Unsubscribe
err = client.Unsubscribe(ctx, []string{"channel"})
err = client.PUnsubscribe(ctx, []string{"events:*"})
err = client.UnsubscribeAll(ctx)      // all exact channels
err = client.PUnsubscribeAll(ctx)     // all patterns
```

go-redis uses a Go channel-based approach (`pubsub.Channel()`). GLIDE uses callbacks (set at creation time) or queue-based polling (`GetQueue` + `Pop` / `WaitForMessage`). Use a dedicated client for subscriptions. GLIDE automatically resubscribes on reconnection.

---

## Go API Maturity Timeline

| Version | Feature |
|---------|---------|
| 2.0 | GA release (June 2025), PubSub support |
| 2.2 | `go mod vendor` support |
| 2.3 | Dynamic PubSub, ACL commands, cluster management commands |

The team minimized interface usage in favor of concrete types after community feedback that returning interfaces was non-idiomatic Go.
