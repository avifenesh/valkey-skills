# Rust Module SDK (valkeymodule-rs)

Use when building Valkey modules in Rust instead of C, setting up a Rust module project, or mapping C API concepts to Rust equivalents.

Source: [valkey-io/valkeymodule-rs](https://github.com/valkey-io/valkeymodule-rs) (crate: `valkey-module` v0.1.11)
---

`valkeymodule-rs` wraps the ValkeyModule C API in idiomatic Rust. Modules compile to `.so`/`.dylib` shared libraries loaded the same way as C modules, but without raw pointers or unsafe blocks for most use cases.

## Project Setup

```toml
# Cargo.toml - [lib] must be crate-type = ["cdylib"]
[lib]
crate-type = ["cdylib"]

[dependencies]
valkey-module = "0.1"
# Optional: proc-macro #[command(...)] attributes
valkey-module-macros = "0.1"
```

Feature flags: `enable-system-alloc` (unit tests without server), `use-redismodule-api` (Redis 7.2+ compat).

```bash
cargo build --release
valkey-server --loadmodule ./target/release/libmymod.so
```

## C API to Rust Mapping

| C API | Rust Equivalent |
|-------|-----------------|
| `ValkeyModule_OnLoad` + `ValkeyModule_Init` | `valkey_module!` macro (declares name, version, commands, data types) |
| `ValkeyModuleCtx *ctx` | `&Context` (borrowed, no lifetime management needed) |
| `ValkeyModuleString` | `ValkeyString` (owned, with `parse_integer()`, `to_string_lossy()`) |
| `ValkeyModule_CreateCommand` | `commands: [...]` in `valkey_module!` or `#[command(...)]` attribute |
| `ValkeyModule_ReplyWith*` | Return `ValkeyResult` / `Ok(ValkeyValue::...)` from handler |
| `ValkeyModule_CreateDataType` | `ValkeyType::new()` static + `data_types: [...]` in macro |
| `ValkeyModule_OpenKey` | `ctx.open_key(&key)` / `ctx.open_key_writable(&key)` |
| `ValkeyModule_ModuleTypeGetValue` | `key.get_value::<MyType>(&MY_TYPE)?` |
| `ValkeyModule_ModuleTypeSetValue` | `key.set_value(&MY_TYPE, value)?` |
| `ValkeyModule_RegisterBoolConfig` etc. | `configurations: [...]` block in `valkey_module!` |
| `ValkeyModule_Log` | `ctx.log_debug()`, `ctx.log_notice()`, `ctx.log_warning()` |
| `ValkeyModule_BlockClient` | `BlockedClient` + `ThreadSafeContext` |
| `VALKEYMODULE_OK` / `VALKEYMODULE_ERR` | `Ok(...)` / `Err(ValkeyError::...)` |

## Minimal Module

```rust
use valkey_module::alloc::ValkeyAlloc;
use valkey_module::{valkey_module, Context, ValkeyError, ValkeyResult, ValkeyString};

fn hello_mul(_: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    if args.len() < 2 {
        return Err(ValkeyError::WrongArity);
    }
    let nums: Vec<i64> = args.into_iter().skip(1)
        .map(|s| s.parse_integer())
        .collect::<Result<Vec<_>, _>>()?;
    let product: i64 = nums.iter().product();
    Ok(product.into())
}

valkey_module! {
    name: "hello",
    version: 1,
    allocator: (ValkeyAlloc, ValkeyAlloc),
    data_types: [],
    commands: [
        ["hello.mul", hello_mul, "", 0, 0, 0],
    ],
}
```

## Proc-Macro Commands

`#[command(...)]` from `valkey-module-macros` declares flags and key specs without the `valkey_module!` commands array:

```rust
#[command({ flags: [ReadOnly], arity: -2,
    key_spec: [{ flags: [ReadOnly, Access],
        begin_search: Index({ index: 1 }),
        find_keys: Range({ last_key: -1, steps: 2, limit: 0 }) }] })]
fn my_cmd(_ctx: &Context, _args: Vec<ValkeyString>) -> ValkeyResult {
    Ok(ValkeyValue::SimpleStringStatic("OK"))
}
```

## Testing

- Unit tests: `cargo test --features enable-system-alloc` (system allocator, no server needed)
- Integration tests: `cargo test` (requires running Valkey, uses `ValkeyAlloc`)
- The `runtest-moduleapi` Tcl harness works for `.so` files built from Rust

## When to Use Rust vs C

- **Rust**: safer memory management, rich type system, Cargo ecosystem
- **C**: zero-overhead control, wrapping existing C libraries, matching upstream examples
- Both produce identical `.so` artifacts - the server cannot tell the difference

## See Also

- [lifecycle/module-loading.md](lifecycle/module-loading.md) - C module loading lifecycle that Rust modules follow identically
- [commands/registration.md](commands/registration.md) - C command registration mapped by the `valkey_module!` macro
- [data-types/registration.md](data-types/registration.md) - C data type callbacks wrapped by `ValkeyType::new()`
- [testing.md](testing.md) - Tcl test harness works for Rust-built `.so` files
