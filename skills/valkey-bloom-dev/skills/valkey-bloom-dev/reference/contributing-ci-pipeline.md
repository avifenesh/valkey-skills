# CI pipeline

Use when debugging CI failures, extending the matrix, or understanding the release-trigger workflow.

Source: `.github/workflows/ci.yml`, `.github/workflows/trigger-bloom-release.yml`.

## Jobs

Triggered on push and PR. `fail-fast: false` on all.

| Job | Runner | Matrix | Coverage |
|-----|--------|--------|----------|
| `build-ubuntu-latest` | ubuntu-latest | unstable, 8.0, 8.1 | lint + build + unit + integration |
| `build-macos-latest` | macos-latest | none | lint + build + unit (no integration - no server binary built on macOS) |
| `asan-build` | ubuntu-latest | unstable, 8.0, 8.1 | full pipeline with AddressSanitizer + LeakSanitizer scan |

Global env: `CARGO_TERM_COLOR`, `VALKEY_REPO_URL`, `TEST_FRAMEWORK_REPO`, `TEST_FRAMEWORK_DIR`.

## Ubuntu pipeline (outline)

1. `actions/checkout@v4`.
2. Export `SERVER_VERSION=<matrix>` into `$GITHUB_ENV`.
3. `cargo fmt --check` + `cargo clippy --profile release --all-targets` (no `-D clippy::all`, unlike build.sh).
4. `cargo build --all --all-targets --release` - adds `--features valkey_8_0` when `SERVER_VERSION=8.0`. No `RUSTFLAGS` (unlike build.sh).
5. `cargo test --features enable-system-alloc`.
6. Clone + build `valkey-io/valkey` at the target version; binary into `tests/build/binaries/<version>/`.
7. Clone `valkey-io/valkey-test-framework`, copy `src/` into `tests/build/valkeytestframework/`.
8. `actions/setup-python@v3` (3.8), `pip install -r requirements.txt`.
9. Export `MODULE_PATH=$(realpath target/release/libvalkey_bloom.so)`.
10. `python -m pytest --cache-clear -v tests/`.

## macOS pipeline

Checkout + format/lint + release build + `cargo test --features enable-system-alloc`. No integration tests, no matrix.

## ASAN pipeline - differences

Server built with sanitizer + TLS module:

```bash
make distclean
make -j SANITIZER=address SERVER_CFLAGS='-Werror' BUILD_TLS=module
```

(`SERVER_CFLAGS='-Werror'` and `BUILD_TLS=module` are CI-only; `build.sh` uses bare `SANITIZER=address`.)

Integration run:

```bash
python -m pytest --capture=sys --cache-clear -v "tests/" \
    -m "not skip_for_asan" 2>&1 | tee test_output.tmp
```

The module itself builds as a standard release binary - ASAN instruments the server process only. Because module allocations go through ValkeyAlloc (instrumented), leaks in module code still show up.

### LeakSanitizer detection

After pytest, scans `test_output.tmp`:

```bash
if grep -q "LeakSanitizer: detected memory leaks" test_output.tmp; then
    LEAKING_TESTS=$(grep -B 2 "LeakSanitizer: detected memory leaks" test_output.tmp \
                    | grep -v "LeakSanitizer" | grep ".*\.py::")
    echo "$LEAKING_TESTS" | while read -r line; do
        echo "::error::Test with leak: $line"
    done
    rm test_output.tmp
    exit 1
fi
```

Emits GitHub Actions `::error::` annotations listing offending tests. `build.sh` has equivalent local logic.

Skip incompatible tests at class or method level:

```python
@pytest.mark.skip_for_asan(reason="activedefrag not available on ASAN server")
class TestBloomDefrag(ValkeyBloomTestCaseBase):
    ...
```

## Release trigger (`trigger-bloom-release.yml`)

Triggers: `release: types: [published]` (auto) or `workflow_dispatch` with `version` input (manual).

Flow:

1. Resolve version from `github.event.release.tag_name` or `inputs.version`.
2. `peter-evans/repository-dispatch@v3` sends to `valkey-io/valkey-bundle`:
   ```yaml
   event-type: bloom-release
   client-payload: { "version": "<tag>", "component": "bloom" }
   ```

Uses `secrets.EXTENSION_PAT` for cross-repo dispatch. The bundle repo's listener updates its bloom component reference.

## Debug tips

- **Lint failures** - run locally with `build.sh` (stricter `-D clippy::all`).
- **8.0 build** - ensure `valkey_8_0` feature. `must_obey_client` in `src/wrapper/mod.rs` branches on `#[cfg(feature = "valkey_8_0")]`.
- **Integration failure in one seed mode only** - likely a seed-dependent bug. Every test runs both random-seed and fixed-seed via `conftest.py`.
- **ASAN leaks** - allocations flow through ValkeyAlloc, so module leaks trace through `zmalloc`.
- **Flaky FP rate tests** - correctness margin may be too tight for that capacity/expansion combo.
