# Error Handling

Use when implementing error handling, retry logic, or batch error semantics in the GLIDE Go client.

## Error Types

Go GLIDE uses typed error structs with the standard `errors.As` pattern:

```go
import (
    "errors"
    glide "github.com/valkey-io/valkey-glide/go/v2"
)
```

| Error | When It Occurs | Recovery |
|-------|---------------|----------|
| `*glide.ConnectionError` | Connection lost | GLIDE auto-reconnects; retry the operation |
| `*glide.TimeoutError` | Request exceeded `WithRequestTimeout` (default 250ms) | Increase timeout or check server load |
| `*glide.ExecAbortError` | Atomic batch aborted (WATCH key changed) | Retry the transaction |
| `*glide.ClosingError` | Client was closed | Create a new client |
| `*glide.ConfigurationError` | Invalid client configuration | Fix config and recreate |
| `*glide.DisconnectError` | Connection problem between client and server | Check network; GLIDE may reconnect |
| `*glide.BatchError` | Multiple errors in a batch response | Inspect individual errors via `.Error()` |

## Basic Error Handling

```go
val, err := client.Get(ctx, "key")
if err != nil {
    var connErr *glide.ConnectionError
    var timeoutErr *glide.TimeoutError
    if errors.As(err, &connErr) {
        // Connection lost - GLIDE is already reconnecting
        // Retry the operation after a brief delay
    } else if errors.As(err, &timeoutErr) {
        // Request exceeded timeout - check server load or increase timeout
    } else {
        // General error
        fmt.Println("Error:", err)
    }
    return
}
// Check for nil result (key not found is NOT an error)
if val.IsNil() {
    fmt.Println("Key does not exist")
} else {
    fmt.Println("Value:", val.Value())
}
```

Go separates nil-check from error-check. A nil result (key not found) is not an error - check `val.IsNil()` after confirming `err == nil`.

---

## Batch Error Handling

The `raiseOnError` parameter on `client.Exec()` controls how batch errors surface:

### raiseOnError = true

First error in results is returned as the `error` return value.

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

tx := pipeline.NewStandaloneBatch(true)
tx.Set("key", "val")
tx.Get("key")
results, err := client.Exec(ctx, *tx, true)
if err != nil {
    fmt.Println("Batch failed:", err)
    return
}
```

### raiseOnError = false

Errors appear inline as `error` values in the `[]any` slice. Use `glide.IsError()` to check:

```go
pipe := pipeline.NewStandaloneBatch(false)
pipe.Set("key", "value")
pipe.LPush("key", []string{"oops"})  // WRONGTYPE error
pipe.Get("key")

results, err := client.Exec(ctx, *pipe, false)
for i, item := range results {
    if e := glide.IsError(item); e != nil {
        fmt.Printf("Command %d failed: %v\n", i, e)
    } else {
        fmt.Printf("Command %d OK: %v\n", i, item)
    }
}
```

Atomic batches with WATCH return `nil, nil` (nil results, no error) if a watched key was modified. Retry the transaction in a loop.

---

## Reconnection Behavior

GLIDE reconnects automatically on connection loss with exponential backoff:

```go
import "github.com/valkey-io/valkey-glide/go/v2/config"

strategy := config.NewBackoffStrategy(5, 100, 2)  // retries, factor(ms), exponentBase
strategy.WithJitterPercent(20)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithReconnectStrategy(strategy)
```

- Delay formula: `factor * (exponentBase ^ attempt)` with optional jitter
- After `numOfRetries`, delay stays at the ceiling indefinitely
- PubSub channels are automatically resubscribed on reconnect
- Permanent errors (NOAUTH, WRONGPASS) are not retried

---

## Failover and Timeout

During cluster failover, expect `ConnectionError` bursts for 1-5 seconds. GLIDE refreshes the slot map and re-routes automatically. Retry failed operations.

Frequent `TimeoutError` indicates server load - verify before increasing timeout:

```go
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithRequestTimeout(1 * time.Second)  // default 250ms
```

GLIDE auto-extends timeouts for blocking commands (BLPOP, XREADGROUP BLOCK) by 500ms beyond the block duration.
