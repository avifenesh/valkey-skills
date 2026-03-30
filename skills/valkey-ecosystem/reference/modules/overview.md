# Module System Overview

Use when understanding the Valkey module system, loading modules, checking compatibility with Redis modules, or deciding between individual modules and the valkey-bundle container image.

---

## Module System

Valkey supports a module system compatible with Redis modules built for Redis 7.2. Modules are shared libraries (`.so` files) loaded at startup or runtime that extend Valkey with new data types and commands. The Valkey project maintains official BSD-licensed modules that provide equivalent functionality to Redis Stack modules.

Modules use the same API as Redis 7.2 modules. Both the `ValkeyModule_OnLoad` and legacy `RedisModule_OnLoad` entry points are supported. Existing Redis modules compiled against Redis 7.2 can run on Valkey without recompilation in most cases.

## Valkey Bundle

The **valkey-bundle** container image packages Valkey with all official modules pre-loaded:

```
docker pull valkey/valkey-bundle
```

The bundle includes all official modules. New releases of any module automatically trigger a bundle release.

| Module | Status |
|--------|--------|
| valkey-json | GA |
| valkey-bloom | GA |
| valkey-search | GA |
| valkey-ldap | GA |

The bundle is the simplest way to get all official modules running. For production deployments where you need only specific modules, load them individually.

## Official Modules

| Module | Purpose | Redis Equivalent | Compatibility |
|--------|---------|------------------|---------------|
| **valkey-json** | Native JSON data type with JSONPath | RedisJSON | API + RDB compatible with RedisJSON v1/v2 |
| **valkey-bloom** | Bloom filter probabilistic data structure | RedisBloom | API compatible with `BF.*` commands |
| **valkey-search** | Vector, full-text, tag, and numeric search | RediSearch | Full-text search added in 1.2.0; covers most RediSearch features |
| **valkey-ldap** | LDAP authentication | N/A | New to Valkey, no Redis equivalent |

## Loading Modules

### At Startup (valkey.conf)

```
loadmodule /opt/valkey/modules/valkeyjson.so
loadmodule /opt/valkey/modules/valkeybloom.so
loadmodule /opt/valkey/modules/valkeysearch.so
```

### At Runtime

Runtime module loading requires `enable-module-command yes` in the configuration:

```
MODULE LOAD /opt/valkey/modules/valkeyjson.so
MODULE LIST
MODULE UNLOAD valkeyjson
```

### Verify Loaded Modules

```
127.0.0.1:6379> MODULE LIST
1) 1) "name"
   2) "valkeyjson"
   3) "ver"
   4) 10000
```

Or from a client using `INFO MODULES`.

## Redis Module Compatibility

Valkey's module API is compatible with Redis 7.2 modules. Key points:

- Modules compiled for Redis 7.2 work on Valkey without changes
- Both `ValkeyModule_*` and `RedisModule_*` API names are supported
- The legacy `RedisModule_OnLoad` entry point is detected automatically
- Modules targeting Redis 7.4+ may not work due to post-fork API divergence
- Community modules like `redistimeseries.so` (built for Redis 7.2) have been confirmed working on Valkey 7.2

### What Does NOT Work

- Modules built specifically for Redis 7.4 or later (post-fork)
- Modules that depend on Redis Stack proprietary extensions
- Redis 8 bundled modules (these are source-available, not open-source)

## Client Integration

GLIDE provides dedicated APIs for JSON and Search modules. For Bloom and LDAP, use `custom_command`.

| Module | GLIDE API | Modules without API |
|--------|-----------|---------------------|
| JSON | GlideJson (Node.js), Json (Java/Python) | Use `custom_command` |
| Search | GlideFt (Node.js), FT (Java/Python) | Use `custom_command` |

See [json.md](json.md) and [search.md](search.md) for per-module GLIDE examples, or the **valkey-glide** skill for complete API reference.

## When to Use Modules vs Core Features

| Need | Solution |
|------|----------|
| Structured documents with nested paths | valkey-json module |
| Probabilistic membership testing | valkey-bloom module |
| Vector similarity / nearest neighbor | valkey-search module |
| Full-text, tag, and numeric search | valkey-search module (1.2.0+) |
| Server-side aggregations | valkey-search FT.AGGREGATE (1.1.0+) |
| Enterprise LDAP authentication | valkey-ldap module |
| Faster Lua script execution | valkey-luajit module (early stage, experimental) |
| Simple key-value, lists, sets, hashes | Core Valkey (no module needed) |
| Sorted scoring / ranking | Core Valkey Sorted Sets |
| Message queuing | Core Valkey Streams |
| Pub/sub messaging | Core Valkey Pub/Sub |

## Building Custom Modules

Valkey modules are shared libraries that implement the Valkey Modules API. You can build custom modules in C (using the API directly) or in Rust (using the valkeymodule-rs SDK).

### C Module API

The C API is the native interface for building modules. Include the `valkeymodule.h` header and implement the `ValkeyModule_OnLoad` entry point.

Minimal module skeleton:

```c
#include "valkeymodule.h"

int HelloCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModule_ReplyWithSimpleString(ctx, "Hello from my module!");
    return VALKEY_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "mymodule", 1, VALKEYMODULE_APIVER_1) == VALKEY_ERR)
        return VALKEY_ERR;

    if (ValkeyModule_CreateCommand(ctx, "mymodule.hello",
            HelloCommand, "readonly", 0, 0, 0) == VALKEY_ERR)
        return VALKEY_ERR;

    return VALKEY_OK;
}
```

Compile and load:

```bash
gcc -shared -fPIC -o mymodule.so mymodule.c
valkey-server --loadmodule ./mymodule.so
```

The C API supports:
- Custom commands with flags (readonly, write, deny-oom, etc.)
- Custom data types with RDB persistence, AOF rewrite, and memory reporting
- Key-space notifications
- Blocking commands
- Cluster message bus
- Module configuration options
- Timer and event loop integration

Full API reference: [valkey.io/topics/modules-api-ref](https://valkey.io/topics/modules-api-ref/)

### Rust SDK (valkeymodule-rs)

[valkeymodule-rs](https://github.com/valkey-io/valkeymodule-rs) provides an idiomatic Rust API for the Valkey Modules API, eliminating the need for raw pointers or unsafe code.

| | |
|---|---|
| **Crate** | `valkey-module` |
| **Install** | `cargo add valkey-module` |
| **Docs** | [docs.rs/valkey-module](https://docs.rs/valkey-module/latest) |
| **Origin** | Forked from redismodule-rs |

Minimal Rust module:

```rust
use valkey_module::{valkey_module, Context, ValkeyResult, ValkeyString, Status};

fn hello_command(ctx: &Context, _args: Vec<ValkeyString>) -> ValkeyResult {
    ctx.reply_simple_string("Hello from Rust!");
    Ok(())
}

valkey_module! {
    name: "mymodule",
    version: 1,
    data_types: [],
    commands: [
        ["mymodule.hello", hello_command, "readonly", 0, 0, 0],
    ],
}
```

Build and load:

```bash
cargo build --release
# Linux
valkey-server --loadmodule ./target/release/libmymodule.so
# macOS
valkey-server --loadmodule ./target/release/libmymodule.dylib
```

#### Feature Flags

| Flag | Purpose |
|------|---------|
| `system-alloc` | Use system allocator instead of Valkey allocator - useful for unit tests without a running server |
| `use-redismodule-api` | Initialize via `RedisModule_OnLoad` for compatibility with both Valkey and Redis servers |

Testing with system allocator:

```bash
cargo test --features enable-system-alloc
```

### Choosing C vs Rust

| Factor | C API | Rust SDK |
|--------|-------|----------|
| Performance | Direct API access, minimal overhead | Near-zero overhead via Rust abstractions |
| Safety | Manual memory management, raw pointers | Memory safety without unsafe code |
| Ecosystem | Any C-compatible toolchain | Cargo, crates.io, docs.rs |
| Debugging | GDB, Valgrind | Rust toolchain + GDB |
| Redis compatibility | Both entry points supported natively | `use-redismodule-api` feature flag |
| Examples | Valkey source tree `src/modules/` | `examples/` directory in valkeymodule-rs |

For new modules, the Rust SDK is recommended unless you need to minimize dependencies or integrate with existing C codebases.

## Additional Official Repositories

| Repository | Purpose | Language |
|------------|---------|----------|
| **valkey-luajit** | Drop-in LuaJIT replacement for Valkey's built-in Lua engine. Significantly faster script execution. Optional FFI support (disabled by default). | C |
| **valkey-admin** | Web-based cluster administration tool. Real-time metrics, key browser, command execution, topology visualization, hot key monitoring, slow log analysis. | TypeScript (React + Electron) |
| **valkey-namespace** | Namespace support for keys - multiple logical namespaces in a single instance. | Ruby |
| **valkey-operator** | Kubernetes operator for Valkey. Active development. | Go |
| **valkeymodule-rs** | Official Rust SDK for building Valkey modules. | Rust |

## Cross-References

- [json.md](json.md) - valkey-json module details
- [bloom.md](bloom.md) - valkey-bloom module details
- [search.md](search.md) - valkey-search full-text and vector search details
- [gaps.md](gaps.md) - feature gaps vs Redis Stack/Redis 8
- `clients/landscape.md` - client library decision framework (GLIDE provides dedicated module APIs)
- **valkey-glide** skill - GLIDE module integration patterns (GlideJson, GlideFt, custom_command)
