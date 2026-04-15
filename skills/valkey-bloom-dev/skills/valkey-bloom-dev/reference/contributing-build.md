# Build System

Use when building valkey-bloom from source, understanding Cargo configuration, feature flags, build.sh usage, or troubleshooting build issues.

Source: `Cargo.toml`, `build.sh`, `src/lib.rs`

## Crate Configuration

The crate produces a C-compatible dynamic library loaded by the Valkey server at runtime:

```toml
[package]
name = "valkey-bloom"
version = "99.99.99-dev"
edition = "2021"
license = "BSD-3-Clause"

[lib]
crate-type = ["cdylib"]
name = "valkey_bloom"
```

The `cdylib` crate type produces a `.so` on Linux or `.dylib` on macOS. The library name `valkey_bloom` maps to output files `libvalkey_bloom.so` / `libvalkey_bloom.dylib`.

The Cargo version (`99.99.99-dev`) is a placeholder replaced during release. The MODULE_VERSION constant in `src/lib.rs` is `999999` (an i32 for the module API), also replaced at release time.

The dev profile enables full debug info (`debug = 2`), debug assertions, and no optimization (`opt-level = 0`). No `[profile.release]` is defined, so the release profile uses Cargo defaults (opt-level 3, no debug).

## Dependencies

Runtime dependencies:

| Crate | Version | Purpose |
|-------|---------|---------|
| `valkey-module` | 0.1.5 | Valkey Module API bindings (with `min-valkey-compatibility-version-8-0` and `min-redis-compatibility-version-7-2` features) |
| `valkey-module-macros` | 0 | Proc macros for `#[info_command_handler]` |
| `linkme` | 0 | Distributed slice registration for macros |
| `bloomfilter` | 3.0.1 | Core bloom filter implementation (with `serde` feature for serialization) |
| `lazy_static` | 1.4.0 | Static initialization of configs and metrics |
| `libc` | 0.2 | C types for FFI callbacks |
| `serde` | 1.0 | Serialization framework (with `derive` feature) |
| `bincode` | 1.3 | Binary encoding for BF.LOAD / AOF rewrite |

Dev-only dependencies (used in unit tests):

| Crate | Version | Purpose |
|-------|---------|---------|
| `rand` | 0.8 | Random string generation for test items |
| `rstest` | 0.23.0 | Parameterized test cases (random vs fixed seed) |

## Feature Flags

```toml
[features]
default = ["min-valkey-compatibility-version-8-0"]
enable-system-alloc = ["valkey-module/enable-system-alloc"]
min-valkey-compatibility-version-8-0 = []
valkey_8_0 = []
use-redismodule-api = []
```

**default** - Enables `min-valkey-compatibility-version-8-0`. This is always on for standard builds.

**enable-system-alloc** - Switches from Valkey's allocator to the system allocator. Required for unit tests because ValkeyAlloc is unavailable outside of a running Valkey server. Always pass `--features enable-system-alloc` when running `cargo test`.

**valkey_8_0** - Enables compatibility with Valkey 8.0. By default the module targets Valkey 8.1+ and uses the `ValkeyModule_MustObeyClient` API. When this flag is set, the module falls back to checking `ContextFlags::REPLICATED` instead (see `reference/commands/replication.md`). Pass this flag when building for Valkey 8.0:

```bash
cargo build --release --features valkey_8_0
```

**use-redismodule-api** - Empty stub. Exists to prevent build errors if the feature is passed by tooling. Not functional.

## ValkeyAlloc Global Allocator

The module registers Valkey's allocator as the global Rust allocator via the `valkey_module!` macro:

```rust
valkey_module! {
    allocator: (valkey_module::alloc::ValkeyAlloc, valkey_module::alloc::ValkeyAlloc),
    // ...
}
```

All Rust heap allocations route through Valkey's `zmalloc`/`zfree`, enabling accurate memory tracking in `INFO MEMORY` and correct behavior with `maxmemory` eviction policies. See `reference/architecture/bloom-object.md` for how memory limits interact with ValkeyAlloc.

Because ValkeyAlloc requires a running Valkey server, unit tests must use `--features enable-system-alloc` to substitute the system allocator. Integration tests load the module into a real server and use ValkeyAlloc normally.

## Build Commands

**Debug build** (fast compilation, debug symbols):

```bash
cargo build
```

**Release build** (optimized, used for integration tests):

```bash
cargo build --all --all-targets --release
```

**Release build for Valkey 8.0** (build.sh uses RUSTFLAGS; CI does not):

```bash
RUSTFLAGS="-D warnings" cargo build --all --all-targets --release --features valkey_8_0
```

**Unit tests** (must use system allocator):

```bash
cargo test --features enable-system-alloc
```

**Format and lint checks** (build.sh adds `-D clippy::all`; CI does not):

```bash
cargo fmt --check
cargo clippy --profile release --all-targets -- -D clippy::all   # build.sh
cargo clippy --profile release --all-targets                      # CI
```

## build.sh Script

The `build.sh` script automates the full pipeline locally: format checks, unit tests, server build, and integration tests.

**Usage**:

```bash
# Full pipeline (set SERVER_VERSION first)
export SERVER_VERSION=unstable   # or 8.0, 8.1, 9.0
./build.sh

# Clean build artifacts (removes target/, tests/build/, test-data/)
./build.sh clean
```

**Environment variables**:

| Variable | Required | Description |
|----------|----------|-------------|
| `SERVER_VERSION` | Yes | Target Valkey version: `unstable`, `8.0`, `8.1`, or `9.0`. Defaults to `unstable` with a warning if unset |
| `ASAN_BUILD` | No | When set (any value), builds Valkey server with `SANITIZER=address` and enables LeakSanitizer detection in test output |
| `TEST_PATTERN` | No | pytest `-k` expression to run specific tests (e.g., `TEST_PATTERN=test_replication`). Works for both ASAN and normal builds |

**Pipeline steps** (in order):

1. `cargo fmt --check` and `cargo clippy --profile release --all-targets -- -D clippy::all` - format and lint checks
2. `cargo test --features enable-system-alloc` - unit tests
3. `RUSTFLAGS="-D warnings" cargo build --release` - release build (adds `--features valkey_8_0` if SERVER_VERSION is 8.0)
4. Clone and build valkey-server from source (cached in `tests/build/binaries/<version>/`)
5. Clone valkey-test-framework into `tests/build/valkeytestframework/`
6. `pip install -r requirements.txt` - install Python test dependencies (`valkey`, `pytest==7.4.3`)
7. `pytest tests/` - run integration tests (with `--capture=sys` and `tee` for ASAN builds)

When `ASAN_BUILD` is set, the script pipes test output through `tee` and scans for `LeakSanitizer: detected memory leaks`. If leaks are found, it reports the offending tests and exits with code 1.

## build.sh vs CI Differences

The build.sh script and GitHub Actions CI have minor differences:

| Aspect | build.sh | CI |
|--------|----------|-----|
| clippy flags | `-- -D clippy::all` | no `-D` flag |
| RUSTFLAGS | `RUSTFLAGS="-D warnings"` on all builds | not set |
| ASAN server build | `make -j SANITIZER=address` | adds `SERVER_CFLAGS='-Werror' BUILD_TLS=module` |
| ASAN test filter | runs all tests | `-m "not skip_for_asan"` to exclude defrag tests |
| Server versions | unstable, 8.0, 8.1, 9.0 | unstable, 8.0, 8.1 |

## Output Artifacts

| Platform | Path |
|----------|------|
| Linux | `target/release/libvalkey_bloom.so` |
| macOS | `target/release/libvalkey_bloom.dylib` |

Load the module in Valkey:

```
loadmodule /path/to/libvalkey_bloom.so
```