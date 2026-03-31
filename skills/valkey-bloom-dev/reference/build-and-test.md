# Build and Test

Use when building valkey-bloom from source, running tests, debugging CI failures, or setting up a local development environment.

## Prerequisites

- Rust toolchain (stable): `curl https://sh.rustup.rs -sSf | sh`
- Clang: `sudo yum install clang` (or equivalent)
- Python 3.8+ with pip (for integration tests)
- A Valkey server binary (built from source for integration tests)

## Cargo Build

```bash
# Default: builds for Valkey >= 8.1
cargo build --release

# For Valkey 8.0 compatibility
cargo build --release --features valkey_8_0
```

Output: `target/release/libvalkey_bloom.so` (Linux) or `libvalkey_bloom.dylib` (macOS).

The crate type is `cdylib` (C-compatible dynamic library), named `valkey_bloom`.

## Feature Flags

| Flag | Purpose |
|------|---------|
| `min-valkey-compatibility-version-8-0` | Default. Minimum server API level |
| `valkey_8_0` | Build for Valkey 8.0 (uses `get_flags()` instead of `MustObeyClient`) |
| `enable-system-alloc` | Use system allocator (required for unit tests) |
| `use-redismodule-api` | Stub flag, intentionally empty |

## Format and Lint Checks

```bash
cargo fmt --check
cargo clippy --profile release --all-targets -- -D clippy::all
```

CI runs these before any build step. Fix all clippy warnings before submitting.

## Unit Tests

```bash
cargo test --features enable-system-alloc
```

The `enable-system-alloc` feature is required because unit tests run without a Valkey server, so `ValkeyAlloc` is not available.

Unit tests live in `src/bloom/utils.rs` under `#[cfg(test)] mod tests`. They test:
- Non-scaling filter behavior (fill to capacity, reject overflow)
- Scaling filter behavior (auto scale-out, multi-filter correctness)
- False positive rate validation with margin
- Encode/decode round-trip via bincode serialization
- Copy correctness
- Seed behavior (random vs fixed)
- Server version validation

Test helpers: `add_items_till_capacity`, `check_items_exist`, `fp_assert`, `verify_restored_items`.

Uses the `rstest` crate for parameterized tests (random seed vs fixed seed cases).

## Integration Tests

Integration tests use Python + pytest and require a running Valkey server with the module loaded.

### Setup

```bash
# Set server version
export SERVER_VERSION=unstable  # or 8.0, 8.1, 9.0

# Install Python deps
pip install -r requirements.txt  # valkey, pytest==7.4.3
```

### Running

The `build.sh` script handles the full pipeline:

```bash
# Full pipeline: fmt, clippy, unit tests, build, compile valkey, run integration tests
SERVER_VERSION=unstable ./build.sh

# Clean all artifacts
./build.sh clean
```

Or run integration tests directly (after building):

```bash
export MODULE_PATH=$(pwd)/target/release/libvalkey_bloom.so
python3 -m pytest --cache-clear -v tests/

# Run specific test pattern
TEST_PATTERN="test_bloom_basic" python3 -m pytest --cache-clear -v tests/ -k "$TEST_PATTERN"
```

### Test Framework

Integration tests use `valkey-test-framework` (cloned during `build.sh`):
- Base class: `ValkeyBloomTestCaseBase` in `tests/valkey_bloom_test_case.py`
- Extends `ValkeyTestCase` from the framework
- Auto-parameterized on seed mode (random-seed / fixed-seed) via `conftest.py`

### Test Files

| File | Coverage |
|------|----------|
| `test_bloom_basic.py` | Core BF.ADD, BF.EXISTS, BF.RESERVE, BF.INFO, BF.INSERT |
| `test_bloom_command.py` | Command argument parsing, error cases |
| `test_bloom_correctness.py` | FP rate validation, scaling correctness |
| `test_bloom_save_and_restore.py` | RDB save/load, BF.LOAD round-trip |
| `test_bloom_aofrewrite.py` | AOF rewrite and recovery |
| `test_bloom_replication.py` | Primary-replica sync, deterministic replication |
| `test_bloom_keyspace.py` | Keyspace notifications |
| `test_bloom_acl_category.py` | ACL category ("bloom") enforcement |
| `test_bloom_metrics.py` | INFO bf metrics validation |
| `test_bloom_defrag.py` | Defragmentation callbacks |
| `test_bloom_valkeypy_compatibility.py` | valkey-py client library compatibility |

### Test Helper Methods

The `ValkeyBloomTestCaseBase` class provides:
- `verify_error_response(client, cmd, expected_err)` - assert error message
- `verify_command_success_reply(client, cmd, expected)` - assert success
- `add_items_till_capacity(client, name, capacity, ...)` - batch add with BF.MADD
- `check_items_exist(client, name, start, end, ...)` - batch check with BF.MEXISTS
- `fp_assert(errors, ops, fp_rate, margin)` - FP rate assertion
- `validate_copied_bloom_correctness(...)` - COPY + digest validation

## CI Pipeline

GitHub Actions (`.github/workflows/ci.yml`):

| Job | Matrix | What it does |
|-----|--------|-------------|
| `build-ubuntu-latest` | unstable, 8.0, 8.1 | fmt, clippy, build, unit tests, compile valkey, integration tests |
| `build-macos-latest` | (none) | fmt, clippy, build, unit tests only |
| `asan-build` | unstable, 8.0, 8.1 | Same as ubuntu + AddressSanitizer build, leak detection |

The ASAN job builds Valkey with `SANITIZER=address` and checks test output for `LeakSanitizer: detected memory leaks`.

## ASAN Build

```bash
export ASAN_BUILD=true
export SERVER_VERSION=unstable
./build.sh
```

This compiles Valkey with AddressSanitizer and scans integration test output for leak reports.
