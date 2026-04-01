# Info Callbacks - Custom INFO Sections and Server Info Queries

Use when publishing custom metrics via the INFO command, adding crash-report diagnostics, or querying existing server INFO fields from within a module.

Source: `src/module.c` (lines 10779-11041), `src/valkeymodule.h` (lines 865-870, 1846-1884), `tests/modules/infotest.c`

## Contents

- [Overview](#overview)
- [Registering an Info Callback](#registering-an-info-callback)
- [Publishing Custom Sections](#publishing-custom-sections)
- [Adding Fields](#adding-fields)
- [Dictionary Fields](#dictionary-fields)
- [Crash Report Sections](#crash-report-sections)
- [Querying Server Info](#querying-server-info)
- [Field Accessor Variants](#field-accessor-variants)

---

## Overview

The info callback API serves two distinct use cases:

1. **Publishing** - register a callback that the server invokes when a client runs `INFO`. The callback adds custom sections and fields that appear alongside built-in server info.
2. **Querying** - call `GetServerInfo` to snapshot the server's current INFO output and extract individual fields by name.

These are independent APIs. A module can use either or both.

## Registering an Info Callback

```c
typedef void (*ValkeyModuleInfoFunc)(ValkeyModuleInfoCtx *ctx, int for_crash_report);

int ValkeyModule_RegisterInfoFunc(ValkeyModuleCtx *ctx, ValkeyModuleInfoFunc cb);
```

Register during `OnLoad`. The callback receives a `ValkeyModuleInfoCtx` used to add sections and fields, plus a `for_crash_report` flag indicating whether the server is generating a crash log rather than responding to a client `INFO` command.

Returns `VALKEYMODULE_OK` on success.

```c
void MyInfoCallback(ValkeyModuleInfoCtx *ctx, int for_crash_report) {
    ValkeyModule_InfoAddSection(ctx, "stats");
    ValkeyModule_InfoAddFieldLongLong(ctx, "requests_processed", total_requests);
    ValkeyModule_InfoAddFieldDouble(ctx, "avg_latency_ms", avg_latency);
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    /* ... Init ... */
    if (ValkeyModule_RegisterInfoFunc(ctx, MyInfoCallback) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;
    return VALKEYMODULE_OK;
}
```

## Publishing Custom Sections

```c
int ValkeyModule_InfoAddSection(ValkeyModuleInfoCtx *ctx, const char *name);
```

Starts a new section. The section name is automatically prefixed with the module name. Pass `NULL` or `""` for the default section (just the module name with no suffix).

Section names must contain only `A-Z`, `a-z`, `0-9`. The output appears as a standard INFO header:

```
# mymodule_stats
mymodule_requests_processed:42
mymodule_avg_latency_ms:1.23
```

Returns `VALKEYMODULE_OK` if the section should be emitted, or `VALKEYMODULE_ERR` if the client requested a specific section that does not match this one. When `VALKEYMODULE_ERR` is returned, subsequent field-add calls are silently skipped (they check `in_section` internally) - so the callback can safely continue without branching.

A module can add multiple sections in one callback:

```c
void MyInfoCallback(ValkeyModuleInfoCtx *ctx, int for_crash_report) {
    ValkeyModule_InfoAddSection(ctx, "");  /* default: # mymodule */
    ValkeyModule_InfoAddFieldLongLong(ctx, "version", 1);

    ValkeyModule_InfoAddSection(ctx, "stats");  /* # mymodule_stats */
    ValkeyModule_InfoAddFieldLongLong(ctx, "hits", cache_hits);
    ValkeyModule_InfoAddFieldLongLong(ctx, "misses", cache_misses);
}
```

## Adding Fields

All field-add functions follow the same pattern: they require an active section (started by `InfoAddSection`), automatically prefix the field name with the module name, and return `VALKEYMODULE_ERR` if no section is active.

Field names and values must not contain `\r\n` or `:`.

```c
int ValkeyModule_InfoAddFieldString(ValkeyModuleInfoCtx *ctx,
                                    const char *field,
                                    ValkeyModuleString *value);
```

Adds a field from a `ValkeyModuleString`. Use when the value is already a module string object.

```c
int ValkeyModule_InfoAddFieldCString(ValkeyModuleInfoCtx *ctx,
                                     const char *field,
                                     const char *value);
```

Adds a field from a null-terminated C string. The most convenient variant for static or stack-allocated strings.

```c
int ValkeyModule_InfoAddFieldDouble(ValkeyModuleInfoCtx *ctx,
                                    const char *field,
                                    double value);
```

Adds a double-precision floating point field. Formatted with `%.17g` for full precision.

```c
int ValkeyModule_InfoAddFieldLongLong(ValkeyModuleInfoCtx *ctx,
                                      const char *field,
                                      long long value);
```

Adds a signed 64-bit integer field.

```c
int ValkeyModule_InfoAddFieldULongLong(ValkeyModuleInfoCtx *ctx,
                                       const char *field,
                                       unsigned long long value);
```

Adds an unsigned 64-bit integer field. Use for counters that may exceed `LLONG_MAX`.

Example combining multiple field types:

```c
ValkeyModule_InfoAddSection(ctx, "memory");
ValkeyModule_InfoAddFieldULongLong(ctx, "used_bytes", mem_used);
ValkeyModule_InfoAddFieldDouble(ctx, "fragmentation_ratio", frag_ratio);
ValkeyModule_InfoAddFieldCString(ctx, "allocator", "jemalloc");
```

## Dictionary Fields

Dictionary fields group related sub-fields on a single line, similar to `INFO KEYSPACE` output (`db0:keys=3,expires=1`).

```c
int ValkeyModule_InfoBeginDictField(ValkeyModuleInfoCtx *ctx, const char *name);
int ValkeyModule_InfoEndDictField(ValkeyModuleInfoCtx *ctx);
```

Between `BeginDictField` and `EndDictField`, the same `InfoAddField*` functions are used but they emit comma-separated `key=value` pairs instead of separate lines. Field names inside a dict are not prefixed with the module name.

```c
ValkeyModule_InfoAddSection(ctx, "keyspace");
ValkeyModule_InfoBeginDictField(ctx, "db0");
ValkeyModule_InfoAddFieldLongLong(ctx, "keys", 3);
ValkeyModule_InfoAddFieldLongLong(ctx, "expires", 1);
ValkeyModule_InfoEndDictField(ctx);
```

Output:

```
# mymodule_keyspace
mymodule_db0:keys=3,expires=1
```

If `EndDictField` is not called, the server implicitly closes the dict when the next section starts or the callback returns. However, explicitly ending each dict is recommended for clarity.

Nested dicts are not supported. Calling `BeginDictField` while already inside a dict implicitly ends the previous one.

## Crash Report Sections

The `for_crash_report` parameter is 1 when the server is generating a crash log (e.g., after a segfault). Use this to add diagnostic information that is only relevant in crash reports and should not appear in normal `INFO` output:

```c
void MyInfoCallback(ValkeyModuleInfoCtx *ctx, int for_crash_report) {
    ValkeyModule_InfoAddSection(ctx, "stats");
    ValkeyModule_InfoAddFieldLongLong(ctx, "active_ops", active_count);

    if (for_crash_report) {
        ValkeyModule_InfoAddSection(ctx, "debug");
        ValkeyModule_InfoAddFieldCString(ctx, "last_error", last_error_msg);
        ValkeyModule_InfoAddFieldLongLong(ctx, "error_count", error_count);
    }
}
```

The crash report callback runs in a signal handler context. Keep the logic simple - avoid allocations or operations that could deadlock.

## Querying Server Info

Use `GetServerInfo` to read the server's own INFO output from within a module.

```c
ValkeyModuleServerInfoData *ValkeyModule_GetServerInfo(ValkeyModuleCtx *ctx,
                                                       const char *section);
```

Takes an optional section name (e.g., `"server"`, `"memory"`, `"replication"`). Pass `NULL` to retrieve all sections. Returns a handle used with the `ServerInfoGetField*` accessors.

If `ctx` is non-NULL, the result is tracked by auto-memory management. Otherwise, the caller must free it explicitly.

```c
void ValkeyModule_FreeServerInfo(ValkeyModuleCtx *ctx,
                                 ValkeyModuleServerInfoData *data);
```

Frees the server info snapshot. Pass the same `ctx` used in `GetServerInfo`, or `NULL` if `NULL` was passed originally.

Complete example - reading memory info to make a decision:

```c
ValkeyModuleServerInfoData *info = ValkeyModule_GetServerInfo(ctx, "memory");
int err;
long long used = ValkeyModule_ServerInfoGetFieldSigned(info, "used_memory", &err);
if (err == VALKEYMODULE_OK && used > threshold) {
    /* trigger eviction or throttle */
}
ValkeyModule_FreeServerInfo(ctx, info);
```

## Field Accessor Variants

Five accessors extract individual fields from a `ValkeyModuleServerInfoData` snapshot. Field names use the exact keys from INFO output (e.g., `"used_memory"`, `"redis_version"`, `"connected_clients"`).

```c
ValkeyModuleString *ValkeyModule_ServerInfoGetField(ValkeyModuleCtx *ctx,
                                                    ValkeyModuleServerInfoData *data,
                                                    const char *field);
```

Returns the field value as a `ValkeyModuleString`, or `NULL` if the field was not found. If `ctx` is non-NULL, the string is auto-memory managed. Otherwise, free it with `ValkeyModule_FreeString`.

```c
const char *ValkeyModule_ServerInfoGetFieldC(ValkeyModuleServerInfoData *data,
                                             const char *field);
```

Returns the field value as a `const char *` pointing into the info data structure. Returns `NULL` if not found. The pointer is valid until `FreeServerInfo` is called. This variant does not require a context.

```c
long long ValkeyModule_ServerInfoGetFieldSigned(ValkeyModuleServerInfoData *data,
                                                const char *field,
                                                int *out_err);
```

Parses the field as a signed 64-bit integer. Returns 0 and sets `*out_err` to `VALKEYMODULE_ERR` if the field is missing or not numeric. Sets `*out_err` to `VALKEYMODULE_OK` on success. The `out_err` pointer may be `NULL`.

```c
unsigned long long ValkeyModule_ServerInfoGetFieldUnsigned(ValkeyModuleServerInfoData *data,
                                                           const char *field,
                                                           int *out_err);
```

Same as `ServerInfoGetFieldSigned` but returns an unsigned value.

```c
double ValkeyModule_ServerInfoGetFieldDouble(ValkeyModuleServerInfoData *data,
                                             const char *field,
                                             int *out_err);
```

Parses the field as a double. Same error semantics as the integer variants.

Example using multiple accessor types:

```c
ValkeyModuleServerInfoData *info = ValkeyModule_GetServerInfo(ctx, "server");
int err;

const char *version = ValkeyModule_ServerInfoGetFieldC(info, "redis_version");
long long uptime = ValkeyModule_ServerInfoGetFieldSigned(info, "uptime_in_seconds", &err);
unsigned long long clients = ValkeyModule_ServerInfoGetFieldUnsigned(
    info, "connected_clients", &err);

ValkeyModule_Log(ctx, "notice", "Server %s, up %lld sec, %llu clients",
    version ? version : "unknown", uptime, clients);

ValkeyModule_FreeServerInfo(ctx, info);
```

## See Also

- [module-configs.md](module-configs.md) - Module configuration parameters exposed via CONFIG
- [fork.md](fork.md) - Fork heartbeat progress visible in INFO persistence
- [../lifecycle/server-info.md](../lifecycle/server-info.md) - Server version, time, database selection, and utility APIs
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - OnLoad where RegisterInfoFunc is typically called
- [../testing.md](../testing.md) - Using getInfoProperty in Tcl tests to verify INFO fields
