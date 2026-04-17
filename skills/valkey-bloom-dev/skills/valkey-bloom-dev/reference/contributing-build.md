# Build system

Use when building valkey-bloom, understanding feature flags, or working with `build.sh`.

Source: `Cargo.toml`, `build.sh`.

## Shape

- `crate-type = ["cdylib"]`, lib name `valkey_bloom` (output `libvalkey_bloom.so` / `.dylib`).
- Crate version `99.99.99-dev`, `MODULE_VERSION = 999999` - both placeholder, rewritten at release.
- Dev profile: `debug = 2`, `opt-level = 0`. Release profile uses Cargo defaults.
- Module name registered to Valkey is `"bf"` (not `"bloom"`).

## Feature flags

```toml
[features]
default = ["min-valkey-compatibility-version-8-0"]
enable-system-alloc        = ["valkey-module/enable-system-alloc"]
min-valkey-compatibility-version-8-0 = []
valkey_8_0                 = []
use-redismodule-api        = []   # empty stub, prevents build errors if passed
```

| Flag | Why |
|------|-----|
| `enable-system-alloc` | **Required for `cargo test`** - ValkeyAlloc needs a running server. Integration tests load into a real server and use ValkeyAlloc normally. |
| `valkey_8_0` | Swaps `must_obey_client` from `ValkeyModule_MustObeyClient` to `ContextFlags::REPLICATED` fallback. Compile-time only. |

## Allocator

```rust
valkey_module! {
    allocator: (valkey_module::alloc::ValkeyAlloc, valkey_module::alloc::ValkeyAlloc),
    ...
}
```

All heap allocations flow through Valkey's `zmalloc`, surfacing in `INFO MEMORY` and `maxmemory` eviction. This is why unit tests need `enable-system-alloc` to escape the dependency on a running server.

## Dependencies worth knowing

- `valkey-module 0.1.5` with features `min-valkey-compatibility-version-8-0` + `min-redis-compatibility-version-7-2`.
- `bloomfilter 3.0.1` with `serde` - core filter impl.
- `bincode 1.3` - BF.LOAD / AOF encoding.
- `rstest 0.23.0` (dev) - parameterized seed tests.

## `build.sh` pipeline

Driven by `SERVER_VERSION` env (`unstable` / `8.0` / `8.1` / `9.0`; defaults to `unstable` with warning). Steps:

1. `cargo fmt --check`.
2. `cargo clippy --profile release --all-targets -- -D clippy::all` (note: **stricter than CI**, which omits `-D`).
3. `cargo test --features enable-system-alloc`.
4. `RUSTFLAGS="-D warnings" cargo build --release` (adds `--features valkey_8_0` when `SERVER_VERSION=8.0`).
5. Clone / build valkey-server into `tests/build/binaries/<version>/`.
6. Clone `valkey-test-framework` into `tests/build/valkeytestframework/`.
7. `pip install -r requirements.txt` (installs `valkey`, `pytest==7.4.3`).
8. `pytest tests/` (with `tee` + ASAN scan when `ASAN_BUILD` set).

`./build.sh clean` removes `target/`, `tests/build/`, `test-data/`.

### Env vars

| Var | Required | Meaning |
|-----|----------|---------|
| `SERVER_VERSION` | yes | `unstable` / `8.0` / `8.1` / `9.0` |
| `ASAN_BUILD` | no | any value -> `make SANITIZER=address`, output piped through `tee`, grep for `LeakSanitizer: detected memory leaks` |
| `TEST_PATTERN` | no | pytest `-k` expression; works for ASAN and normal builds |

## build.sh vs CI differences

| Aspect | build.sh | CI |
|--------|----------|----|
| clippy | `-- -D clippy::all` | no `-D` |
| RUSTFLAGS | `-D warnings` always | unset |
| ASAN server make | `make -j SANITIZER=address` | adds `SERVER_CFLAGS='-Werror' BUILD_TLS=module` |
| ASAN test filter | all tests | `-m "not skip_for_asan"` |
| Server matrix | unstable, 8.0, 8.1, 9.0 | unstable, 8.0, 8.1 |
