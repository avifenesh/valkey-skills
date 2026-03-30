# Configuration System

Use when understanding how Valkey loads, validates, modifies, and persists configuration parameters at runtime.

Source: `src/config.c` (3,681 lines)

---

## Architecture Overview

Valkey's configuration system is built on a **type-safe registration table** of `standardConfig` entries. Each config parameter declares its type, default value, bounds, validation callback, and apply callback in a single macro invocation. The runtime `configs` dict maps parameter names (and aliases) to their `standardConfig` structs for O(1) lookup.

Three paths converge on the same infrastructure:

1. **File parsing** - `loadServerConfig()` reads `valkey.conf` at startup
2. **CONFIG SET** - `configSetCommand()` modifies values at runtime
3. **CONFIG REWRITE** - `rewriteConfig()` persists current state back to disk

## Key Structs

```c
struct standardConfig {
    const char *name;        /* The user visible name of this config */
    const char *alias;       /* An alias that can also be used for this config */
    unsigned int flags;      /* IMMUTABLE_CONFIG, MODIFIABLE_CONFIG, etc. */
    typeInterface interface;  /* Function pointers: init, set, get, rewrite, apply */
    typeData data;           /* Union of type-specific data (yesno, string, sds, enumd, numeric) */
    configType type;         /* BOOL_CONFIG, STRING_CONFIG, ENUM_CONFIG, NUMERIC_CONFIG, etc. */
    void *privdata;          /* For module configs: points to ModuleConfig struct */
};

typedef struct typeInterface {
    void (*init)(standardConfig *config);     /* Set server field to default value */
    int (*set)(standardConfig *config, sds *argv, int argc, const char **err);
    apply_fn apply;                            /* Post-set callback for side effects */
    sds (*get)(standardConfig *config);        /* Return current value as sds */
    void (*rewrite)(standardConfig *config, const char *name, struct rewriteConfigState *state);
} typeInterface;
```

The `set()` function returns three values:
- `0` - error (validation failed)
- `1` - value changed successfully
- `2` - no actual change (value was already set to this)

## Type System

Each config type has its own data struct and a creation macro:

| Type | Data Struct | Creation Macro | Key Fields |
|------|-------------|----------------|------------|
| Bool | `boolConfigData` | `createBoolConfig()` | `int *config`, `default_value`, `is_valid_fn` |
| String | `stringConfigData` | `createStringConfig()` | `char **config`, `default_value`, `convert_empty_to_null` |
| SDS | `sdsConfigData` | `createSDSConfig()` | `sds *config`, `default_value`, `convert_empty_to_null` |
| Enum | `enumConfigData` | `createEnumConfig()` | `int *config`, `configEnum *enum_value`, `default_value` |
| Numeric | `numericConfigData` | `createIntConfig()` etc. | `union config`, `numeric_type`, `lower_bound`, `upper_bound` |
| Special | N/A | `createSpecialConfig()` | Fully custom set/get logic for configs that don't fit standard types |

Numeric configs support 10 subtypes via the `numericType` enum: `INT`, `UINT`, `LONG`, `ULONG`, `LONG_LONG`, `ULONG_LONG`, `SIZE_T`, `SSIZE_T`, `OFF_T`, `TIME_T`. Each has its own creation macro (`createIntConfig`, `createUIntConfig`, etc.).

Enum configs use a null-terminated array of `configEnum` structs:

```c
configEnum maxmemory_policy_enum[] = {
    {"volatile-lru", MAXMEMORY_VOLATILE_LRU},
    {"allkeys-lfu", MAXMEMORY_ALLKEYS_LFU},
    {"noeviction", MAXMEMORY_NO_EVICTION},
    {NULL, 0}
};
```

Enums can be used as bitflags (multiple values combined with `|`).

## Registration and Initialization

All built-in configs live in the `static_configs[]` array:

```c
standardConfig static_configs[] = {
    createBoolConfig("rdbchecksum", NULL, IMMUTABLE_CONFIG, server.rdb_checksum, 1, NULL, NULL),
    createBoolConfig("protected-mode", NULL, MODIFIABLE_CONFIG, server.protected_mode, 1, NULL, NULL),
    createEnumConfig("maxmemory-policy", NULL, MODIFIABLE_CONFIG, maxmemory_policy_enum,
                     server.maxmemory_policy, MAXMEMORY_NO_EVICTION, NULL, NULL),
    createLongLongConfig("maxmemory", NULL, MODIFIABLE_CONFIG, 0, LLONG_MAX,
                         server.maxmemory, 0, MEMORY_CONFIG, NULL, applyMaxmemory),
    /* ... hundreds more ... */
};
```

At startup, `initConfigValues()` iterates `static_configs[]`:

1. Calls each config's `init()` to set the `server.*` field to its default
2. Registers the config name (and alias if present) in the `configs` dict

The `embedCommonConfig` and `embedConfigInterface` macros wire name/flags and the type-specific init/set/get/rewrite/apply function pointers into each entry.

## Config Flags

Key flags on `standardConfig.flags`:

- `IMMUTABLE_CONFIG` - can only be set in the config file, not via CONFIG SET
- `MODIFIABLE_CONFIG` - can be changed at runtime via CONFIG SET
- `SENSITIVE_CONFIG` - value is redacted from logs and command history
- `PROTECTED_CONFIG` - requires `enable-protected-configs local|yes`
- `DENY_LOADING_CONFIG` - cannot be changed while a dataset is loading
- `MODULE_CONFIG` - registered by a loaded module
- `HIDDEN_CONFIG` - not returned by `CONFIG GET *` pattern matching
- `MULTI_ARG_CONFIG` - accepts multiple space-separated arguments
- `ALIAS_CONFIG` - this entry is an alias for another config
- `VOLATILE_CONFIG` - always reports "changed" even if value is identical

## File Parsing: loadServerConfig()

```c
void loadServerConfig(char *filename, char config_from_stdin, char *options);
```

1. Reads the file (supports glob patterns for `include` directives)
2. Optionally appends stdin and `--`-prefixed CLI options
3. Passes the concatenated string to `loadServerConfigFromString()`

`loadServerConfigFromString()` splits input into lines, then for each non-comment line:

1. Looks up `argv[0]` in the `configs` dict via `lookupConfig()`
2. If found, calls `config->interface.set(config, &argv[1], argc-1, &err)`
3. For `MULTI_ARG_CONFIG` with a single argument, tries splitting it by spaces first
4. Special directives handled separately: `include`, `rename-command`, `user`, `loadmodule`, `sentinel`, and module configs (detected by `.` in the name)

Deprecated configs (e.g., `list-max-ziplist-entries`) are silently skipped.

## CONFIG SET Implementation

```c
void configSetCommand(client *c);
```

CONFIG SET accepts multiple key-value pairs atomically. The algorithm:

1. **Lookup phase** - find all `standardConfig` entries, redact sensitive values, check IMMUTABLE/PROTECTED flags
2. **Backup phase** - save old values via each config's `get()` interface
3. **Set phase** - call `performInterfaceSet()` for each config; on failure, restore all backups
4. **Apply phase** - call `apply()` callbacks (deduplicated); on failure, restore all backups
5. **Module apply** - call `moduleConfigApplyConfig()` for module configs
6. **Notify** - fire `VALKEYMODULE_EVENT_CONFIG` server event

The atomic rollback ensures that if any single parameter fails validation or application, the entire CONFIG SET is reverted.

## CONFIG GET Implementation

```c
void configGetCommand(client *c);
```

Accepts multiple patterns. For each pattern:

- If no glob characters (`[*?`), does direct dict lookup
- Otherwise, iterates all configs and uses `stringmatch()` (skipping HIDDEN configs)

Results are collected, sorted alphabetically by key, and returned as a map of key-value pairs. Values come from each config's `get()` function.

## CONFIG REWRITE Implementation

```c
int rewriteConfig(char *path, int force_write);
```

Persists current configuration back to the config file. Four-step process:

1. **Read old file** into a `rewriteConfigState` - tracks which lines correspond to which options via an `option_to_line` dict mapping option names to lists of line numbers
2. **Rewrite each option** - iterates all registered configs, calling their `rewrite()` function. Each rewrite function calls `rewriteConfigRewriteLine()` which either replaces an existing line or appends a new one after the `# Generated by CONFIG REWRITE` signature
3. **Remove orphans** - blank out old lines for options that have been fully rewritten
4. **Write** - join all lines and atomically overwrite the config file

The `rewriteConfigState` struct:

```c
struct rewriteConfigState {
    dict *option_to_line; /* Option -> list of config file lines map */
    dict *rewritten;      /* Dictionary of already processed options */
    int numlines;         /* Number of lines in current config */
    sds *lines;           /* Current lines as an array of sds strings */
    int needs_signature;  /* True if we need to append the rewrite signature */
    int force_write;      /* True if we want all keywords to be force written */
};
```

## Adding a New Config Parameter

To add a new configuration parameter:

1. Add a field to the `server` struct in `server.h`
2. Add a `create*Config()` entry to the `static_configs[]` array in `config.c`
3. If the parameter needs side effects on change, write an `apply_fn` and pass it as the last argument to the creation macro
4. If it needs custom validation, write an `is_valid_fn`

Example - a new boolean config:

```c
createBoolConfig("my-new-feature", NULL, MODIFIABLE_CONFIG,
                 server.my_new_feature, 0, NULL, applyMyNewFeature),
```

This single line provides: default initialization, file parsing, CONFIG SET validation, CONFIG GET retrieval, and CONFIG REWRITE persistence. The `apply` function (`applyMyNewFeature`) runs only on CONFIG SET, not on startup file parsing.

---

## See Also

- [Key Expiration](../config/expiry.md) - active-expire-effort, lazyfree-lazy-expire, and other expiry configs registered through this system
- [Database Management](../config/db-management.md) - the `databases` config and lazy allocation controlled by the config system
- [Commandlog](../monitoring/commandlog.md) - commandlog threshold and max-len configs with their slowlog aliases
- [Latency Monitoring](../monitoring/latency.md) - `latency-monitor-threshold` config
- [Modules API](../modules/api-overview.md) - modules register configs via `MODULE_CONFIG` flag, applied through `moduleConfigApplyConfig()`
- [ACL Subsystem](../security/acl.md) - `PROTECTED_CONFIG` requires `enable-protected-configs` to change at runtime, adding a security layer. `SENSITIVE_CONFIG` redacts values from logs and command history. ACL users defined via `user` directives in the config file are parsed during `loadServerConfigFromString()`.
- [TLS Subsystem](../security/tls.md) - TLS config parameters (`tls-port`, `tls-cert-file`, etc.) are registered through this system. Background certificate reloading is triggered by config changes detected in `serverCron`.
