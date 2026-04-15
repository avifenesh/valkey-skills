---
name: migrate-go-redis
description: "Use when migrating Go from go-redis to Valkey GLIDE. Covers Result[T] nil handling, CGO dependency, PubSub, SetWithOptions, Alpine/MUSL gotchas. Not for greenfield Go apps - use valkey-glide-go instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from go-redis to Valkey GLIDE (Go)

Use when migrating a Go application from `go-redis/redis` to the GLIDE client library.

## Routing

- String, hash, list, set, sorted set, delete, exists, cluster -> API Mapping
- Pipeline, transaction, Batch API, TxPipelined -> Advanced Patterns
- PubSub, subscribe, publish, queue-based polling -> Advanced Patterns

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

go-redis uses `redis.Nil` as an error sentinel for missing keys. GLIDE separates nil from errors - `err` is only for actual errors, `val.IsNil()` checks for key absence.

## Quick Start - Connection Setup

**go-redis:**
```go
rdb := redis.NewClient(&redis.Options{Addr: "localhost:6379", Password: "", DB: 0})
```

**GLIDE:**
```go
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})
client, err := glide.NewClient(cfg)
defer client.Close()
```

## Configuration Mapping

| go-redis field | GLIDE equivalent |
|----------------|------------------|
| `Addr: "host:port"` | `WithAddress(&config.NodeAddress{Host, Port})` |
| `Password` | `WithCredentials(&config.ServerCredentials{Password: "..."})` |
| `DB` | `WithDatabaseId(0)` |
| `DialTimeout` | `WithRequestTimeout(ms)` |
| `TLSConfig` | `WithUseTLS(true)` |
| `PoolSize` | Not needed - single multiplexed connection |
| `MaxRetries` | Built-in reconnection via `WithReconnectStrategy` |

## Incremental Migration Strategy

No drop-in compatibility layer exists for Go. Migration approach:

1. Add `github.com/valkey-io/valkey-glide/go/v2` to your `go.mod` alongside `go-redis`
2. Define a repository or store interface that abstracts the Redis client
3. Create a GLIDE implementation alongside the go-redis one
4. Replace `redis.Nil` error checks with `Result[T].IsNil()` at each call site
5. Run tests after each package migration to catch nil-handling regressions
6. Remove `go-redis` from `go.mod` once all implementations are migrated

## Reference

| Topic | File |
|-------|------|
| Command-by-command API mapping (strings, hashes, lists, sets, sorted sets, delete, exists, cluster) | [api-mapping](reference/api-mapping.md) |
| Transactions, pipelines, Pub/Sub, Go API maturity timeline | [advanced-patterns](reference/advanced-patterns.md) |

## Gotchas

1. **`Result[T]` instead of `redis.Nil`.** Check `IsNil()` before calling `Value()`.
2. **Slice args, not varargs.** Multi-key commands take `[]string` slices.
3. **Separate `Set` and `SetWithOptions`.** go-redis combines expiry into `Set()`. GLIDE has separate methods.
4. **CGO dependency.** GLIDE for Go uses CGO to call the Rust core. Cross-compilation requires Docker-based builds or platform-native compilation.
5. **Alpine Linux / MUSL.** Requires the `musl` build tag: `export GOFLAGS=-tags=musl`.
6. **No connection pool tuning.** Drop all `PoolSize`, `MinIdleConns` configuration.
7. **Import path.** Module is `github.com/valkey-io/valkey-glide/go/v2` with subpackages `config`, `options`, `pipeline`, `models`, `constants`.
8. **`go mod vendor` support.** Added in GLIDE 2.2 - earlier versions did not work with vendor mode.
