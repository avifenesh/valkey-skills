# CI Pipeline

Use when debugging CI failures, understanding the test matrix, adding CI jobs, or investigating ASAN leak reports in valkey-json.

Source: `.github/workflows/ci.yml` in valkey-io/valkey-json

## Contents

- [Overview](#overview)
- [Server Version Matrix](#server-version-matrix)
- [Job Types](#job-types)
- [Total CI Matrix](#total-ci-matrix)
- [ASAN Leak Detection](#asan-leak-detection)
- [Additional Workflows](#additional-workflows)
- [Debugging CI Failures](#debugging-ci-failures)

## Overview

The CI pipeline runs on every push and pull request. It defines four job types, each running across a matrix of Valkey server versions. All jobs run on `ubuntu-latest`.

## Server Version Matrix

Every job tests against these Valkey versions:

| Version | Branch/Tag |
|---------|------------|
| unstable | Latest development branch |
| 8.0 | Valkey 8.0.x stable |
| 8.1 | Valkey 8.1.x stable |
| 9.0 | Valkey 9.0.x stable |

The matrix uses `fail-fast: false` so all version combinations run even if one fails.

## Job Types

### 1. build-release

Validates that the module compiles cleanly against each server version.

```yaml
steps:
  - Set SERVER_VERSION from matrix
  - Run ./build.sh
```

Runs `./build.sh` with default flags (release mode). Produces `build/src/libjson.so`. No tests executed - this job catches compile errors and warnings (remember `-Werror` is on).

### 2. unit-tests

Builds the module and runs GoogleTest unit tests.

```yaml
steps:
  - Set SERVER_VERSION from matrix
  - Run ./build.sh --unit
```

Compiles the `unitTests` binary and executes all unit tests. Tests run without a Valkey server using the module simulation layer.

### 3. integration-tests

Builds the module and server, then runs the pytest integration suite.

```yaml
steps:
  - Set SERVER_VERSION from matrix
  - Set up Python 3.9
  - pip install -r requirements.txt
  - Run ./build.sh --integration
```

This job:
1. Builds valkey-server from the specified version tag
2. Fetches the valkey-test-framework
3. Builds the JSON module
4. Installs Python dependencies (valkey, pytest, pytest-html)
5. Runs the full integration test suite against the built server

### 4. asan-tests

Runs integration tests with AddressSanitizer enabled for memory safety validation.

```yaml
steps:
  - Set SERVER_VERSION from matrix
  - Set up Python 3.9
  - pip install -r requirements.txt
  - export ASAN_BUILD=true
  - Run ./build.sh --integration
```

This job is identical to integration-tests except:
- `ASAN_BUILD=true` is exported before build.sh
- The module and server are compiled with `-fsanitize=address`
- CMake build type is `Debug` instead of `Release`
- After tests run, `run.sh` scans output for `LeakSanitizer: detected memory leaks`
- If leaks are found, the job identifies which test functions leaked and fails

## Total CI Matrix

4 jobs x 4 server versions = 16 parallel job runs per push/PR.

| Job | Versions | Python | ASAN |
|-----|----------|--------|------|
| build-release | 4 | No | No |
| unit-tests | 4 | No | No |
| integration-tests | 4 | 3.9 | No |
| asan-tests | 4 | 3.9 | Yes |

## ASAN Leak Detection

The ASAN job uses a two-phase approach:

1. **Compile-time** - `-fsanitize=address` instruments all allocations in both the JSON module and the Valkey server
2. **Runtime detection** - LeakSanitizer runs at process exit and reports unreleased memory
3. **CI enforcement** - `run.sh` captures test output, greps for leak reports, extracts the test function names, and exits non-zero if any leaks are found

When investigating ASAN failures:
- Check the CI log for `LeakSanitizer: detected memory leaks`
- The lines above the leak report show which test triggered it
- Reproduce locally: `ASAN_BUILD=true TEST_PATTERN="test_name" ./build.sh --integration`

## Additional Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `spell-check.yml` | push, PR | Spell checking on documentation and comments |
| `trigger-json-release.yml` | manual | Triggers release build pipeline |

## Debugging CI Failures

### Build failures
- Check compiler flags - `-Werror` means warnings are errors
- Verify the Valkey version tag exists (matrix value must match a git tag)
- Check for architecture-specific issues (CI runs x86_64)

### Unit test failures
- Reproduce with `SERVER_VERSION=<ver> ./build.sh --unit`
- Run specific test: `./build/tst/unit/unitTests --gtest_filter="TestName"`
- Check `malloced` counter in module_sim for leak detection

### Integration test failures
- Reproduce with `SERVER_VERSION=<ver> ./build.sh --integration`
- Filter to failing test: `TEST_PATTERN="test_name" ./build.sh --integration`
- Check if the server binary built correctly in `.build/binaries/<version>/`

### ASAN failures
- Reproduce with `ASAN_BUILD=true ./build.sh --integration`
- Look at the allocation stack trace in the leak report
- Common causes: missing `dom_free`, unreleased JDocument, keytable ref count imbalance

## See Also

- [build.md](build.md) - Build system details and options
- [testing.md](testing.md) - Test infrastructure and writing tests
- [adding-commands.md](adding-commands.md) - New commands must pass all CI jobs
- [rdb-format.md](../persistence/rdb-format.md) - RDB format tested by test_rdb.py in CI
- [memory-layers.md](../document/memory-layers.md) - Memory architecture relevant to ASAN leak investigations
