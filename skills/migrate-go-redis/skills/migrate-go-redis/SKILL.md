---
name: migrate-go-redis
description: "Use when migrating Go from go-redis to Valkey GLIDE. Covers Result[T] nil handling (no redis.Nil), slice args, typed SET/ZADD options, flat error model, CGO requirement. Publish arg order is UNCHANGED. Not for greenfield Go apps - use valkey-glide-go."
version: 1.1.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from go-redis to Valkey GLIDE (Go)

Use when moving an existing `go-redis/redis` app to GLIDE. Assumes you already know go-redis. Covers what breaks or changes shape; commands that translate literally (same method names, `ctx` first arg) are not listed here.

## Divergences that actually matter

| Area | go-redis | GLIDE Go |
|------|----------|---------|
| Construction | `redis.NewClient(&redis.Options{Addr: "host:6379"})` | `glide.NewClient(cfg)` returning `(*Client, error)` |
| Cluster | `redis.NewClusterClient(&redis.ClusterOptions{...})` | `glide.NewClusterClient(cfg)` |
| Config style | Struct literal | Builder chain: `config.NewClientConfiguration().WithAddress(...).With...()` |
| Return types | `*StatusCmd`, `*StringCmd`, etc.; call `.Result()` | Direct `(Result[T], error)` from command; `.IsNil()` + `.Value()` on the Result |
| Nil handling | `if err == redis.Nil` sentinel for missing key | `err` is only real errors; `val.IsNil()` for missing key - two orthogonal checks |
| Error types | `redis.Error` types in one package with `errors.Is` | FLAT model - `*ConnectionError`, `*TimeoutError`, `*DisconnectError`, `*ExecAbortError`, `*ClosingError`, `*ConfigurationError`, `*BatchError` - independent structs. Most operational errors fall through to generic `errors.New(msg)`. |
| Multi-arg commands | Varargs: `Del(ctx, "k1", "k2")` | Slice: `Del(ctx, []string{"k1", "k2"})` - same for `Exists`, `LPush`, `SAdd`, `SRem` |
| SET expiry | Duration arg: `Set(ctx, k, v, 60*time.Second)` | `SetWithOptions(ctx, k, v, *options.NewSetOptions().SetExpiry(options.NewExpiryIn(60*time.Second)))` - `NewExpiryIn` for duration, `NewExpiryAt` for absolute `time.Time`, `NewExpiryKeepExisting()` for KEEPTTL |
| ZADD | `ZAdd(ctx, key, redis.Z{Score, Member})` varargs | `ZAdd(ctx, key, map[string]float64{"alice": 1.0})` or with `options.NewZAddOptions().SetConditionalChange(...)` |
| Pipeline | `rdb.Pipeline()` + `.Set(...)` + `.Exec(ctx)` chain | `pipeline.NewStandaloneBatch(false)` + `batch.Set(...)` + `client.Exec(ctx, *batch, raiseOnError)` |
| Transaction | `rdb.TxPipelined(ctx, func(pipe Pipeliner) error { ... })` closure | `pipeline.NewStandaloneBatch(true)` + `client.Exec(ctx, *batch, raiseOnError)` - same class, `isAtomic` flag |
| Pipeline results | `[]redis.Cmder` - iterate `.Err()` and `.Val()` | `[]any` - iterate with `glide.IsError(item)` check |
| `Publish` | `rdb.Publish(ctx, channel, message)` | `client.Publish(ctx, channel, message)` - **SAME ORDER** (unlike Python/Node GLIDE which reverses) |
| PubSub | `pubsub := rdb.Subscribe(ctx, ch); pubsub.ReceiveMessage(ctx)` | Static config OR dynamic `Subscribe(ctx, ...)` (GLIDE 2.3+); callback in config OR polling |
| Connection pool | `Options.PoolSize`, `MinIdleConns`, `PoolTimeout` | Multiplexer - no pool knobs; blocking commands need a dedicated client |
| Retries | `Options.MaxRetries`, `MinRetryBackoff` | Reconnection is INFINITE; `config.NewBackoffStrategy(n, factor, base)` caps backoff sequence length only |
| TLS | `Options.TLSConfig *tls.Config` | `WithUseTLS(true)` + `config.NewTlsConfiguration().WithRootCertificates(...)` in advanced config |
| IAM (not in go-redis) | N/A | `config.NewIamAuthConfig("cluster", config.ElastiCache, "us-east-1")` + `NewServerCredentialsWithIam` |
| `redis.Nil`-style empty returns | Sentinel error | N/A - use `IsNil()` or check for empty map/slice |
| Cluster topology | `ClusterOptions.Addrs`, `RouteByLatency`, `RouteRandomly` | `WithAddress(...)` (multiple OK; seeds), `WithReadFrom(config.PreferReplica / AzAffinity / ...)` |

## Error handling - THE biggest change

```go
// go-redis: Nil is a sentinel error
val, err := rdb.Get(ctx, "key").Result()
if err == redis.Nil { /* missing */ }
else if err != nil  { /* real error */ }
else                { /* val is the value */ }

// GLIDE: Nil is not an error
val, err := client.Get(ctx, "key")
if err != nil { /* real error - typed or generic errors.New */ ; return }
if val.IsNil() { /* missing */ }
else           { /* val.Value() is the value */ }
```

Importantly, GLIDE's error model is FLAT - you can't catch "all request errors" with one type check. See [error-handling reference](../../valkey-glide-go/skills/valkey-glide-go/reference/best-practices-error-handling.md) (or the greenfield skill) for the full picture.

## Config translation

```go
// go-redis:
rdb := redis.NewClient(&redis.Options{
    Addr: "h:6379", Password: "pw", DB: 0,
    DialTimeout: 5 * time.Second, TLSConfig: &tls.Config{},
    PoolSize: 10, MaxRetries: 3,
})

// GLIDE:
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "h", Port: 6379}).
    WithCredentials(config.NewServerCredentialsWithDefaultUsername("pw")).
    WithDatabaseId(0).
    WithRequestTimeout(5 * time.Second).
    WithUseTLS(true).
    WithReconnectStrategy(config.NewBackoffStrategy(5, 100, 2))
client, err := glide.NewClient(cfg)
```

Drop `PoolSize`, `MinIdleConns`, `PoolTimeout`, `IdleTimeout`, `MaxConnAge` - GLIDE has no pool.

## Migration strategy

No compatibility layer. Migrate incrementally:

1. Add `github.com/valkey-io/valkey-glide/go/v2` alongside `go-redis` in `go.mod`.
2. Define a repository interface that abstracts the Redis client. Implement both sides.
3. Swap implementations behind a build tag or config flag per package.
4. **Rewrite nil-handling at every call site** - `redis.Nil` checks become `Result[T].IsNil()` checks. This is the biggest chunk of mechanical work.
5. Run tests after each package - nil handling regressions are the most common failure.
6. Remove `go-redis` from `go.mod` when all implementations are migrated.

## Reference

| Topic | File |
|-------|------|
| Slice args, SET typed options, ZADD map form, cluster, per-command divergences | [api-mapping](reference/api-mapping.md) |
| Pipeline/transaction mapping, PubSub (static + dynamic 2.3+), platform / CGO / Alpine notes | [advanced-patterns](reference/advanced-patterns.md) |

## Gotchas (the short list)

1. **`Result[T].IsNil()` not `redis.Nil`.** Two orthogonal checks: `err` for transport, `IsNil()` for missing key.
2. **Flat error model.** `ConnectionError`, `TimeoutError`, `DisconnectError`, `ExecAbortError`, etc. are independent structs with no base class; `errors.As(err, &connErr)` catches ONLY that specific type. Most runtime errors fall through to `errors.New(msg)`.
3. **Most "connection lost" errors arrive as `*DisconnectError`, not `*ConnectionError`.** Subtle. `ConnectionError` is mostly setup-time.
4. **Slice args for multi-key** - `Del(ctx, []string{"k1","k2"})`, not varargs.
5. **`SetWithOptions` for expiry** - the simple `Set` has no duration parameter; use `options.NewSetOptions().SetExpiry(options.NewExpiryIn(d))` (`In` for duration, `At` for timestamp, `KeepExisting` for KEEPTTL).
6. **`Publish(ctx, channel, message)` order is UNCHANGED from go-redis.** Python/Node GLIDE reverse this; Go does not.
7. **No pool tuning.** Delete `PoolSize`, `MinIdleConns`, `PoolTimeout` etc. Blocking commands (`BLPop`, `BRPop`, `BLMove`, `BZPopMax`/`Min`, `BRPopLPush`, `BLMPop`, `BZMPop`, `XRead`/`XReadGroup` with block, WATCH) need a dedicated client instead.
8. **Reconnection is infinite** - no `MaxRetries` equivalent.
9. **CGO is mandatory.** Requires a C toolchain and glibc 2.17+. Alpine needs `musl-gcc` / `CGO_ENABLED=1`.
10. **`inflightRequestsLimit` is NOT exposed** in Go at v2.3.1 (Python/Node expose it). Core cap of 1000 applies.
11. **`go mod vendor`** works from GLIDE 2.2+. Older versions had vendor-mode issues.
12. **Import root** - `github.com/valkey-io/valkey-glide/go/v2` with subpackages `config`, `options`, `pipeline`, `models`, `constants`.

## Cross-references

- `valkey-glide-go` - full Go skill for GLIDE features beyond the migration scope
- `glide-dev` - GLIDE core internals (Rust + CGO bridge) if you need to debug binding-level issues
