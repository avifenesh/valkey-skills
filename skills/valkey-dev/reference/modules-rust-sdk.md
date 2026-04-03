# Rust SDK for Valkey Modules

Use when writing a Valkey module in Rust instead of C.

The `valkey-module` crate (crates.io, repo: `valkey-io/valkeymodule-rs`) provides safe Rust bindings over the Valkey C module API. Uses `valkey_module!` declarative macro for setup, `Context` for the API surface, `ValkeyResult` for error handling. Build with `crate-type = ["cdylib"]` to produce a `.so` loadable by `MODULE LOAD`.

Key differences from C modules: Rust ownership for memory safety, `Result<ValkeyValue, ValkeyError>` error handling, `ValkeyType::new()` for custom data types with `unsafe extern "C"` RDB callbacks. Blocking commands use `ctx.block_client()` with `std::thread::spawn`.

For the full C callback signatures and module API, see [module-lifecycle.md](modules-module-lifecycle.md), [module-patterns.md](modules-module-patterns.md), [custom-types.md](modules-custom-types.md).

Source: https://github.com/valkey-io/valkeymodule-rs
