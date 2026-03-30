# CI Pipeline

Use when you need to understand what CI checks run on your PR, diagnose CI failures, or run extended tests manually. For local build and test setup, see [Building Valkey](../build/building.md).

---

## Workflow Files

All CI configuration lives in `.github/workflows/`:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | Every push and PR | Core build and test matrix |
| `daily.yml` | Nightly cron, release branch PRs, on-demand | Extended test matrix |
| `clang-format.yml` | Every push and PR | Code formatting check |
| `spell-check.yml` | Push and PR | Spelling verification |
| `reply-schemas-linter.yml` | Push and PR | Command reply schema validation |
| `codeql-analysis.yml` | Push and PR | CodeQL security scanning |
| `codecov.yml` | Push and PR | Code coverage reporting |
| `coverity.yml` | Scheduled | Coverity static analysis |
| `external.yml` | Push, PR, and scheduled (cron) | Tests against external server |
| `benchmark-on-label.yml` | Label trigger | Performance benchmarks |
| `benchmark-release.yml` | On demand (workflow_dispatch) | Release benchmarks |
| `trigger-build-release.yml` | Tag push | Release build pipeline |
| `auto-author-assign.yml` | PR opened | Auto-assign PR author |
| `scorecard.yml` | Scheduled | OpenSSF Scorecard |
| `weekly.yml` | Weekly cron | Extended weekly checks |

## PR CI (ci.yml) - What Runs on Every PR

This is the primary CI gate. All jobs must pass before merge.

### Jobs

| Job | OS | What it does |
|-----|------|--------------|
| `test-ubuntu-latest` | Ubuntu latest | Build with `-Werror`, TLS, libbacktrace. Run integration tests (skip slow), module API tests, unit tests, validate commands.def |
| `test-ubuntu-latest-compatibility` | Ubuntu latest | Compatibility tests against Valkey 7.2, 8.0, 8.1 |
| `test-ubuntu-latest-cmake-tls` | Ubuntu latest | CMake build with TLS, run tests with `--tls`, unit tests |
| `test-sanitizer-address` | Ubuntu latest | ASan build with TLS module, integration tests, module API tests, unit tests ([details](../build/sanitizers.md)) |
| `test-rdma` | Ubuntu latest | RDMA module and builtin build, RDMA tests |
| `test-tls-only` | Ubuntu latest | TLS module and builtin builds, TLS-specific tests |
| `build-debian-old` | Debian Bullseye | Compilation check on older Debian |
| `build-macos-latest` | macOS latest | Compilation check with LLVM/Clang on macOS |
| `build-32bit` | Ubuntu latest | 32-bit cross-compilation, unit tests |
| `build-libc-malloc` | Ubuntu latest | Build with `MALLOC=libc` |
| `build-almalinux8-jemalloc` | AlmaLinux 8 | Build on RHEL-compatible OS |
| `format-yaml` | Ubuntu latest | YAML formatting check |

### Key CI Build Command

```
make -j4 all-with-unit-tests SERVER_CFLAGS='-Werror' BUILD_TLS=yes USE_LIBBACKTRACE=yes
```

### Test Commands in CI

```
# Integration tests (skip slow for speed)
./runtest --verbose --tags -slow --dump-logs

# Module API tests
CFLAGS='-Werror' ./runtest-moduleapi --verbose --dump-logs

# Unit tests
make test-unit

# Validate commands.def is up to date
touch src/commands/ping.json
make commands.def
git diff  # must be empty
```

## Clang Format Check (clang-format.yml)

Runs clang-format-18 on all `.c`, `.h`, `.cpp`, `.hpp` files in `src/`. The format rules are in `src/.clang-format`. If any file differs after formatting, the job fails with a diff.

To fix locally:

```
cd src
clang-format-18 -i **/*.c **/*.h **/*.cpp **/*.hpp
```

## Daily / Extended Tests (daily.yml)

These run on a schedule (midnight UTC), on PRs to release branches, and on unstable PRs (with `run-extra-tests` label). They can also be triggered manually via `workflow_dispatch`.

### When Daily Tests Run on PRs

- PRs to release branches (e.g., `8.0`, `8.1`) always run the daily matrix
- PRs to `unstable` run daily tests only when the `run-extra-tests` label is added

### Daily Job Categories

| Category | Jobs | What they test |
|----------|------|---------------|
| Ubuntu + jemalloc | `test-ubuntu-jemalloc` | Full test suite with `--accurate` |
| Ubuntu + ARM | `test-ubuntu-arm` | ARM architecture build and test |
| Fortify | `test-ubuntu-jemalloc-fortify` | `_FORTIFY_SOURCE=3` hardening |
| Allocators | `test-ubuntu-libc-malloc`, `test-ubuntu-no-malloc-usable-size` | Alternative allocator configurations |
| 32-bit | `test-ubuntu-32bit` | Full 32-bit test suite |
| TLS | `test-ubuntu-tls`, `test-ubuntu-tls-no-tls` | TLS with and without TLS tests |
| I/O threads | `test-ubuntu-io-threads`, `test-ubuntu-tls-io-threads` | Threaded I/O |
| Valgrind | `test-valgrind-test`, `test-valgrind-misc`, + no-malloc-usable-size variants | Memory checking |
| Sanitizers | `test-sanitizer-address`, `test-sanitizer-undefined`, + large-memory and force-defrag | ASan, UBSan (gcc + clang matrix) ([details](../build/sanitizers.md)) |
| macOS | `test-macos-latest` | Full test suite on macOS |
| FreeBSD | `test-freebsd` | FreeBSD build and test |
| Alpine | `test-alpine-jemalloc`, `test-alpine-libc-malloc` | musl libc build and test |
| RPM distros | `test-rpm-distros-jemalloc`, `test-rpm-distros-tls-module` | AlmaLinux 8, AlmaLinux 9, CentOS Stream 9, Fedora latest, Fedora rawhide |
| Reply schemas | `reply-schemas-validator` | Reply schema validation |
| LTTng | `test-ubuntu-lttng` | LTTng tracing build and test |
| Reclaim cache | `test-ubuntu-reclaim-cache` | Reclaim cache tests |
| macOS extended | `test-macos-latest-sentinel`, `test-macos-latest-cluster` | macOS Sentinel and Cluster tests |
| Old macOS | `build-old-macos-versions` | Build verification on older macOS versions |

### Running Daily Tests Manually

From your fork:

1. Go to **Actions** > **Daily**
2. Click **Run workflow**
3. Set `use_repo` to your fork (e.g., `youruser/valkey`)
4. Set `use_git_ref` to your branch
5. Set `skipjobs` to `none` for the full matrix (default skips most jobs)
6. Set `skiptests` to `none` for all test types

The `skipjobs` input controls which job groups run. The default value when triggered manually skips everything - delete the jobs you want to skip to keep the ones you want.

Available skip tokens: `valgrind`, `sanitizer`, `tls`, `freebsd`, `macos`, `alpine`, `32bit`, `iothreads`, `ubuntu`, `rpm-distros`, `malloc`, `specific`, `fortify`, `reply-schema`, `arm`, `lttng`.

Available test skip tokens: `valkey`, `modules`, `sentinel`, `cluster`, `unittest`, `large-memory`.

## CI Duration

| Job Type | Approximate Time |
|----------|-----------------|
| PR CI (ci.yml) | 15-30 minutes |
| Daily full suite | 2-8 hours |
| Valgrind tests | Up to 24 hours (timeout) |
| Sanitizer tests | 1-4 hours |

## Common Failure Patterns

### Clang Format

Symptom: `clang-format.yml` fails with a diff.

Fix: Run `clang-format-18 -i` on your changed files in `src/`.

### commands.def Out of Date

Symptom: CI step "validate commands.def up to date" fails.

Fix: Run `make commands.def` after changing any `.json` file in `src/commands/`.

### ASan Error

Symptom: `test-sanitizer-address` fails with AddressSanitizer output in logs.

Fix: The error report shows the exact memory error with a stack trace. Common causes are buffer overflows in SDS operations or use-after-free during object lifecycle.

### Flaky Test

Symptom: Test passes locally but fails intermittently in CI.

Fix: Run with `--loop` or `--loops 100` locally to reproduce. Timing-sensitive tests may need `wait_for_condition` instead of fixed delays.

### Compatibility Test Failure

Symptom: `test-ubuntu-latest-compatibility` fails.

Fix: Check that backward-compatible behavior is maintained when interacting with older Valkey versions. The `needs:other-server` tag controls which tests run in this mode.

## Required Checks

All jobs in `ci.yml` must pass for a PR to be mergeable. The daily tests are informational for `unstable` PRs but required for release branch PRs.

## See Also

- [Building Valkey](../build/building.md) - build commands and flags used by CI jobs
- [Sanitizer Builds](../build/sanitizers.md) - details on ASan, UBSan, TSan, and Valgrind CI configurations
- [Tcl Integration Tests](tcl-tests.md) - test runner options and tags (CI uses `--tags -slow` on PRs)
- [C++ Unit Tests](unit-tests.md) - unit test binary and `make test-unit`
- [Contribution Workflow](../contributing/workflow.md) - full contributor guide including the PR process and CI expectations
- [Module API Overview](../modules/api-overview.md) - the `test-sanitizer-address` CI job and `./runtest-moduleapi` validate module API tests. Module tests compile C test modules and exercise custom types, blocking commands, and scripting engines.
