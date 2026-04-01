# Logging - Log, LogIOError, and LatencyAddSample

Use when emitting log messages from a module, logging errors during RDB/AOF serialization, reporting latency samples, or using module assertions.

Source: `src/module.c` (lines 7903-7989), `src/valkeymodule.h` (lines 291-295)

## Contents

- ValkeyModule_Log (line 20)
- Log Levels (line 49)
- ValkeyModule_LogIOError (line 71)
- ValkeyModule_Assert (line 102)
- ValkeyModule_LatencyAddSample (line 122)
- Output Format (line 147)
- Practical Patterns (line 158)

---

## ValkeyModule_Log

The primary logging function for modules. Writes to the standard server log with a module name prefix:

```c
void ValkeyModule_Log(ValkeyModuleCtx *ctx,
                      const char *levelstr,
                      const char *fmt, ...);
```

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context, or NULL if unavailable (threads, callbacks) |
| `levelstr` | Log level string (see table below) |
| `fmt` | printf-style format string |
| `...` | Format arguments |

When `ctx` is NULL, the log message uses a generic `<module>` prefix instead of the module name. This is safe to call from background threads or contexts where no `ValkeyModuleCtx` is available.

The internal implementation (`moduleLogRaw`) formats the message as:

```
<modulename> formatted message text
```

There is a fixed maximum log line length (`LOG_MAX_LEN`). The limit is not specified publicly but is large enough for several lines of text.

Messages below the server's configured `loglevel` (verbosity) threshold are silently dropped.

## Log Levels

Four log levels are available, matching the server's own levels:

| Level String | Constant | Numeric | When to Use |
|-------------|----------|---------|-------------|
| `"debug"` | `VALKEYMODULE_LOGLEVEL_DEBUG` | `LL_DEBUG` | Development diagnostics, high-volume tracing |
| `"verbose"` | `VALKEYMODULE_LOGLEVEL_VERBOSE` | `LL_VERBOSE` | Detailed operational information |
| `"notice"` | `VALKEYMODULE_LOGLEVEL_NOTICE` | `LL_NOTICE` | Normal significant events (startup, config) |
| `"warning"` | `VALKEYMODULE_LOGLEVEL_WARNING` | `LL_WARNING` | Errors and critical issues |

If an invalid level string is provided, `"verbose"` is used as the default.

The constants are defined in `src/valkeymodule.h` (lines 291-295):

```c
#define VALKEYMODULE_LOGLEVEL_DEBUG   "debug"
#define VALKEYMODULE_LOGLEVEL_VERBOSE "verbose"
#define VALKEYMODULE_LOGLEVEL_NOTICE  "notice"
#define VALKEYMODULE_LOGLEVEL_WARNING "warning"
```

## ValkeyModule_LogIOError

Specialized logging function for RDB/AOF serialization callbacks:

```c
void ValkeyModule_LogIOError(ValkeyModuleIO *io,
                             const char *levelstr,
                             const char *fmt, ...);
```

| Parameter | Description |
|-----------|-------------|
| `io` | The IO context received in rdb_load/rdb_save callbacks |
| `levelstr` | Log level string (same levels as ValkeyModule_Log) |
| `fmt` | printf-style format string |

Use this instead of `ValkeyModule_Log` inside RDB/AOF callbacks (`rdb_load`, `rdb_save`, `aof_rewrite`) because these callbacks receive a `ValkeyModuleIO *` rather than a `ValkeyModuleCtx *`.

The function extracts the module reference from `io->type->module` to include the correct module name in the log prefix.

```c
void *MyType_RdbLoad(ValkeyModuleIO *io, int encver) {
    if (encver != CURRENT_ENCVER) {
        ValkeyModule_LogIOError(io, "warning",
            "Unsupported encoding version %d", encver);
        return NULL;
    }
    /* ... */
}
```

## ValkeyModule_Assert

Module assertion that integrates with the server's crash reporting:

```c
void ValkeyModule__Assert(const char *estr,
                          const char *file,
                          int line);
```

The macro form is preferred:

```c
ValkeyModule_Assert(expression);
```

A failed assertion shuts down the server and produces logging identical to a native server assertion failure, including the assertion expression, file name, and line number. This integrates with crash reporting, stack traces, and bug report generation.

Use for invariant checks that indicate a programming error if violated. Do not use for conditions that can result from user input or normal operation.

## ValkeyModule_LatencyAddSample

Adds a latency sample to the server's latency monitoring system:

```c
void ValkeyModule_LatencyAddSample(const char *event,
                                   mstime_t latency);
```

| Parameter | Description |
|-----------|-------------|
| `event` | Event name (appears in LATENCY HISTORY output) |
| `latency` | Duration in milliseconds |

The sample is only recorded if the latency equals or exceeds the configured `latency-monitor-threshold`. The millisecond value is passed directly to `latencyAddSampleIfNeeded()`.

This allows module operations to appear in `LATENCY HISTORY <event>` and `LATENCY LATEST` output, helping operators diagnose performance issues.

```c
long long start = ValkeyModule_Milliseconds();
/* perform expensive operation */
long long elapsed = ValkeyModule_Milliseconds() - start;
ValkeyModule_LatencyAddSample("mymodule-expensive-op", elapsed);
```

## Output Format

Log messages from modules appear in the server log with the module name in angle brackets:

```
12345:M 01 Apr 2026 12:00:00.000 * <mymodule> Module loaded successfully
12345:M 01 Apr 2026 12:00:01.500 # <mymodule> Critical error detected
```

The `*` marker corresponds to notice level, `#` to warning, `-` to verbose, and `.` to debug, following the server's standard log format.

## Practical Patterns

Log during module initialization:

```c
int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv, int argc) {
    /* ... init ... */
    ValkeyModule_Log(ctx, "notice",
                     "Module v%d loaded with %d args", VERSION, argc);
    return VALKEYMODULE_OK;
}
```

Log from a background thread (no context available):

```c
void *background_worker(void *arg) {
    /* ctx is NULL - uses generic "<module>" prefix */
    ValkeyModule_Log(NULL, "verbose", "Background task completed");
    return NULL;
}
```

Conditional debug logging:

```c
/* Use debug level for high-frequency diagnostics.
 * These are dropped unless the server loglevel is set to debug. */
ValkeyModule_Log(ctx, "debug",
                 "Processing key %s with %d fields",
                 keyname, nfields);
```
