# Configuration System

Use when understanding how Valkey loads, validates, modifies, and persists configuration parameters at runtime.

Standard type-safe registration table of `standardConfig` entries with `loadServerConfig()` / `CONFIG SET` / `CONFIG GET` / `CONFIG REWRITE`. Each config declares its type, default, bounds, and callbacks in a single macro.

## Valkey-Specific Changes

- **IMMUTABLE_CONFIG flag**: Configs marked `IMMUTABLE_CONFIG` can only be set in the config file, not via `CONFIG SET`. Replaces the ad-hoc approach of checking individual params.
- **Renamed parameters**: Terminology changes from Redis - `slaveof` -> `replicaof`, `slave-*` -> `replica-*`, `masteruser` -> `primaryuser`, `masterauth` -> `primaryauth`.
- **PROTECTED_CONFIG flag**: Requires `enable-protected-configs local|yes` before modification. Additional safety layer for sensitive params.
- **HIDDEN_CONFIG flag**: Configs not returned by `CONFIG GET *` pattern matching.
- **Atomic multi-param CONFIG SET**: `CONFIG SET` accepts multiple key-value pairs atomically with full rollback on failure.

Source: `src/config.c`
