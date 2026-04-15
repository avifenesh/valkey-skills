# Advanced Features

Use when you need Lua scripting, cluster SCAN, command routing, OpenTelemetry observability, logging, or custom commands in the Python GLIDE client.

## Lua Scripting

The `Script` class manages script loading and invocation. Scripts are loaded once via SCRIPT LOAD and invoked via EVALSHA automatically.

```python
from glide import Script

# Create a script (loaded on first invocation)
lua_script = Script("return { KEYS[1], ARGV[1] }")

# Standalone client
result = await client.invoke_script(lua_script, keys=["foo"], args=["bar"])
# result: [b"foo", b"bar"]

# Cluster client - keys must map to same hash slot
result = await client.invoke_script(lua_script, keys=["{app}.key1"], args=["val"])
```

Cluster client also supports `invoke_script_route` for keyless scripts with explicit routing:

```python
from glide import AllPrimaries

lua_no_keys = Script("return 'hello'")
result = await client.invoke_script_route(lua_no_keys, args=[], route=AllPrimaries())
```

Kill a running script:

```python
await client.script_kill()

# Cluster: optionally route to specific nodes
await client.script_kill(route=AllPrimaries())
```

Check if scripts exist in the cache and flush:

```python
from glide import FlushMode

exists = await client.script_exists(["sha1_digest1", "sha1_digest2"])
# [True, False]

await client.script_flush()              # synchronous flush
await client.script_flush(FlushMode.ASYNC)  # asynchronous flush
```

## Cluster SCAN

GLIDE provides a cluster-aware SCAN that iterates across all nodes automatically.

```python
from glide import ClusterScanCursor, ObjectType

cursor = ClusterScanCursor()
all_keys = []

while not cursor.is_finished():
    cursor, keys = await client.scan(cursor, match="user:*", count=100)
    all_keys.extend(keys)

# Filter by type
cursor = ClusterScanCursor()
while not cursor.is_finished():
    cursor, keys = await client.scan(
        cursor,
        match="*",
        count=100,
        type=ObjectType.STRING,
    )
    all_keys.extend(keys)

# Allow scanning even if some slots are not covered
cursor = ClusterScanCursor()
cursor, keys = await client.scan(cursor, allow_non_covered_slots=True)
```

Always use the returned cursor for the next iteration - reusing a cursor produces duplicate or unexpected results.

### Standalone SCAN

```python
from glide import ObjectType

cursor = "0"
all_keys = []

while True:
    result = await client.scan(cursor, match="session:*", count=100)
    cursor = result[0]       # next cursor (bytes)
    keys = result[1]         # list of keys (List[bytes])
    all_keys.extend(keys)
    if cursor == b"0":
        break

# Filter by type
result = await client.scan("0", match="*", count=50, type=ObjectType.HASH)
```

## Routing and Custom Commands (Cluster)

```python
from glide import AllNodes, AllPrimaries, RandomNode, SlotKeyRoute, SlotType, SlotIdRoute, ByAddressRoute

info = await client.info(route=AllNodes())
result = await client.custom_command(["DBSIZE"], route=RandomNode())
result = await client.custom_command(
    ["DEBUG", "OBJECT", "mykey"], route=SlotKeyRoute(SlotType.PRIMARY, "mykey"),
)
result = await client.custom_command(
    ["CLUSTER", "COUNTKEYSINSLOT", "42"], route=SlotIdRoute(SlotType.PRIMARY, 42),
)
result = await client.custom_command(["CLIENT", "LIST"], route=ByAddressRoute("10.0.0.5", 6379))
```

## OpenTelemetry

Initialize once at application startup. Traces and metrics are exported via OTLP/HTTP.

```python
from glide import (
    OpenTelemetry, OpenTelemetryConfig,
    OpenTelemetryTracesConfig, OpenTelemetryMetricsConfig,
)

OpenTelemetry.init(OpenTelemetryConfig(
    traces=OpenTelemetryTracesConfig(
        endpoint="http://localhost:4318/v1/traces",
        sample_percentage=10,
    ),
    metrics=OpenTelemetryMetricsConfig(
        endpoint="http://localhost:4318/v1/metrics",
    ),
    flush_interval_ms=1000,   # default: 5000
))
```

Runtime sampling control:

```python
# Adjust sample percentage without reinitializing
OpenTelemetry.set_sample_percentage(50)

# Check current state
pct = OpenTelemetry.get_sample_percentage()
is_init = OpenTelemetry.is_initialized()
```

OpenTelemetry can only be initialized once per process. Subsequent calls to `init()` are ignored.

## Logging

```python
from glide import Logger, LogLevel

# Initialize logger (only configures if not already set)
Logger.init(LogLevel.INFO)
Logger.init(LogLevel.DEBUG, "glide-app")  # log to file

# Replace existing logger configuration
Logger.set_logger_config(LogLevel.INFO)

# Log from application code
Logger.log(LogLevel.WARN, "my-component", "something unexpected happened")

# Log with exception context
try:
    await client.get("key")
except Exception as e:
    Logger.log(LogLevel.ERROR, "my-component", "request failed", err=e)
```

Log levels: `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE`, `OFF`.

## Error Types

| Exception | When |
|-----------|------|
| `GlideError` | Base class for all GLIDE errors |
| `ClosingError` | Client is closed or connection lost |
| `ConfigurationError` | Invalid configuration (TLS, PubSub, compression) |
| `ConnectionError` | Network or connection issues |
| `RequestError` | Command execution failure |
| `TimeoutError` | Request or subscription timeout |
| `ExecAbortError` | Transaction aborted (e.g., type mismatch) |
