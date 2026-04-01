# CI Pipeline

Use when debugging CI failures, understanding the CI matrix, adding new CI jobs, or working with the release workflow.

Source: `.github/workflows/ci.yml`, `.github/workflows/trigger-bloom-release.yml`

## Contents

- CI Overview (line 19)
- build-ubuntu-latest Job (line 33)
- build-macos-latest Job (line 75)
- asan-build Job (line 88)
- LeakSanitizer Detection (line 114)
- Release Trigger Workflow (line 142)
- Debugging CI Failures (line 162)

---

## CI Overview

The CI pipeline runs on every push and pull request. It has three jobs:

| Job | Runner | Matrix | Purpose |
|-----|--------|--------|---------|
| `build-ubuntu-latest` | ubuntu-latest | unstable, 8.0, 8.1 | Full pipeline: lint, build, unit tests, integration tests |
| `build-macos-latest` | macos-latest | none | Lint, build, unit tests only (no integration tests) |
| `asan-build` | ubuntu-latest | unstable, 8.0, 8.1 | Full pipeline with AddressSanitizer and LeakSanitizer |

All jobs use `fail-fast: false` so one matrix entry failing does not cancel others.

Global environment variables set on all jobs: `CARGO_TERM_COLOR=always`, `VALKEY_REPO_URL`, `TEST_FRAMEWORK_REPO`, `TEST_FRAMEWORK_DIR`.

## build-ubuntu-latest Job

This is the primary CI job. It runs the complete pipeline for each server version in the matrix.

**Steps in order**:

1. **Checkout** - `actions/checkout@v4`

2. **Set SERVER_VERSION** - writes `SERVER_VERSION=<matrix.server_version>` to `$GITHUB_ENV` so integration tests use the correct server binary.

3. **Format and lint checks** (note: no `-D clippy::all` unlike build.sh):
   ```bash
   cargo fmt --check
   cargo clippy --profile release --all-targets
   ```

4. **Release build** - conditional on server version (no `RUSTFLAGS` unlike build.sh):
   ```bash
   # For 8.0:
   cargo build --all --all-targets --release --features valkey_8_0
   # For unstable and 8.1:
   cargo build --all --all-targets --release
   ```

5. **Unit tests**:
   ```bash
   cargo test --features enable-system-alloc
   ```

6. **Build valkey-server** - clones `valkey-io/valkey` at the target version, builds with `make -j`, copies the binary to `tests/build/binaries/<version>/valkey-server`

7. **Set up test framework** - clones `valkey-io/valkey-test-framework`, copies `src/` contents to `tests/build/valkeytestframework/`

8. **Python setup** - Python 3.8 via `actions/setup-python@v3`, upgrades pip, installs `requirements.txt`

9. **Set MODULE_PATH** - sets the environment variable via `realpath target/release/libvalkey_bloom.so` into `$GITHUB_ENV`

10. **Integration tests**:
    ```bash
    python -m pytest --cache-clear -v "tests/"
    ```

## build-macos-latest Job

A lighter job that validates compilation and unit tests on macOS. No server version matrix - runs once.

**Steps**:

1. Checkout
2. Format and lint checks (`cargo fmt --check`, `cargo clippy --profile release --all-targets`)
3. Release build (`cargo build --all --all-targets --release`)
4. Unit tests (`cargo test --features enable-system-alloc`)

Integration tests are skipped because the CI does not build a macOS valkey-server binary.

## asan-build Job

Runs the full pipeline with AddressSanitizer enabled on the Valkey server binary. Uses the same matrix as the Ubuntu job (unstable, 8.0, 8.1).

**Key differences from the standard Ubuntu job**:

The Valkey server is built with sanitizer flags (note `SERVER_CFLAGS` and `BUILD_TLS` are CI-only - build.sh uses just `SANITIZER=address`):

```bash
make distclean
make -j SANITIZER=address SERVER_CFLAGS='-Werror' BUILD_TLS=module
```

Integration tests run with `--capture=sys`, pipe output through `tee`, and filter out ASAN-incompatible tests:

```bash
python -m pytest --capture=sys --cache-clear -v "tests/" \
    -m "not skip_for_asan" 2>&1 | tee test_output.tmp
```

The `-m "not skip_for_asan"` filter excludes tests marked with `@pytest.mark.skip_for_asan`. Currently, the `TestBloomDefrag` class in `test_bloom_defrag.py` is the only test excluded because `activedefrag` cannot be enabled on ASAN server builds.

After tests complete, the output is scanned for LeakSanitizer reports (see next section).

Note: The bloom module itself is built as a standard release binary without ASAN instrumentation. ASAN coverage applies to the Valkey server process. Memory leaks in the module are detected because the module's allocations (via ValkeyAlloc) flow through the server's instrumented allocator.

## LeakSanitizer Detection

After the ASAN integration tests finish, the CI scans `test_output.tmp` for memory leak reports:

```bash
if grep -q "LeakSanitizer: detected memory leaks" test_output.tmp; then
    LEAKING_TESTS=$(grep -B 2 "LeakSanitizer: detected memory leaks" test_output.tmp | \
                    grep -v "LeakSanitizer" | grep ".*\.py::")
    LEAK_COUNT=$(echo "$LEAKING_TESTS" | wc -l)
    echo "$LEAKING_TESTS" | while read -r line; do
        echo "::error::Test with leak: $line"
    done
    rm test_output.tmp
    exit 1
fi
rm test_output.tmp
```

If any leaks are detected, the job fails with GitHub Actions error annotations listing the specific test names and a count. The `build.sh` script contains equivalent logic for local ASAN builds.

To skip a test in ASAN builds, mark it at the class or method level:

```python
@pytest.mark.skip_for_asan(reason="Explanation of why this test is ASAN-incompatible")
class TestSomething(ValkeyBloomTestCaseBase):
    pass
```

## Release Trigger Workflow

The `trigger-bloom-release.yml` workflow runs when a GitHub release is published or via manual `workflow_dispatch`.

**Trigger conditions**:

- `release: types: [published]` - automatic on new release
- `workflow_dispatch` with `version` input (required) - manual trigger

**What it does**:

1. Determines the version from the release tag (`github.event.release.tag_name`) or the manual input (`inputs.version`)
2. Sends a `repository-dispatch` event to `valkey-io/valkey-bundle` with:
   - `event-type: bloom-release`
   - `client-payload: { "version": "<tag>", "component": "bloom" }`

This triggers the downstream valkey-bundle repository to update its bloom component reference.

The workflow uses a `secrets.EXTENSION_PAT` token for cross-repository dispatch via the `peter-evans/repository-dispatch@v3` action.

## Debugging CI Failures

**Lint failures** - Run locally with build.sh (stricter than CI due to `-D clippy::all`):
```bash
cargo fmt --check
cargo clippy --profile release --all-targets -- -D clippy::all
```

**Build failures for 8.0** - ensure the `valkey_8_0` feature flag is used. The `must_obey_client` wrapper in `src/wrapper/mod.rs` has conditional compilation (`#[cfg(feature = "valkey_8_0")]` vs `#[cfg(not(feature = "valkey_8_0"))]`).

**Integration test failures** - check which server version and seed mode failed. Every test runs twice (random-seed and fixed-seed) via `conftest.py`. A failure in only one mode usually indicates a seed-dependent bug.

**ASAN leak reports** - the leak is in the Valkey server process. Check if the leak originates from module code (bloom allocations) or server internals. Module allocations use ValkeyAlloc, so leaks show up under `zmalloc` in the stack trace.

**Flaky FP-rate tests** - correctness tests use a margin above the configured FP rate. If a test fails intermittently, the margin may need adjustment for the specific capacity/expansion combination. See `reference/architecture/bloom-object.md` for FP tightening details.

## See Also

- `reference/contributing/build.md` - build system, feature flags, and build.sh vs CI differences
- `reference/contributing/testing.md` - test framework and test file inventory
- `reference/commands/replication.md` - must_obey_client and valkey_8_0 conditional compilation
