# Error Handling

Use when implementing error handling, retry logic, or batch error semantics in the GLIDE Python client.

## Contents

- Error Types (line 15)
- Basic Error Handling (line 42)
- Batch Error Handling (line 69)
- Reconnection Behavior (line 125)
- Failover and Timeout (line 149)

---

## Error Types

GLIDE defines its own `TimeoutError` and `ConnectionError` classes that shadow Python built-ins when imported directly. Always import with explicit aliases:

```python
from glide import (
    GlideClient,
    GlideError,
    TimeoutError as GlideTimeoutError,
    ConnectionError as GlideConnectionError,
    RequestError,
    ExecAbortError,
    ConfigurationError,
    ClosingError,
)
```

| Error | Parent | When It Occurs |
|-------|--------|---------------|
| `GlideError` | `Exception` | Base class for all GLIDE errors |
| `RequestError` | `GlideError` | Base class for server/protocol errors |
| `GlideTimeoutError` | `RequestError` | Request exceeded `request_timeout` (default 250ms) |
| `GlideConnectionError` | `RequestError` | Connection lost (auto-reconnects) |
| `ExecAbortError` | `RequestError` | Atomic batch aborted by server (e.g., command error in MULTI) |
| `ConfigurationError` | `RequestError` | Invalid configuration (TLS, PubSub, compression) |
| `ClosingError` | `GlideError` | Client was closed while requests pending |

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

## Reconnection Behavior

GLIDE reconnects automatically on connection loss with exponential backoff:

```python
from glide import BackoffStrategy, GlideClientConfiguration, NodeAddress

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    reconnect_strategy=BackoffStrategy(
        num_of_retries=5,
        factor=100,          # 100ms base delay
        exponent_base=2,
    ),
)
```

- Delay formula: `rand(0 ... factor * (exponent_base ^ attempt))`
- After `num_of_retries`, delay stays at the ceiling indefinitely
- PubSub channels are automatically resubscribed on reconnect
- Permanent errors (NOAUTH, WRONGPASS) are not retried

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
