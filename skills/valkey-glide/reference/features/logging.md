# Logging

Use when debugging connection issues, timeout problems, cluster routing, or any operational issue with the GLIDE client. For structured observability with distributed tracing and metrics export, see [OpenTelemetry](opentelemetry.md) instead.

GLIDE provides a unified logging system powered by a Rust core (`logger_core` crate) with language-specific wrapper classes. All language clients produce logs in the same format and support the same log levels, making cross-language debugging consistent.

## Architecture

The logging stack is:

1. **Rust core** (`logger_core` crate) - uses the `tracing` crate with reloadable filter layers
2. **Language wrappers** - `Logger` class in Python, Java, and Node.js; Go uses the core directly
3. **Output targets** - console (stdout) or rolling log files

The Rust core initializes a global tracing subscriber with two reloadable layers: one for console output and one for file output. Only one target is active at a time - providing a file name switches to file output and disables console, and vice versa.

## Log Levels

| Level | Value | Description |
|-------|-------|-------------|
| Error | 0 | Critical failures that prevent operations |
| Warn | 1 | Unexpected situations that may affect behavior |
| Info | 2 | Notable operational events (connections, reconnections) |
| Debug | 3 | Detailed operational information |
| Trace | 4 | Very fine-grained execution details |
| Off | 5 | Disable all logging |

The logger filters out all messages with a level higher (less severe) than the configured threshold. Setting level to Info shows Error, Warn, and Info messages.

## Logger Singleton

The Logger is a singleton across all language wrappers. It can be initialized in two ways:

1. **`init(level, fileName)`** - Configures the logger only if it has not been previously configured. Safe to call multiple times.
2. **`setLoggerConfig(level, fileName)`** - Replaces the existing configuration. Previous log output remains, but new logs go to the new target/level.

If neither is called before the first log attempt, a default logger is automatically created with Warn level writing to console.

## Python

```python
from glide import Logger, Level

# Initialize to console at Info level
Logger.init(Level.INFO)

# Initialize to file
Logger.init(Level.DEBUG, "glide-client.log")

# Log a message
Logger.log(Level.INFO, "my-app", "Connected to cluster")

# Log with exception
try:
    await client.get("key")
except Exception as e:
    Logger.log(Level.ERROR, "my-app", "Failed to get key", e)

# Replace logger configuration at runtime
Logger.set_logger_config(Level.TRACE, "debug-session.log")
```

### Python Level Enum

```python
from glide import Level

Level.ERROR   # Only errors
Level.WARN    # Errors and warnings
Level.INFO    # General operational info
Level.DEBUG   # Detailed debug output
Level.TRACE   # Everything
Level.OFF     # Disable logging
```

## Java

```java
import glide.api.logging.Logger;
import static glide.api.logging.Logger.Level.*;

// Initialize to console at Info level
Logger.init(INFO);

// Initialize to file
Logger.init(INFO, "glide-client.log");

// Initialize with defaults (Warn level, console)
Logger.init();

// Log a message
Logger.log(INFO, "my-app", "Connected to cluster");

// Log with exception
Logger.log(ERROR, "my-app", "Connection failed", exception);

// Lazy message construction (avoids string building when level is filtered)
Logger.log(DEBUG, "my-app", () -> "Processing " + count + " items");

// Replace configuration
Logger.setLoggerConfig(TRACE, "debug-session.log");
Logger.setLoggerConfig(INFO);  // Switch back to console
```

### Java Level Enum

```java
Logger.Level.DEFAULT  // -1, let Glide core decide
Logger.Level.ERROR    // 0
Logger.Level.WARN     // 1
Logger.Level.INFO     // 2
Logger.Level.DEBUG    // 3
Logger.Level.TRACE    // 4
Logger.Level.OFF      // 5
```

Java also provides `Level.DEFAULT` which defers to the Rust core's built-in default level.

## Node.js

```typescript
import { Logger } from "@valkey/valkey-glide";

// Initialize to console at Info level
Logger.init("info");

// Initialize to file
Logger.init("debug", "glide-client.log");

// Log a message
Logger.log("info", "my-app", "Connected to cluster");

// Log with error
Logger.log("error", "my-app", "Connection failed", new Error("timeout"));

// Replace configuration
Logger.setLoggerConfig("trace", "debug-session.log");
```

### Node.js Level Options

Level options are lowercase strings: `"error"`, `"warn"`, `"info"`, `"debug"`, `"trace"`, `"off"`.

## File Logging

When a file name is provided, logs are written to rolling files in a `glide-logs/` directory (or the directory specified by `GLIDE_LOG_DIR`).

### File Rotation

The Rust core uses `tracing-appender` with hourly rotation. Log files are named with the provided file name as a prefix and a timestamp suffix. Old files are not automatically cleaned up.

### Default Log Directory

| Priority | Source | Path |
|----------|--------|------|
| 1 | `GLIDE_LOG_DIR` environment variable | Custom directory |
| 2 | Default | `glide-logs/` relative to working directory |

The directory is created automatically if it does not exist. If the directory cannot be created (e.g., read-only filesystem), file logging initialization is deferred using a lazy appender - it will attempt to create the directory on the first actual log write.

## Environment Variables

| Variable | Effect |
|----------|--------|
| `GLIDE_LOG_DIR` | Override the directory where log files are written |
| `RUST_LOG` | Set the maximum log level for the Rust core's target filter. Accepts tracing level names: `trace`, `debug`, `info`, `warn`, `error`. If invalid, defaults to `trace`. |

The `RUST_LOG` variable controls the target filter ceiling - it sets the maximum level that the logger infrastructure will pass through. The level set via `init()` or `setLoggerConfig()` acts as the output filter. Both must allow a message for it to appear.

## Target Filtering

The Rust core applies a target filter that only passes logs from specific crate names:

- `glide`
- `redis`
- `logger_core`
- The crate name of the native binding (`valkey_glide`, `glide_rs`, etc.)

Logs from other Rust crates (third-party dependencies) are filtered out regardless of level.

## What Gets Logged at Each Level

### Error
- Connection failures after all retries exhausted
- Protocol errors and invalid server responses
- Internal panics and critical state corruption

### Warn
- Connection drops and reconnection attempts
- Cluster topology changes
- Command timeouts
- Configuration validation issues

### Info
- Client creation and shutdown
- Initial cluster topology discovery
- Successful reconnection events
- Subscription state changes

### Debug
- Individual command execution details
- Connection state changes (per-node multiplexed connections)
- Cluster slot refresh operations
- Compression decisions (skipped vs compressed)

### Trace
- Raw protocol bytes sent and received
- Every internal state machine transition
- Timer and timeout tracking
- Detailed retry logic execution

## Debugging Common Issues

### Connection Problems

```python
# Enable Debug to see connection attempts and failures
Logger.init(Level.DEBUG, "connection-debug.log")
```

Look for patterns like:
- Repeated "reconnecting" messages indicate unstable network
- "topology changed" at Info level shows cluster rebalancing
- Error-level "connection refused" means the server is down or address is wrong

### Timeout Issues

```java
// Trace shows exact timing of command lifecycle
Logger.init(Logger.Level.TRACE, "timeout-debug.log");
```

At Trace level, you can see when commands are sent and when responses arrive, helping identify whether timeouts are caused by slow server responses or client-side queueing.

### Cluster Routing

```typescript
Logger.init("debug", "cluster-debug.log");
```

Debug level logs show slot-to-node mapping and command routing decisions, useful for diagnosing MOVED/ASK redirect storms.

## Log Format

Log lines include:
- Timestamp
- Log level
- Log identifier (the context string passed by the caller)
- Message

Example output:
```
2025-01-15T10:30:45.123Z INFO glide - my-app - Connected to cluster with 3 nodes
2025-01-15T10:30:45.456Z DEBUG glide - connection - Slot 5461 mapped to node 10.0.1.2:6379
```

## Resource Tracking via Statistics

GLIDE provides `getStatistics()` / `get_statistics()` for tracking client resource usage alongside logging:

```python
stats = await client.get_statistics()
print(f"Total Connections: {stats['total_connections']}")
print(f"Total Clients: {stats['total_clients']}")
```

When compression is enabled, statistics also include compression metrics (`total_values_compressed`, `total_original_bytes`, `total_bytes_compressed`). Combine logging with statistics for comprehensive operational visibility.

## Performance Considerations

- Use the appropriate log level for production. Warn or Error is recommended - Debug and Trace generate high log volume.
- Java's `Supplier<String>` overload avoids constructing log messages that will be filtered out.
- The logger checks the level before formatting, so disabled levels have minimal overhead.
- File logging with hourly rotation can accumulate large files under Trace level. Monitor disk usage or set up external log rotation.

## Related Features

- [OpenTelemetry](opentelemetry.md) - structured observability with distributed tracing and metrics export; complements logging for production monitoring
- [Compression](compression.md) - when compression is enabled, statistics include compression metrics accessible via `getStatistics()`
