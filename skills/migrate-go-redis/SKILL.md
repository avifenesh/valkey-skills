---
name: migrate-go-redis
description: "go-redis to Valkey GLIDE migration for Go. Covers Result[T] nil handling, CGO dependency, PubSub, SetWithOptions, Alpine/MUSL gotchas. Not for greenfield Go apps - use valkey-glide-go instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from go-redis to Valkey GLIDE (Go)

Use when migrating a Go application from `go-redis/redis` to the GLIDE client library.

---

## Contents

- [Key Differences](#key-differences)
- [Connection Setup](#connection-setup)
- [Configuration Mapping](#configuration-mapping)
- [Error Handling - The Biggest Change](#error-handling---the-biggest-change)
- [String Operations](#string-operations)
- [Hash Operations](#hash-operations)
- [List Operations](#list-operations)
- [Set Operations](#set-operations)
- [Sorted Set Operations](#sorted-set-operations)
- [Delete and Exists](#delete-and-exists)
- [Cluster Mode](#cluster-mode)
- [Transactions and Pipelines](#transactions-and-pipelines)
- [Pub/Sub](#pubsub)
- [Incremental Migration Strategy](#incremental-migration-strategy)
- [Gotchas](#gotchas)
- [Go API Maturity Timeline](#go-api-maturity-timeline)

---

## Key Differences

| Area | go-redis | GLIDE |
|------|----------|-------|
| Return types | `*StatusCmd`, `*StringCmd` with `.Result()` | `models.Result[T]` with `.Value()` and `.IsNil()` |
| Nil handling | `redis.Nil` sentinel error | `val.IsNil()` method |
| Configuration | `redis.Options{}` struct | `config.NewClientConfiguration()` builder chain |
| Multi-arg commands | Varargs: `Del(ctx, "k1", "k2")` | Slice args: `Del(ctx, []string{"k1", "k2"})` |
| Expiry | Duration arg: `Set(ctx, "k", "v", 60*time.Second)` | `SetWithOptions` + `options.SetOptions` |
| Transactions | `TxPipelined()` closure | `pipeline.NewStandaloneBatch(true)` + `client.Exec()` |
| Pipelines | `Pipelined()` closure | `pipeline.NewStandaloneBatch(false)` + `client.Exec()` |
| Connection model | Pool with configurable size | Single multiplexed connection per node |
| API style | Synchronous with goroutine safety | Synchronous with goroutine safety (via CGO bridge) |

---

## Connection Setup

**go-redis:**
```go
import "github.com/redis/go-redis/v9"

rdb := redis.NewClient(&redis.Options{
    Addr:     "localhost:6379",
    Password: "",
    DB:       0,
})
err := rdb.Ping(ctx).Err()
```

**GLIDE:**
```go
import (
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})

client, err := glide.NewClient(cfg)
if err != nil {
    panic(err)
}
defer client.Close()
```

---

## Configuration Mapping

| go-redis field | GLIDE equivalent |
|----------------|------------------|
| `Addr: "host:port"` | `WithAddress(&config.NodeAddress{Host, Port})` |
| `Password` | `WithCredentials(&config.ServerCredentials{Password: "..."})` |
| `Username` | `WithCredentials(&config.ServerCredentials{Username: "...", Password: "..."})` |
| `DB` | `WithDatabaseId(0)` |
| `DialTimeout` | `WithRequestTimeout(ms)` |
| `ReadTimeout` | Part of `WithRequestTimeout` |
| `TLSConfig` | `WithUseTLS(true)` |
| `PoolSize` | Not needed - single multiplexed connection |
| `MaxRetries` | Built-in reconnection via `WithReconnectStrategy` |

---

## Error Handling - The Biggest Change

**go-redis:**
```go
val, err := rdb.Get(ctx, "key").Result()
if err == redis.Nil {
    fmt.Println("key does not exist")
} else if err != nil {
    fmt.Println("error:", err)
} else {
    fmt.Println("value:", val)
}
```

**GLIDE:**
```go
val, err := client.Get(ctx, "key")
if err != nil {
    fmt.Println("error:", err)
    return
}
if val.IsNil() {
    fmt.Println("key does not exist")
} else {
    fmt.Println("value:", val.Value())
}
```

The critical difference: go-redis uses `redis.Nil` as an error sentinel for missing keys. GLIDE separates the nil check from error handling - `err` is only for actual errors, and `val.IsNil()` checks for key absence.

---

## String Operations

**go-redis:**
```go
err := rdb.Set(ctx, "key", "value", 0).Err()
err = rdb.Set(ctx, "key", "value", 60*time.Second).Err()  // with expiry
val, err := rdb.Get(ctx, "key").Result()
```

**GLIDE:**
```go
import (
    "time"
    "github.com/valkey-io/valkey-glide/go/v2/options"
)

_, err := client.Set(ctx, "key", "value")
// With expiry - use SetWithOptions
opts := options.NewSetOptions().
    SetExpiry(options.NewExpiryIn(60 * time.Second))
_, err = client.SetWithOptions(ctx, "key", "value", *opts)
val, err := client.Get(ctx, "key")
fmt.Println(val.Value())  // string
```

---

## Hash Operations

**go-redis:**
```go
rdb.HSet(ctx, "hash", "f1", "v1", "f2", "v2")   // varargs pairs
rdb.HSet(ctx, "hash", map[string]interface{}{"f1": "v1"})
val, err := rdb.HGet(ctx, "hash", "f1").Result()
all, err := rdb.HGetAll(ctx, "hash").Result()     // map[string]string
```

**GLIDE:**
```go
client.HSet(ctx, "hash", map[string]string{"f1": "v1", "f2": "v2"})
val, err := client.HGet(ctx, "hash", "f1")
if !val.IsNil() {
    fmt.Println(val.Value())
}
all, err := client.HGetAll(ctx, "hash")           // map[string]string
```

---

## List Operations

**go-redis:**
```go
rdb.LPush(ctx, "list", "a", "b", "c")
rdb.RPush(ctx, "list", "x", "y")
val, err := rdb.LPop(ctx, "list").Result()
vals, err := rdb.LRange(ctx, "list", 0, -1).Result()
```

**GLIDE:**
```go
client.LPush(ctx, "list", []string{"a", "b", "c"})     // slice arg
client.RPush(ctx, "list", []string{"x", "y"})
val, err := client.LPop(ctx, "list")
if !val.IsNil() {
    fmt.Println(val.Value())
}
vals, err := client.LRange(ctx, "list", 0, -1)          // []string
```

---

## Set Operations

**go-redis:**
```go
rdb.SAdd(ctx, "set", "a", "b", "c")
rdb.SRem(ctx, "set", "a")
members, err := rdb.SMembers(ctx, "set").Result()
isMember, err := rdb.SIsMember(ctx, "set", "b").Result()
```

**GLIDE:**
```go
client.SAdd(ctx, "set", []string{"a", "b", "c"})
client.SRem(ctx, "set", []string{"a"})
members, err := client.SMembers(ctx, "set")              // map[string]struct{}
isMember, err := client.SIsMember(ctx, "set", "b")       // bool
```

---

## Sorted Set Operations

**go-redis:**
```go
rdb.ZAdd(ctx, "zset", redis.Z{Score: 1.0, Member: "alice"},
                       redis.Z{Score: 2.0, Member: "bob"})
score, err := rdb.ZScore(ctx, "zset", "alice").Result()
```

**GLIDE:**
```go
client.ZAdd(ctx, "zset", map[string]float64{
    "alice": 1.0,
    "bob":   2.0,
})
score, err := client.ZScore(ctx, "zset", "alice")
fmt.Println(score.Value())  // 1.0
```

---

## Delete and Exists

**go-redis:**
```go
rdb.Del(ctx, "k1", "k2", "k3")                // varargs
count, err := rdb.Exists(ctx, "k1", "k2").Result()
```

**GLIDE:**
```go
client.Del(ctx, []string{"k1", "k2", "k3"})   // slice arg
count, err := client.Exists(ctx, []string{"k1", "k2"})
```

---

## Cluster Mode

**go-redis:**
```go
rdb := redis.NewClusterClient(&redis.ClusterOptions{
    Addrs: []string{
        "node1.example.com:6379",
        "node2.example.com:6380",
    },
    ReadOnly: true,
})
```

**GLIDE:**
```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6380}).
    WithReadFrom(config.PreferReplica)

client, err := glide.NewClusterClient(cfg)
```

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

go-redis uses a Go channel-based approach (`pubsub.Channel()`). GLIDE uses either callbacks (set at creation time) or queue-based polling (`GetQueue` + `Pop` / `WaitForMessage`). Use a dedicated client for subscriptions. GLIDE automatically resubscribes on reconnection.

---

## Incremental Migration Strategy

No drop-in compatibility layer exists for Go. The recommended approach:

1. Add `github.com/valkey-io/valkey-glide/go/v2` to your `go.mod` alongside `go-redis`
2. Define a repository or store interface that abstracts the Redis client
3. Create a GLIDE implementation of that interface alongside the go-redis one
4. Migrate one service or package at a time, swapping the interface implementation
5. Replace `redis.Nil` error checks with `Result[T].IsNil()` at each call site
6. Run tests after each package migration to catch nil-handling regressions
7. Remove `go-redis` from `go.mod` once all implementations are migrated
8. Review `best-practices/production.md` for timeout tuning, connection management, and observability setup

---

## See Also

- **valkey-glide-go** skill - full GLIDE Go API details
- Batching (see valkey-glide skill) - pipeline and transaction patterns
- PubSub (see valkey-glide skill) - subscription patterns and dynamic PubSub
- TLS and authentication (see valkey-glide skill) - TLS setup and credential management
- Production deployment (see valkey-glide skill) - timeout tuning, connection management, observability
- Error handling (see valkey-glide skill) - error types, reconnection, batch error semantics

---

## Gotchas

1. **`Result[T]` instead of `redis.Nil`.** The biggest behavioral change. go-redis returns `redis.Nil` as an error for missing keys. GLIDE returns a `Result[T]` with `.IsNil()` and `.Value()` methods. Always check `IsNil()` before calling `Value()`.

2. **Slice args, not varargs.** Multi-key commands take `[]string` slices. Passing bare strings will not compile.

3. **Separate `Set` and `SetWithOptions`.** go-redis combines expiry into `Set()` as a duration parameter. GLIDE has a plain `Set()` and `SetWithOptions()` for expiry, conditional set, and return-old-value.

4. **CGO dependency.** GLIDE for Go uses CGO to call the Rust core via pre-built static libraries. This is the single biggest migration concern for Go users accustomed to pure-Go builds. Cross-compilation requires Docker-based builds (`CGO_ENABLED=1` with appropriate `CC` for the target arch) or platform-native compilation. macOS cross-compilation requires building on a macOS system.

5. **Alpine Linux / MUSL.** Supported but requires the `musl` build tag: `export GOFLAGS=-tags=musl`. Without this tag, the build will fail or produce a broken binary on Alpine containers.

6. **No connection pool tuning.** Drop all `PoolSize`, `MinIdleConns`, and pool-related configuration. GLIDE handles connection multiplexing internally.

7. **Context parameter.** Both go-redis and GLIDE use `context.Context` as the first parameter, so this transfers directly.

8. **Import path.** The module is `github.com/valkey-io/valkey-glide/go/v2`. Subpackages include `config`, `options`, `pipeline`, `models`, and `constants`. The original `api` package name was refactored to `glide` for idiomatic Go.

9. **`go mod vendor` support.** Added in GLIDE 2.2. Earlier versions did not work with vendor mode, which blocked adoption in environments that require vendored dependencies.

---

## Go API Maturity Timeline

| Version | Feature |
|---------|---------|
| 2.0 | GA release (June 2025), PubSub support |
| 2.2 | `go mod vendor` support |
| 2.3 | Dynamic PubSub, ACL commands, cluster management commands |

Community feedback shaped the API design - the team minimized interface usage in favor of concrete types after developers noted that returning interfaces was non-idiomatic Go.
