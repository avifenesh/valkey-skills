# Rust SDK for Valkey Modules

Use when writing a Valkey module in Rust instead of C, evaluating the Rust SDK approach, or setting up a Rust module project.

Source: `src/valkeymodule.h` (C API that the Rust SDK wraps), research guide section 15

---

## Overview

The `valkeymodule-rs` crate (published as `valkey-module` on crates.io) provides safe Rust bindings over the Valkey C module API. It wraps `valkeymodule.h` via FFI, adding Rust idioms: the `valkey_module!` declarative macro for setup, `Context` for the API surface, `ValkeyResult` for error handling, and derive macros for custom types.

Repository: https://github.com/valkey-io/valkeymodule-rs

---

## Project Setup

### Cargo.toml

```toml
[package]
name = "my-valkey-module"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
valkey-module = "0"    # Use latest 0.x
```

The `crate-type = ["cdylib"]` is mandatory - it produces a `.so` shared library that Valkey can load via `MODULE LOAD`.

### Build

```bash
cargo build --release
# Produces: target/release/libmy_valkey_module.so (Linux)
#           target/release/libmy_valkey_module.dylib (macOS)
```

Load into Valkey:
```
MODULE LOAD /path/to/target/release/libmy_valkey_module.so
```

---

## Module Declaration

The `valkey_module!` macro replaces the C boilerplate of `ValkeyModule_OnLoad`, `ValkeyModule_Init`, and `ValkeyModule_CreateCommand`:

```rust
use valkey_module::{valkey_module, Context, ValkeyResult, ValkeyString, ValkeyValue};

fn hello_cmd(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    if args.len() != 2 {
        return Err(valkey_module::ValkeyError::WrongArity);
    }

    let name = args[1].try_as_str()?;
    let reply = format!("Hello, {}!", name);

    Ok(ValkeyValue::SimpleString(reply))
}

valkey_module! {
    name: "helloworld",
    version: 1,
    allocator: (valkey_module::alloc::ValkeyAlloc, valkey_module::alloc::ValkeyAlloc),
    data_types: [],
    commands: [
        ["hello.greet", hello_cmd, "readonly fast", 0, 0, 0],
    ],
}
```

### Macro fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Module name (string literal) |
| `version` | Yes | Module version (integer) |
| `allocator` | No | Use Valkey's allocator for all Rust allocations |
| `data_types` | Yes | List of custom data type registrations |
| `commands` | Yes | List of command registrations |
| `init` | No | Custom initialization function |

### Command registration format

```rust
commands: [
    ["command.name", handler_fn, "flags", firstkey, lastkey, keystep],
]
```

The flags string uses the same space-separated format as the C API: `"write deny-oom"`, `"readonly fast"`, etc. See `api-overview.md` for the full flag list.

---

## Command Handlers

Every command handler has the signature:

```rust
fn my_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult;
```

`ValkeyResult` is `Result<ValkeyValue, ValkeyError>`.

### Return values

```rust
// String reply
Ok(ValkeyValue::SimpleStringStatic("OK"))
Ok(ValkeyValue::SimpleString("dynamic string".to_string()))
Ok(ValkeyValue::BulkString("binary safe".to_string()))
Ok(ValkeyValue::BulkValkeyString(valkey_string))

// Numeric replies
Ok(ValkeyValue::Integer(42))
Ok(ValkeyValue::Float(3.14))

// Null
Ok(ValkeyValue::Null)

// Array
Ok(ValkeyValue::Array(vec![
    ValkeyValue::Integer(1),
    ValkeyValue::Integer(2),
]))

// No reply (for blocked clients)
Ok(ValkeyValue::NoReply)
```

### Error handling

```rust
// Wrong number of arguments
Err(ValkeyError::WrongArity)

// Custom error
Err(ValkeyError::String("ERR something failed".to_string()))
Err(ValkeyError::Str("ERR static message"))
```

---

## Key Access

The `Context` provides methods that wrap the C key API:

```rust
fn my_write_cmd(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    let key = ctx.open_key_writable(&args[1]);

    // Check type
    match key.key_type() {
        KeyType::Empty => { /* create */ },
        KeyType::String => { /* exists */ },
        _ => return Err(ValkeyError::WrongType),
    }

    // String operations
    key.set_value(&args[2])?;
    key.set_expire(Duration::from_secs(60))?;

    Ok(ValkeyValue::SimpleStringStatic("OK"))
}
```

Read-only access:

```rust
let key = ctx.open_key(&args[1]);
let value = key.read()?;
```

### Calling other commands

```rust
let reply = ctx.call("SET", &["mykey", "myvalue"])?;
```

---

## Custom Data Types

Use `ValkeyType::new()` with the 9-character type name, encoding version, and a `raw::ValkeyModuleTypeMethods` struct specifying `rdb_load`, `rdb_save`, and `free` callbacks. The RDB callbacks are `unsafe extern "C"` functions that use `raw::load_signed`/`raw::save_signed` and `Box::into_raw`/`Box::from_raw` for value lifecycle. Register the static type in the `data_types: [MY_TYPE]` field of the `valkey_module!` macro.

Note: Older versions of the Rust SDK used the name `raw::RedisModuleTypeMethods` from the Redis-era API. Current versions use `raw::ValkeyModuleTypeMethods`.

See `types-and-commands.md` for the full C callback signatures - the Rust wrappers mirror them exactly via FFI.

---

## Comparison: C vs Rust Module Development

| Aspect | C Module | Rust Module |
|--------|----------|-------------|
| Header | `#include "valkeymodule.h"` | `use valkey_module::*` |
| Build | `gcc -shared -fPIC` | `cargo build --release` (cdylib) |
| Entry point | `ValkeyModule_OnLoad` function | `valkey_module!` macro |
| Memory safety | Manual (use module allocator) | Rust ownership + optional Valkey allocator |
| Error handling | Return codes + errno | `Result<ValkeyValue, ValkeyError>` |
| String handling | `ValkeyModuleString*` + `StringPtrLen` | `ValkeyString` with `.try_as_str()` |
| Custom types | `ValkeyModuleTypeMethods` struct | `ValkeyType::new()` with raw callbacks |
| RDB callbacks | Directly write C callbacks | `unsafe extern "C"` wrappers |
| Blocking commands | `BlockClient`/`UnblockClient` | Same API through `Context` methods |
| Dependencies | None (single header) | `valkey-module` crate |
| Binary size | Small (few KB) | Larger (includes Rust runtime) |
| Debug | gdb/lldb directly | gdb/lldb + Rust symbols |

### When to use Rust

- Complex data structures where memory safety matters (trees, graphs, caches with eviction)
- Modules with significant business logic beyond simple key operations
- Teams already using Rust in their stack
- Modules that spawn background threads for blocking commands

### When to use C

- Maximum performance with minimal overhead
- Simple modules (a few commands wrapping existing data types)
- Environments where Rust toolchain is not available
- When you need direct access to internal Valkey structures

---

## Blocking Commands in Rust

```rust
use std::thread;
use valkey_module::BlockedClient;

fn slow_cmd(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    let blocked = ctx.block_client();

    thread::spawn(move || {
        // Background work
        let result = expensive_computation();

        // Unblock with the result
        blocked.set_reply(move |ctx, _args| {
            Ok(ValkeyValue::Integer(result))
        });
        blocked.unblock();
    });

    Ok(ValkeyValue::NoReply)
}
```

---

## Configuration and Options

Register module configs via `ctx.register_string_config`, `register_numeric_config`, `register_bool_config`, or `register_enum_config`, then call `ctx.load_configs()`. These map to the C API's `ValkeyModule_Register*Config` family. Set module-wide options with `ctx.set_module_options(ModuleOptions::HANDLE_IO_ERRORS)` - see `api-overview.md` for the full options list.

---

## Testing

Test pure business logic with standard Rust unit tests. For integration tests, start a Valkey server with the module loaded and use the `redis-rs` crate (compatible with Valkey) to send commands and assert results. The Valkey source tree also includes a Tcl-based module test harness under `tests/unit/moduleapi/`.

---

## See Also

- [Module API Overview](../modules/api-overview.md) - The C API that this Rust SDK wraps. Command flag strings, context flags, and reply types are documented there.
- [Custom Types and Advanced Commands](../modules/types-and-commands.md) - Full C callback signatures for custom data types, RDB serialization primitives, and blocking command patterns. The Rust wrappers mirror these via FFI.
