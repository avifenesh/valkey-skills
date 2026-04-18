# Error handling (Go)

Covers what differs from go-redis's `redis.Nil` sentinel + typed errors in `redis` package. GLIDE Go has a fundamentally different error model you need to understand.

## Divergence from go-redis

| go-redis | GLIDE Go |
|----------|---------|
| `val, err := rdb.Get(ctx, key).Result()`; `errors.Is(err, redis.Nil)` for missing key | `val, err := client.Get(ctx, key)` returns `(Result[string], error)`; check `err` for transport errors first, THEN `val.IsNil()` for missing key |
| Typed errors in `redis` package, pointer to base | FLAT error model - independent structs, no base class. `*ConnectionError`, `*TimeoutError`, `*DisconnectError`, `*ExecAbortError`, `*ClosingError`, `*ConfigurationError`, `*BatchError` - each unrelated |
| `redis.Nil` sentinel for missing key | `Result[T].IsNil()` - separate API, no error at all |
| `MaxRetries` caps request retries | Reconnection is INFINITE - `numOfRetries` on `BackoffStrategy` only caps backoff sequence length |

## Go's flat error model - the subtle gotcha

```go
import (
    "errors"
    glide "github.com/valkey-io/valkey-glide/go/v2"
)

val, err := client.Get(ctx, "key")
if err != nil {
    var connErr *glide.ConnectionError
    var discErr *glide.DisconnectError
    var timeoutErr *glide.TimeoutError
    var closingErr *glide.ClosingError
    switch {
    case errors.As(err, &connErr):
        // rare - only at setup-type errors
    case errors.As(err, &discErr):
        // MOST "connection lost" scenarios arrive as DisconnectError, not ConnectionError
    case errors.As(err, &timeoutErr):
        // request exceeded requestTimeout
    case errors.As(err, &closingErr):
        // client is closed - create a new one
    default:
        // generic errors.New(msg) - the majority of operational errors
    }
    return
}
if val.IsNil() { /* key not found - not an error */ }
```

### Why this differs from Python / Node

Only three errors are auto-typed by `GoError()` in `go/errors.go`: `ExecAbort`, `Timeout`, `Disconnect`. Everything else falls through to generic `errors.New(msg)`. So most operational errors do NOT match a typed struct. This is a bigger behavioral gap than it looks.

Python's `except RequestError:` / Node's `instanceof RequestError` catch the whole timeout+connection+config+exec-abort family. Go has no equivalent - you either list each `errors.As` check or resort to string matching on the message.

### Typed errors reference

| Type | Source |
|------|--------|
| `*ConnectionError` | Explicit throws in client setup |
| `*DisconnectError` | Auto-mapped from core's `Disconnect` - actual "connection lost" signal |
| `*TimeoutError` | Auto-mapped from core's `Timeout` |
| `*ExecAbortError` | Auto-mapped from atomic-batch WATCH conflicts / MULTI errors |
| `*ClosingError` | Explicit throws when client is closed |
| `*ConfigurationError` | Explicit throws in config validation |
| `*BatchError` | Wraps multiple prep-time batch errors (`[]error` collected during command construction) |

## Batch error handling

`raiseOnError=true` returns the first inline error as `err`; `raiseOnError=false` embeds errors inline in the results slice - use `glide.IsError(item)` to check:

```go
results, err := client.Exec(ctx, *batch, false)
for i, item := range results {
    if e := glide.IsError(item); e != nil { /* handle command i */ }
}
```

Atomic batches with WATCH return `nil, nil` on conflict (not an error).

## Reconnection behavior

```go
strategy := config.NewBackoffStrategy(5, 100, 2)  // numOfRetries, factor_ms, exponentBase
strategy.WithJitterPercent(20)
```

- Delay formula: `rand_jitter * factor * (exponentBase ^ attempt)` (conceptual; Go doesn't have an exponentiation operator - the math is done in the Rust core), clamped at a ceiling.
- After `numOfRetries` the delay plateaus and reconnection continues infinitely until close.
- Initial-connect permanent errors (`AuthenticationFailed`, `InvalidClientConfig`, `RESP3NotSupported`, plus `NOAUTH` / `WRONGPASS` string matches) are not retried. After initial connect, the core keeps reconnecting and surfaces `DisconnectError` / generic error per command until the server recovers.
- PubSub channels resubscribe automatically via the synchronizer.

## Failover and timeout

During cluster failover expect error bursts for 1-5 seconds while the slot map refreshes. Retry is the right response.

Frequent `*TimeoutError` usually indicates server load, not a too-tight timeout. GLIDE auto-extends the effective timeout for blocking commands (BLPOP/BRPOP/BLMOVE/BZPopMax/BZPopMin/BRPopLPush/BLMPop/BZMPop and XRead/XReadGroup with block, WAIT/WAITAOF) by 0.5 s beyond the block duration - no tuning required.
