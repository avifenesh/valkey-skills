# Error Handling (Java)

Use for retry logic and batch error semantics. Covers GLIDE-specific divergence from Jedis (`JedisException` hierarchy) and Lettuce (`RedisException` / `RedisCommandExecutionException`).

## Hierarchy - FLAT under GlideException

All errors extend `GlideException extends RuntimeException` directly. No multi-level subclass tree (unlike Python's `ValkeyError -> RequestError -> TimeoutError/etc.`).

```
GlideException extends RuntimeException         # concrete base; catch-all
├── ClosingException             # client closed while requests pending
├── ConnectionException          # network / connection issue (temporary - auto-reconnecting)
├── ConfigurationError           # invalid config (note "Error" suffix - inconsistent with others)
├── ExecAbortException           # atomic batch aborted (WATCH conflict)
├── RequestException             # server-side / protocol error (WRONGTYPE, OOM, etc.)
└── TimeoutException             # GLIDE request timeout
```

All 6 direct children are siblings at the same level. `catch (GlideException e)` catches all of them. Subclass checks are independent `instanceof` tests.

**Gotcha**: `java.util.concurrent.TimeoutException` vs GLIDE's `TimeoutException` - two different classes with the same simple name. `.get(n, TimeUnit.MILLISECONDS)` throws the former if the future doesn't complete within `n` ms; GLIDE's internal request timeout surfaces as the latter wrapped in `ExecutionException`. Always fully-qualify or import with aliases.

## Unwrap pattern

Every command returns `CompletableFuture<T>`. Errors from the server come back inside `ExecutionException` when you call `.get()`:

| Error kind | When it occurs |
|-----------|----------------|
| `RequestException` | Server / protocol errors - WRONGTYPE, OOM, NOAUTH, etc. |
| `TimeoutException` (GLIDE) | Request exceeded `requestTimeout` (default 250 ms) |
| `ConnectionException` | Connection lost. Auto-reconnect in progress. |
| `ExecAbortException` | Atomic batch aborted (WATCH key changed) |
| `ClosingException` | Client was closed while requests pending - create a new client |
| `ConfigurationError` | Invalid config (TLS mismatch, RESP2+PubSub) |

## Basic Error Handling

```java
import glide.api.GlideClient;
import glide.api.models.exceptions.*;

try {
    String value = client.get("key").get(500, TimeUnit.MILLISECONDS);
} catch (java.util.concurrent.TimeoutException e) {
    // Future.get() timed out - separate from GLIDE's internal TimeoutException
} catch (ExecutionException e) {
    Throwable cause = e.getCause();
    if (cause instanceof RequestException) {
        System.err.println("Request failed: " + cause.getMessage());
    } else if (cause instanceof ConnectionException) {
        // Connection lost - GLIDE is reconnecting automatically
        // Retry the operation
    }
}
```

Always use `.get(timeout, TimeUnit)` - never bare `.get()`. Bare `.get()` blocks indefinitely if the connection encounters issues.

---

## Batch Error Handling

The `raiseOnError` parameter on `client.exec()` controls how batch errors surface:

### raiseOnError = true

Throws on the first error. Use when all commands must succeed.

```java
import glide.api.models.Batch;

Batch batch = new Batch(true).set("key", "val").get("key");
try {
    Object[] results = client.exec(batch, true).get(5000, TimeUnit.MILLISECONDS);
} catch (ExecutionException e) {
    if (e.getCause() instanceof RequestException) {
        System.err.println("Batch failed: " + e.getCause().getMessage());
    }
}
```

### raiseOnError = false

Errors appear inline in the result array. Use for partial-success workloads.

```java
Batch batch = new Batch(false)
    .set("key", "value")
    .lpush("key", new String[]{"oops"})  // WRONGTYPE error
    .get("key");

Object[] results = client.exec(batch, false).get(5000, TimeUnit.MILLISECONDS);
for (int i = 0; i < results.length; i++) {
    if (results[i] instanceof RequestException) {
        System.out.println("Command " + i + " failed: " + results[i]);
    } else {
        System.out.println("Command " + i + " OK: " + results[i]);
    }
}
```

### ExecAbortException

Atomic batches with WATCH throw `ExecAbortException` if a watched key was modified:

```java
for (int attempt = 0; attempt < 3; attempt++) {
    try {
        Object[] results = client.exec(batch, true).get(5000, TimeUnit.MILLISECONDS);
        break;
    } catch (ExecutionException e) {
        if (e.getCause() instanceof ExecAbortException && attempt < 2) {
            // Rebuild the batch and retry
            continue;
        }
        throw e;
    }
}
```

---

## Reconnection Behavior

GLIDE reconnects automatically on connection loss with exponential backoff:

```java
import glide.api.models.configuration.*;

BackoffStrategy strategy = BackoffStrategy.builder()
    .numOfRetries(5)
    .factor(100)          // 100ms base delay
    .exponentBase(2)
    .jitterPercent(20)
    .build();

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .reconnectStrategy(strategy)
    .build();
```

- Delay formula: `rand(0 ... factor * (exponentBase ^ attempt))`
- After `numOfRetries`, delay stays at the ceiling indefinitely
- PubSub channels are automatically resubscribed on reconnect
- Permanent errors (NOAUTH, WRONGPASS) are not retried

---

## Failover and Timeout

During cluster failover, expect `ConnectionException` bursts for 1-5 seconds. GLIDE refreshes the slot map and re-routes automatically. Retry failed operations.

Frequent timeouts indicate server load - verify before increasing timeout:

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .requestTimeout(1000)  // ms, default 250
    .build();
```

GLIDE auto-extends timeouts for blocking commands (BLPOP, XREADGROUP BLOCK) by 500ms beyond the block duration.

Other errors: `ClosingException` (create new client), `RequestException: inflight requests` (back off, reduce concurrency).
