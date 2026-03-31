---
name: valkey-module-dev
description: "Use when building custom Valkey modules in C or Rust. Covers ValkeyModule_* API, valkeymodule-rs SDK, custom data types, RDB/AOF persistence, command registration, blocking commands, and testing. Not for using existing modules (valkey-modules)."
version: 1.0.0
argument-hint: "[API area or task]"
---

# Valkey Module Development Reference

C and Rust module API reference for developers building custom Valkey modules.

## Routing

- Module skeleton, OnLoad, Init, lifecycle -> Module API
- Custom data types, RDB load/save, AOF rewrite, encoding versions -> Data Types
- Command registration, flags, argument parsing, reply helpers, subcommands -> Commands
- Testing modules, loading/unloading, CI, runtest-moduleapi -> Testing
- Rust module, valkeymodule-rs, Cargo, valkey-module crate, Rust SDK -> Rust SDK

## Reference

| Topic | Reference |
|-------|-----------|
| Module lifecycle, context, memory, events, timers, config, cluster messaging | [module-api](reference/module-api.md) |
| Custom data types, RDB serialization, AOF rewrite, aux data, defrag | [data-types](reference/data-types.md) |
| Command registration, flags, key specs, argument parsing, reply building | [commands](reference/commands.md) |
| Testing modules, Tcl harness, loading/unloading, CI integration | [testing](reference/testing.md) |
| Rust SDK (valkeymodule-rs), Cargo setup, C-to-Rust API mapping | [rust-sdk](reference/rust-sdk.md) |

## Quick Start

```c
#include "valkeymodule.h"

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "mymod", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;
    // Register commands, data types, configs, events here
    return VALKEYMODULE_OK;
}
```

```bash
gcc -shared -fPIC -o mymod.so mymod.c -I /path/to/valkey/src
valkey-server --loadmodule ./mymod.so
```
