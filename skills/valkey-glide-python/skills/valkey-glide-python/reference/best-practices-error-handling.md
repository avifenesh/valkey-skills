# Error Handling

Use when implementing error handling, retry logic, or batch error semantics. Covers GLIDE-specific divergence from `redis-py` (which raises `redis.exceptions.ConnectionError`, `TimeoutError`, `ResponseError`, etc.).

## Key gotcha: GLIDE error classes shadow Python built-ins

`GlideError`, `RequestError`, `ClosingError`, `LoggerError` are GLIDE-specific. But `TimeoutError` and `ConnectionError` collide with Python built-ins if imported directly. Always alias:

```python
from glide import (
    GlideError,
    RequestError,
    TimeoutError as GlideTimeoutError,
    ConnectionError as GlideConnectionError,
    ExecAbortError,
    ConfigurationError,
    ClosingError,
)
```

## Hierarchy

```
GlideError                       # base - catches everything
├── ClosingError                 # client closed / unusable
├── LoggerError                  # logger init failure
└── RequestError                 # catches everything below too - most code catches at this level
    ├── TimeoutError             # request exceeded request_timeout (default 250ms)
    ├── ExecAbortError           # server aborted atomic batch (type mismatch in MULTI/EXEC)
    ├── ConnectionError          # network disconnect - GLIDE is already reconnecting; retry after delay
    └── ConfigurationError       # invalid config (TLS, RESP2+PubSub, compression)
```

**Common mistake:** catching `Exception` in redis-py matches `redis.exceptions.RedisError` and subclasses. In GLIDE, `except RequestError:` already catches timeouts, connection errors, and configuration errors - they are subclasses. Catch `GlideError` only if you also need `ClosingError` / `LoggerError`.

## Basic Error Handling

```python
from glide import (
    TimeoutError as GlideTimeoutError,
    ConnectionError as GlideConnectionError,
    RequestError,
)

try:
    value = await client.get("key")
except GlideTimeoutError:
    # Request exceeded request_timeout - check server load or increase timeout
    pass
except GlideConnectionError:
    # Connection lost - GLIDE is already reconnecting
    # Retry the operation after a brief delay
    pass
except RequestError as e:
    # General request failure (WRONGTYPE, auth errors, etc.)
    print(f"Request failed: {e}")
```

`RequestError` covers most command-level failures - catch it after specific subtypes. For the broadest catch-all (including `ClosingError`), use `GlideError`.

---

## Batch Error Handling

The `raise_on_error` parameter on `client.exec()` controls how batch errors surface:

### raise_on_error = True

Raises `RequestError` on the first error. Use when all commands must succeed.

```python
from glide import Batch, RequestError

batch = Batch(is_atomic=True)
batch.set("key", "val")
batch.get("key")
try:
    result = await client.exec(batch, raise_on_error=True)
except RequestError as e:
    print(f"Batch failed: {e}")
```

### raise_on_error = False

Errors appear inline in the result list. Use for partial-success workloads.

```python
from glide import Batch, RequestError

batch = Batch(is_atomic=False)
batch.set("key", "value")
batch.lpush("key", ["oops"])  # WRONGTYPE error
batch.get("key")

result = await client.exec(batch, raise_on_error=False)
for i, item in enumerate(result):
    if isinstance(item, RequestError):
        print(f"Command {i} failed: {item}")
    else:
        print(f"Command {i} OK: {item}")
```

### WATCH Conflicts

Atomic batches with WATCH return `None` from `exec()` if a watched key was modified before EXEC. This is not an exception - check the return value:

```python
for attempt in range(3):
    result = await client.exec(batch, raise_on_error=True)
    if result is not None:
        break
    # result is None - WATCH conflict, rebuild the batch and retry
```

`ExecAbortError` is separate - it occurs when the server aborts a transaction due to command errors (e.g., type mismatch inside MULTI/EXEC).

---

## Reconnection behavior

GLIDE reconnects automatically on connection loss with exponential backoff. Two key differences from redis-py's `retry_on_timeout`:

1. **Reconnection is infinite.** `num_of_retries` caps the backoff sequence length, not the total number of retries. After `num_of_retries` attempts the delay plateaus at the ceiling and the client keeps retrying until close. This is very different from redis-py where retries give up after N attempts.
2. **Permanent errors are only blocked at INITIAL connect.** During reconnection, auth failures and `RESP3NotSupported` will also end up in an error state, but the mid-session classification logic is in the Rust core - callers just see `ConnectionError` until the client is closed or the server recovers.

```python
from glide import BackoffStrategy

BackoffStrategy(num_of_retries=5, factor=100, exponent_base=2, jitter_percent=20)
# Delay formula: rand_jitter * factor * (exponent_base ** attempt), clamped at the ceiling
```

PubSub channels resubscribe automatically on reconnect via the synchronizer on the core side (see the `glide-dev` skill for the reconciliation loop details).

---

## Failover and Timeout

During cluster failover, expect `GlideConnectionError` bursts for 1-5 seconds. GLIDE refreshes the slot map and re-routes automatically. Retry failed operations.

Frequent `GlideTimeoutError` indicates server load - verify before increasing timeout:

```python
config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    request_timeout=1000,  # ms, default 250
)
```

GLIDE auto-extends timeouts for blocking commands (BLPOP, XREADGROUP BLOCK) by 500ms beyond the block duration.
