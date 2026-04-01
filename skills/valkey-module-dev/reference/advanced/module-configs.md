# Module Configurations - Register and Manage Config Parameters

Use when exposing module settings through CONFIG SET/GET/REWRITE, defining typed configuration parameters with validation, or loading startup arguments.

Source: `src/module.c` (lines 13355-13667), `src/valkeymodule.h`

## Contents

- [Overview](#overview)
- [Config Types](#config-types)
- [Config Flags](#config-flags)
- [RegisterStringConfig](#registerstringconfig)
- [RegisterBoolConfig](#registerboolconfig)
- [RegisterNumericConfig](#registernumericconfig)
- [RegisterEnumConfig](#registerenumconfig)
- [LoadConfigs and UpdateRuntimeArgs](#loadconfigs-and-updateruntimeargs)
- [Callback Signatures](#callback-signatures)

---

## Overview

Module configs integrate with the server's CONFIG system. Once registered, they support:

- `CONFIG SET module-name.config-name value` - runtime modification
- `CONFIG GET module-name.config-name` - retrieval
- `CONFIG REWRITE` - persistence to config file
- Config file loading at startup
- `MODULE LOADEX` argument passing

All config registration must happen during `ValkeyModule_OnLoad()`. After registering all configs, call `ValkeyModule_LoadConfigs()` to apply startup values.

## Config Types

| Type | Registration Function | Value Type |
|------|----------------------|------------|
| String | `RegisterStringConfig` | `ValkeyModuleString *` |
| Bool | `RegisterBoolConfig` | `int` (0 or 1) |
| Numeric | `RegisterNumericConfig` | `long long` (signed, with min/max) |
| Unsigned Numeric | `RegisterUnsignedNumericConfig` | `unsigned long long` (with min/max) |
| Enum | `RegisterEnumConfig` | `int` (maps string tokens to integers) |

## Config Flags

| Flag | Description |
|------|-------------|
| `VALKEYMODULE_CONFIG_DEFAULT` | Modifiable at runtime (default behavior) |
| `VALKEYMODULE_CONFIG_IMMUTABLE` | Only settable at startup/load time |
| `VALKEYMODULE_CONFIG_SENSITIVE` | Value is redacted from logging |
| `VALKEYMODULE_CONFIG_HIDDEN` | Hidden from `CONFIG GET` pattern matching |
| `VALKEYMODULE_CONFIG_PROTECTED` | Immutable when `enable-protected-configs` is on |
| `VALKEYMODULE_CONFIG_DENY_LOADING` | Cannot be modified while server is loading data |
| `VALKEYMODULE_CONFIG_MEMORY` | Numeric only: accepts memory unit notation (e.g. `1gb`) |
| `VALKEYMODULE_CONFIG_BITFLAGS` | Enum only: allow combining multiple values as bit flags |

Flags can be combined with bitwise OR: `VALKEYMODULE_CONFIG_IMMUTABLE | VALKEYMODULE_CONFIG_SENSITIVE`.

## RegisterStringConfig

```c
int ValkeyModule_RegisterStringConfig(ValkeyModuleCtx *ctx,
                                      const char *name,
                                      const char *default_val,
                                      unsigned int flags,
                                      ValkeyModuleConfigGetStringFunc getfn,
                                      ValkeyModuleConfigSetStringFunc setfn,
                                      ValkeyModuleConfigApplyFunc applyfn,
                                      void *privdata);
```

The string passed to `setfn` is freed after the callback returns - the module must retain it (e.g. with `ValkeyModule_RetainString`). The string returned by `getfn` is not consumed by the server.

```c
static ValkeyModuleString *my_str = NULL;

ValkeyModuleString *getStr(const char *name, void *privdata) {
    return my_str;
}

int setStr(const char *name, ValkeyModuleString *new_val,
           void *privdata, ValkeyModuleString **err) {
    if (my_str) ValkeyModule_FreeString(NULL, my_str);
    ValkeyModule_RetainString(NULL, new_val);
    my_str = new_val;
    return VALKEYMODULE_OK;
}

/* In OnLoad: */
ValkeyModule_RegisterStringConfig(ctx, "greeting", "hello",
    VALKEYMODULE_CONFIG_DEFAULT, getStr, setStr, NULL, NULL);
```

## RegisterBoolConfig

```c
int ValkeyModule_RegisterBoolConfig(ValkeyModuleCtx *ctx,
                                    const char *name,
                                    int default_val,
                                    unsigned int flags,
                                    ValkeyModuleConfigGetBoolFunc getfn,
                                    ValkeyModuleConfigSetBoolFunc setfn,
                                    ValkeyModuleConfigApplyFunc applyfn,
                                    void *privdata);
```

```c
static int debug_enabled = 0;

int getDebug(const char *name, void *privdata) { return debug_enabled; }
int setDebug(const char *name, int val, void *privdata, ValkeyModuleString **err) {
    debug_enabled = val;
    return VALKEYMODULE_OK;
}

ValkeyModule_RegisterBoolConfig(ctx, "debug", 0,
    VALKEYMODULE_CONFIG_DEFAULT, getDebug, setDebug, NULL, NULL);
```

## RegisterNumericConfig

```c
int ValkeyModule_RegisterNumericConfig(ValkeyModuleCtx *ctx,
                                       const char *name,
                                       long long default_val,
                                       unsigned int flags,
                                       long long min,
                                       long long max,
                                       ValkeyModuleConfigGetNumericFunc getfn,
                                       ValkeyModuleConfigSetNumericFunc setfn,
                                       ValkeyModuleConfigApplyFunc applyfn,
                                       void *privdata);

int ValkeyModule_RegisterUnsignedNumericConfig(ValkeyModuleCtx *ctx,
                                               const char *name,
                                               unsigned long long default_val,
                                               unsigned int flags,
                                               unsigned long long min,
                                               unsigned long long max,
                                               ValkeyModuleConfigGetUnsignedNumericFunc getfn,
                                               ValkeyModuleConfigSetUnsignedNumericFunc setfn,
                                               ValkeyModuleConfigApplyFunc applyfn,
                                               void *privdata);
```

With `VALKEYMODULE_CONFIG_MEMORY`, values like `1gb`, `256mb`, `1024kb` are converted to bytes before calling `setfn`.

```c
static long long max_items = 1000;

long long getMax(const char *name, void *privdata) { return max_items; }
int setMax(const char *name, long long val, void *privdata, ValkeyModuleString **err) {
    max_items = val;
    return VALKEYMODULE_OK;
}

ValkeyModule_RegisterNumericConfig(ctx, "max-items", 1000,
    VALKEYMODULE_CONFIG_DEFAULT, 1, 1000000, getMax, setMax, NULL, NULL);
```

## RegisterEnumConfig

```c
int ValkeyModule_RegisterEnumConfig(ValkeyModuleCtx *ctx,
                                    const char *name,
                                    int default_val,
                                    unsigned int flags,
                                    const char **enum_values,
                                    const int *int_values,
                                    int num_enum_vals,
                                    ValkeyModuleConfigGetEnumFunc getfn,
                                    ValkeyModuleConfigSetEnumFunc setfn,
                                    ValkeyModuleConfigApplyFunc applyfn,
                                    void *privdata);
```

Maps string tokens (exposed to clients) to integer values (used internally). With `VALKEYMODULE_CONFIG_BITFLAGS`, multiple values can be combined.

```c
static int log_level = 1;
const char *levels[] = {"debug", "info", "warning", "error"};
const int level_vals[] = {0, 1, 2, 3};

int getLevel(const char *name, void *privdata) { return log_level; }
int setLevel(const char *name, int val, void *privdata, ValkeyModuleString **err) {
    log_level = val;
    return VALKEYMODULE_OK;
}

ValkeyModule_RegisterEnumConfig(ctx, "log-level", 1,
    VALKEYMODULE_CONFIG_DEFAULT, levels, level_vals, 4,
    getLevel, setLevel, NULL, NULL);
```

## LoadConfigs and UpdateRuntimeArgs

```c
int ValkeyModule_LoadConfigs(ValkeyModuleCtx *ctx);
```

Must be called after all configs are registered, still within `OnLoad`. Applies values from the config file or `MODULE LOADEX` arguments. Returns `VALKEYMODULE_ERR` if called outside `OnLoad`.

```c
int ValkeyModule_UpdateRuntimeArgs(ValkeyModuleCtx *ctx,
                                   ValkeyModuleString **argv, int argc);
```

Updates the module's saved arguments so they are persisted on `CONFIG REWRITE`. Always returns `VALKEYMODULE_OK`.

## Callback Signatures

All registration functions return `VALKEYMODULE_OK` on success. On failure, `VALKEYMODULE_ERR` with errno:

| errno | Cause |
|-------|-------|
| `EBUSY` | Registration outside `OnLoad` |
| `EINVAL` | Invalid flags or config name characters |
| `EALREADY` | Config name already registered |

Config names must contain only alphanumeric characters, dashes, and underscores.

The `applyfn` callback is called after one or more `setfn` calls from a single `CONFIG SET`. If multiple configs share the same `applyfn` pointer and `privdata`, the callback is deduplicated and called only once. Use `applyfn` for atomic multi-config validation.

The `setfn` callback can reject a value by returning `VALKEYMODULE_ERR` and setting `*err` to a `ValkeyModuleString *` error message. The server frees this string after consuming it - all config types (string, bool, numeric, enum) use `ValkeyModuleString **err`.

## See Also

- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - OnLoad and module initialization flow
- [info-callbacks.md](info-callbacks.md) - Exposing runtime config values via INFO
- [calling-commands.md](calling-commands.md) - Using CONFIG GET/SET via ValkeyModule_Call
- [../commands/registration.md](../commands/registration.md) - Command registration during OnLoad
