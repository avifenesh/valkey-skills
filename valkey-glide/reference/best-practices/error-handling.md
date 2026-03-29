# Error Handling

Use when implementing error handling for GLIDE operations, configuring reconnection strategies, or dealing with batch error semantics. For timeout tuning and deployment configuration, see `production.md`.

---

## Error Type Hierarchy

GLIDE defines a consistent error hierarchy across all languages. The Rust core (`glide-core/src/errors.rs`) classifies errors into four internal types, and each language wrapper maps these to idiomatic exception/error types.

### Core Error Types (Rust)

```rust
pub enum RequestErrorType {
    Unspecified = 0,   // General request failures
    ExecAbort = 1,     // Transaction aborted (WATCH key changed)
    Timeout = 2,       // Request exceeded timeout
    Disconnect = 3,    // Connection lost
}
```

### Language-Level Error Types

| Error | Description | When It Occurs |
|-------|-------------|----------------|
| `RequestError` | Base class for all GLIDE request failures | Any server-side or protocol error |
| `TimeoutError` | Request exceeded `request_timeout` | Slow server, network latency, overloaded node |
| `ConnectionError` | Connection to server was lost | Network partition, server restart, node failure |
| `ExecAbortError` | Atomic batch (transaction) was aborted | WATCH key was modified by another client |
| `ConfigurationError` | Invalid client configuration | Bad addresses, incompatible options, missing params |

The `Disconnect` error type in Rust maps to `ConnectionError` in wrappers. When a disconnect is detected, the Rust core appends "Will attempt to reconnect" to the error message and triggers the automatic reconnection process.

---

## Error Handling Patterns by Language

### Python

```python
from glide import (
    GlideClient,
    TimeoutError as GlideTimeoutError,
    ConnectionError as GlideConnectionError,
    RequestError,
    ExecAbortError,
)

try:
    value = await client.get("key")
except GlideTimeoutError:
    # Request took longer than request_timeout (default 250ms)
    # Consider increasing timeout or investigating server load
    pass
except GlideConnectionError:
    # Connection lost - GLIDE is already reconnecting automatically
    # Retry the operation after a brief delay
    pass
except ExecAbortError:
    # Only occurs with atomic batches (transactions)
    # A watched key was modified - retry the transaction
    pass
except RequestError as e:
    # Catch-all for other request failures
    print(f"Request failed: {e}")
```

Note: GLIDE aliases `TimeoutError` and `ConnectionError` to avoid shadowing Python built-in names. Import them with explicit aliases.

### Java

```java
try {
    String value = client.get("key").get();
} catch (ExecutionException e) {
    Throwable cause = e.getCause();
    if (cause instanceof RequestException) {
        RequestException re = (RequestException) cause;
        System.err.println("Request failed: " + re.getMessage());
    }
}
```

Java wraps all errors in `ExecutionException` because operations return `CompletableFuture`. Always unwrap with `getCause()` to access the actual GLIDE error.

### Node.js

```javascript
import {
    GlideClient,
    RequestError,
    TimeoutError,
    ConnectionError,
} from "@valkey/valkey-glide";

try {
    const value = await client.get("key");
} catch (error) {
    if (error instanceof TimeoutError) {
        // Request exceeded timeout
    } else if (error instanceof ConnectionError) {
        // Connection lost, auto-reconnecting
    } else if (error instanceof RequestError) {
        // General request failure
    }
}
```

### Go

Go uses the standard `errors.As` pattern for type-checking GLIDE errors:

```go
val, err := client.Get(ctx, "key")
if err != nil {
    var connErr *glide.ConnectionError
    var timeoutErr *glide.TimeoutError
    if errors.As(err, &connErr) {
        // Connection lost - client is auto-reconnecting
        fmt.Println("Connection error:", connErr)
    } else if errors.As(err, &timeoutErr) {
        // Request timed out
        fmt.Println("Timeout:", timeoutErr)
    } else {
        // General error
        fmt.Println("Error:", err)
    }
    return
}
if val.IsNil() {
    fmt.Println("Key does not exist")
}
```

Go separates nil-check from error-check. A nil result (key not found) is not an error - check `val.IsNil()` after confirming `err == nil`.

---

## Batch Error Handling

The `raise_on_error` parameter controls how errors in batches (pipelines and transactions) are surfaced.

### raise_on_error = true (Default for Atomic Batches)

Throws/raises on the first error encountered. The entire batch result is discarded.

```python
try:
    result = await client.exec(batch, raise_on_error=True)
except RequestError as e:
    print(f"Batch failed: {e}")
```

Use this when all commands in the batch must succeed (transactions, atomic operations).

### raise_on_error = false (Default for Non-Atomic Batches)

Returns errors inline in the response array. Each position corresponds to the command at that index.

```python
result = await client.exec(batch, raise_on_error=False)
for i, item in enumerate(result):
    if isinstance(item, RequestError):
        print(f"Command {i} failed: {item}")
    else:
        print(f"Command {i} succeeded: {item}")
```

Use this when partial success is acceptable (bulk operations, cache warming).

### Go Batch Error Handling

Go batch error handling follows the same pattern - check the top-level error for total batch failure, then inspect individual results for per-command errors. Consult the Go client API reference for the exact `Exec` signature and result types.

---

## Reconnection Behavior

GLIDE automatically reconnects on connection loss. No application code is needed to trigger reconnection.

### Automatic Reconnection Process

1. Connection loss is detected (via disconnect notifier or failed request)
2. The connection state transitions to `Reconnecting`
3. Exponential backoff with jitter begins
4. Permanent errors (auth failures, invalid config, NOAUTH, WRONGPASS) are not retried
5. Transient errors are retried with increasing delays
6. On successful reconnect, the connection state transitions to `Connected`
7. PubSub channels are automatically resubscribed

### BackoffStrategy Configuration

The reconnection delay follows this formula:

```
delay = rand(0 .. factor * (exponent_base ^ attempt))
```

Once the maximum delay is reached (after `num_of_retries` increasing steps), the delay stays at that ceiling until reconnection succeeds.

```python
from glide import BackoffStrategy, GlideClientConfiguration, NodeAddress

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    reconnect_strategy=BackoffStrategy(
        num_of_retries=5,      # Number of increasing-duration retries
        factor=100,            # Base factor in milliseconds
        exponent_base=2,       # Exponential base
    ),
)
# Delays: rand(0..100), rand(0..200), rand(0..400), rand(0..800), rand(0..1600)
# After 5 retries: stays at rand(0..1600) until reconnection succeeds
```

The Rust core `ConnectionRetryStrategy` struct also supports a `jitter_percent` field as part of the rand() calculation for additional randomization.

### Default Behavior

When no `BackoffStrategy` is configured, GLIDE uses `RetryStrategy::default()` from the underlying redis crate. The defaults provide reasonable reconnection behavior for most workloads.

---

## PubSub Auto-Resubscription

When a PubSub subscriber reconnects, GLIDE automatically resubscribes to all configured channels:

- Exact subscriptions (SUBSCRIBE)
- Pattern subscriptions (PSUBSCRIBE)
- Sharded subscriptions (SSUBSCRIBE)

This applies to both static subscriptions (configured at client creation) and dynamic subscriptions (added via `subscribe()`/`unsubscribe()` in GLIDE 2.3+).

The reconnection check interval is 3 seconds (`CONNECTION_CHECKS_INTERVAL` in `glide-core/src/client/mod.rs`). This interval is not user-configurable to prevent misconfiguration that could degrade PubSub resiliency.

---

## Java Best Practice: Timed Gets

Always use `.get(timeout, TimeUnit.MILLISECONDS)` in Java - never bare `.get()`. This prevents indefinite blocking if the connection encounters issues. Wrap with exponential backoff and jitter for production resilience.

### Additional Error Types

| Error | Recovery |
|-------|----------|
| `ClosingError` | Create new client |
| `RequestException: inflight requests` | Back off, reduce concurrency |
| `AllConnectionsUnavailable` | Check cluster health, increase connectionTimeout |

---

## Common Error Scenarios

### Timeout Tuning

The default request timeout is 250ms. For timeout configuration, workload-specific recommendations, and blocking command timeout extension, see the Timeout Configuration section in `production.md`.

If you see frequent `TimeoutError`:

1. Check if the server is overloaded (`INFO` command, `commandstats`)
2. Check network latency between client and server
3. Increase `request_timeout` in client configuration for operations that legitimately take longer

### Connection Errors During Failover

During cluster failover, you may see a burst of `ConnectionError` exceptions. This is expected. GLIDE will:
1. Detect the topology change
2. Refresh the slot map
3. Re-route commands to the new primary

Application code should retry failed operations. The retry window during failover is typically 1-5 seconds.

### ExecAbortError in Transactions

Atomic batches with `WATCH` will fail with `ExecAbortError` if the watched key is modified between WATCH and EXEC. Implement retry logic:

```python
for attempt in range(3):
    try:
        result = await client.exec(tx, raise_on_error=True)
        break
    except ExecAbortError:
        if attempt == 2:
            raise
        # Rebuild the transaction and retry
```
