# CI Pipeline

Use when understanding CI workflows, debugging CI failures, or adding new CI checks.

Source: `.github/workflows/`, `.devcontainer/Dockerfile`, `ci/build_ubuntu.sh`

## Contents

- [Overview](#overview)
- [Workflows](#workflows)
- [Docker Build Environment](#docker-build-environment)
- [Pre-built Dependencies](#pre-built-dependencies)
- [CI Scripts](#ci-scripts)
- [Clang Format Check](#clang-format-check)
- [Test Artifact Upload](#test-artifact-upload)
- [Endurance Test Configuration](#endurance-test-configuration)
- [CI Build Flow](#ci-build-flow)
- [Debugging CI Failures](#debugging-ci-failures)

## Overview

valkey-search runs 11 GitHub Actions workflows. Most test workflows use a Docker-based approach: they build a Docker image from `.devcontainer/Dockerfile` and execute tests inside the container. This ensures consistent tooling across local development and CI.

## Workflows

### On Every PR and Push to main/fulltext

| Workflow | File | What it does | Timeout |
|----------|------|-------------|---------|
| Unit Tests | `unittests.yml` | Builds module, runs all GoogleTest binaries | Default |
| Unit Tests (ASan) | `unittests-asan.yml` | Builds with AddressSanitizer, runs all unit tests | Default |
| Unit Tests (TSan) | `unittests-tsan.yml` | Builds with ThreadSanitizer, runs all unit tests | Default |
| Integration Tests | `integration_tests.yml` | Builds module, runs full Python integration suite | 140 min |
| Integration Tests (ASan) | `integration_tests-asan.yml` | Integration tests with AddressSanitizer | 140 min |

### On Source File Changes (PR and push to main/fulltext)

| Workflow | File | Trigger Paths | What it does |
|----------|------|--------------|-------------|
| Clang Format | `clang_tidy_format.yml` | `src/**`, `testing/**`, `vmsdk/src/**`, `vmsdk/testing/**` | Checks clang-format on modified `.cc`/`.h` files (excludes `third_party/` and `rax/`) |

### On All Pushes and PRs (no branch filter)

| Workflow | File | What it does |
|----------|------|-------------|
| Spellcheck | `spell_check.yml` | Runs `typos` with config from `.config/typos.toml` |

### On PR/Push to main Only

| Workflow | File | What it does |
|----------|------|-------------|
| macOS Build | `macos.yml` | Builds on macOS (build only, no tests) |

### Scheduled / Manual

| Workflow | File | Trigger | What it does |
|----------|------|---------|-------------|
| Endurance Tests | `endurance_tests.yml` | Daily at 09:00 UTC + manual | Long-running memtier_benchmark stability tests via `scripts/benchmark/run_endurance_test.sh` |
| Delete Old Workflows | `delete old workflows.yml` | Monthly (1st of month) | Cleans up workflow runs older than 90 days, keeps minimum 6 |
| Release Trigger | `trigger-search-release.yml` | On release publish + manual | Dispatches `search-release` event to `valkey-bundle` for extension packaging |

### Concurrency

All workflows use concurrency groups scoped to the branch/PR head ref with `cancel-in-progress: true`. This means pushing a new commit cancels any in-progress run for the same branch.

## Docker Build Environment

The `.devcontainer/Dockerfile` is based on Ubuntu 24.04 (Noble) and includes:

- GCC, CMake, Ninja
- clang-format, clang-tidy, clangd
- Python 3.12 with venv
- memtier-benchmark (from Redis packages)
- SSL development libraries

A `.devcontainer/setup.sh` script prepares the build context. The same Dockerfile is used for:
- CI workflows (built as `presubmit-image`)
- VS Code dev containers (configured via `devcontainer_base.json`)
- Endurance test runs (built as `endurance-test-image`)

## Pre-built Dependencies

CI speed is optimized by using pre-built `.deb` packages for the C++ dependencies (gRPC, Protobuf, Abseil, GoogleTest, HighwayHash). The `ci/build_ubuntu.sh` script:

1. Detects architecture (`amd64` or `arm64`) and distro via `lsb_release`
2. Downloads a platform-specific `.deb` from the GitHub releases page
3. Installs it to `/opt/valkey-search-deps/` (or `/opt/valkey-search-deps-asan/` for sanitizer builds)
4. Sets `CMAKE_PREFIX_PATH` to find the pre-built packages
5. Passes `--use-system-modules` to `build.sh` to skip building submodules from source

The deb naming convention is:
```
valkey-search-deps-{distro}-{codename}{san-suffix}-{arch}.deb
```

For example: `valkey-search-deps-ubuntu-noble-amd64.deb` or `valkey-search-deps-ubuntu-noble-asan-amd64.deb`.

## CI Scripts

| Script | Purpose |
|--------|---------|
| `ci/build_ubuntu.sh` | Main CI entry point - downloads deps, sets up env, calls `build.sh` |
| `ci/check_clang_format.sh` | Verifies a single file matches clang-format output |
| `ci/refresh_comp_db.sh` | Regenerates `compile_commands.json` for clang-tidy |
| `ci/check_changes.sh` | Utility for detecting changed files |
| `ci/entrypoint.sh` | Docker container entrypoint |
| `ci/asan.supp` | AddressSanitizer suppression rules |
| `ci/tsan.supp` | ThreadSanitizer suppression rules |

## Clang Format Check

The `clang_tidy_format.yml` workflow only checks files modified in the PR (not the entire codebase). It:

1. Determines the base branch (PR base or previous commit for pushes)
2. Builds the Docker image and generates `compile_commands.json` via `ci/refresh_comp_db.sh`
3. Finds modified `.cc` and `.h` files (excluding `third_party/` and `src/indexes/text/rax/`)
4. Runs `ci/check_clang_format.sh` on each file

Clang-tidy is defined in the workflow but currently disabled (pending codebase-wide tidy pass).

To format locally before pushing:

```bash
./build.sh --format
```

This formats files under `src/`, `testing/`, `vmsdk/src/`, and `vmsdk/testing/`, excluding `src/indexes/text/rax/`.

## Test Artifact Upload

All test workflows upload results as GitHub Actions artifacts:

| Workflow | Artifact Name | Contents |
|----------|--------------|----------|
| Unit tests | `unittest-results` | Test binaries output, `tests.out` |
| Integration tests | `integration-test-results` | Server logs, module binaries, test framework output |
| Endurance tests | `endurance-test-results-{run}` | Benchmark results (CSV, JSON), server logs, metadata |

Endurance test artifacts are retained for 90 days.

## Endurance Test Configuration

The endurance workflow accepts manual inputs for fine-grained control:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `branch_version` | unstable | Valkey server branch to test against |
| `enable_tls` | true | Enable TLS for benchmark connections |
| `test_duration` | 3600 (1 hour) | Test duration in seconds |
| `threads` | 10 | memtier benchmark threads |
| `clients` | 10 | memtier benchmark clients per thread |
| `pipeline_depth` | 1 | Command pipeline depth |
| `data_size` | 1024 | Data size in bytes |
| `workload_type` | mixed | mixed, read_only, or write_only |
| `keyspace_size` | 1000000 | Number of keys |

The test entry point is `scripts/benchmark/run_endurance_test.sh`, invoked inside the Docker container.

## CI Build Flow

The standard CI workflow for test jobs follows this sequence:

1. **Checkout** - clone the repository
2. **Docker build** - build the dev container image from `.devcontainer/Dockerfile`
3. **Run tests** - execute `ci/build_ubuntu.sh` inside the container with appropriate flags
4. **Upload artifacts** - save test output regardless of pass/fail

The `ci/build_ubuntu.sh` script is the bridge between GitHub Actions and the standard `build.sh`:

1. Detects architecture and distro for the correct `.deb` package
2. Downloads and installs pre-built dependencies if not cached
3. Enables core dumps (`ulimit -c unlimited`)
4. Sets `CMAKE_PREFIX_PATH` pointing to `/opt/valkey-search-deps/`
5. For integration-only runs, disables unit test binary compilation (`BUILD_UNIT_TESTS=OFF`)
6. Calls `build.sh --use-system-modules --test-errors-stdout` with the original CI flags

## Branch Targeting

Most PR/push workflows trigger on:
- Pull requests targeting `main` or `fulltext` branches
- Direct pushes to `main` or `fulltext` branches
- Manual `workflow_dispatch` trigger

Exceptions:
- The macOS workflow targets only `main`
- The spellcheck workflow triggers on all branches (no branch filter)
- The clang format workflow triggers only when source files change (path filters)

## Debugging CI Failures

1. Download the test artifact from the failed workflow run
2. For unit test failures, check `tests.out` in the artifact
3. For integration test failures, check server logs in `valkey-test-framework/`
4. For sanitizer failures, look for ASan/TSan reports in the test output
5. Reproduce locally using the same build flags:
   ```bash
   # Reproduce an ASan unit test failure
   ./build.sh --asan --run-tests --test-errors-stdout
   
   # Reproduce an integration test failure
   ./build.sh --run-integration-tests=test_name --retries=1
   ```

### Common CI Failure Patterns

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Clang format check fails | Source file not formatted | Run `./build.sh --format` and commit |
| ASan unit test fails with ODR violation | Duplicate symbol definitions | Suppressed via `ASAN_OPTIONS=detect_odr_violation=0`; check if new code introduces real duplicates |
| Integration test timeout (140 min) | Test deadlock or slow server startup | Check server logs in artifact, look for module load errors |
| macOS build fails | Platform-specific code or missing macOS guard | Check `#ifdef APPLE` guards and linker flags |
| Spellcheck fails | Typo in source or docs | Fix the typo or add to `.config/typos.toml` exceptions |

### Running the Full CI Locally

To approximate the full CI pipeline on a local machine:

```bash
# Build the Docker image
docker build -t presubmit-image -f .devcontainer/Dockerfile .

# Run unit tests (matching CI)
docker run --privileged --rm -v "$(pwd):/workspace" \
  --user "ubuntu:ubuntu" presubmit-image \
  sudo ci/build_ubuntu.sh --run-tests

# Run integration tests (matching CI)
docker run --privileged --rm -v "$(pwd):/workspace" \
  --user "ubuntu:ubuntu" presubmit-image \
  sudo ci/build_ubuntu.sh --run-integration-tests
```
