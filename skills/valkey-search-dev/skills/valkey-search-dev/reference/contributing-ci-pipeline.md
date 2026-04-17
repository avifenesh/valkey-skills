# CI pipeline

Use when reasoning about CI workflows, debugging failures, or adding checks.

Source: `.github/workflows/`, `.devcontainer/Dockerfile`, `ci/build_ubuntu.sh`.

## Shape

11 GitHub Actions workflows. Most test workflows build a Docker image from `.devcontainer/Dockerfile` and run tests inside - consistent local + CI tooling.

### On every PR / push to `main` or `fulltext`

| Workflow | File | What | Timeout |
|----------|------|------|---------|
| Unit Tests | `unittests.yml` | GoogleTest binaries | default |
| Unit Tests (ASan) | `unittests-asan.yml` | AddressSanitizer unit | default |
| Unit Tests (TSan) | `unittests-tsan.yml` | ThreadSanitizer unit | default |
| Integration Tests | `integration_tests.yml` | Python suite | 140 min |
| Integration Tests (ASan) | `integration_tests-asan.yml` | | 140 min |

### On source file changes

| Workflow | Paths | Action |
|----------|-------|--------|
| Clang Format | `clang_tidy_format.yml` triggers on `src/**`, `testing/**`, `vmsdk/src/**`, `vmsdk/testing/**` | clang-format on modified `.cc`/`.h` (excludes `third_party/` + `rax/`) |

### All pushes / PRs (no branch filter)

| Workflow | Action |
|----------|--------|
| `spell_check.yml` | `typos` with `.config/typos.toml` |

### `main` only

| Workflow | Action |
|----------|--------|
| `macos.yml` | macOS build (no tests) |

### Scheduled / manual

| Workflow | Trigger | Action |
|----------|---------|--------|
| `endurance_tests.yml` | daily 09:00 UTC + manual | `scripts/benchmark/run_endurance_test.sh` |
| `delete old workflows.yml` | monthly (1st) | remove runs > 90 days, keep >= 6 |
| `trigger-search-release.yml` | release publish + manual | dispatch `search-release` to `valkey-bundle` |

### Concurrency

All workflows use concurrency groups scoped to branch/PR head ref with `cancel-in-progress: true` - new commit cancels in-progress runs.

## Docker environment

`.devcontainer/Dockerfile` = Ubuntu 24.04 (Noble). Includes GCC, CMake, Ninja, clang-format, clang-tidy, clangd, Python 3.12 + venv, memtier-benchmark (Redis packages), SSL dev libs.

`.devcontainer/setup.sh` preps context. Same Dockerfile serves:

- CI (`presubmit-image`).
- VS Code dev containers (`devcontainer_base.json`).
- Endurance (`endurance-test-image`).

## Pre-built deps

To speed up CI, C++ deps (gRPC, Protobuf, Abseil, GoogleTest, HighwayHash) come from pre-built `.deb`s. `ci/build_ubuntu.sh`:

1. Detect arch (`amd64` / `arm64`) + distro via `lsb_release`.
2. Download platform-specific `.deb` from GitHub releases.
3. Install to `/opt/valkey-search-deps/` (or `-asan/` for SAN).
4. Set `CMAKE_PREFIX_PATH`.
5. Pass `--use-system-modules` to `build.sh` to skip submodule build.

Naming: `valkey-search-deps-<distro>-<codename>[-<san>]-<arch>.deb`. Examples: `valkey-search-deps-ubuntu-noble-amd64.deb`, `valkey-search-deps-ubuntu-noble-asan-amd64.deb`.

## CI scripts

| Script | Purpose |
|--------|---------|
| `ci/build_ubuntu.sh` | main CI entry - deps + env + `build.sh` |
| `ci/check_clang_format.sh` | per-file clang-format check |
| `ci/refresh_comp_db.sh` | regenerates `compile_commands.json` for clang-tidy |
| `ci/check_changes.sh` | changed-file detection |
| `ci/entrypoint.sh` | Docker container entrypoint |
| `ci/asan.supp` | ASan suppressions |
| `ci/tsan.supp` | TSan suppressions |

## Clang format

`clang_tidy_format.yml` checks only PR-modified files, not the whole tree.

1. Determine base branch (PR base or previous commit for pushes).
2. Build Docker image, `ci/refresh_comp_db.sh` for `compile_commands.json`.
3. Find modified `.cc` / `.h` (exclude `third_party/`, `src/indexes/text/rax/`).
4. `ci/check_clang_format.sh` per file.

clang-tidy is defined in the workflow but currently disabled (pending codebase-wide tidy pass).

Local: `./build.sh --format`. Formats `src/`, `testing/`, `vmsdk/src/`, `vmsdk/testing/` (excludes `src/indexes/text/rax/`).

## Artifacts

| Workflow | Name | Contents |
|----------|------|----------|
| Unit | `unittest-results` | `tests.out`, binaries' output |
| Integration | `integration-test-results` | server logs, module binaries, framework output |
| Endurance | `endurance-test-results-{run}` | benchmark CSV/JSON, server logs, metadata (90-day retention) |

## Endurance inputs

| Param | Default |
|-------|---------|
| `branch_version` | `unstable` |
| `enable_tls` | true |
| `test_duration` | 3600 s |
| `threads` | 10 |
| `clients` | 10 (per thread) |
| `pipeline_depth` | 1 |
| `data_size` | 1024 |
| `workload_type` | `mixed` (or `read_only` / `write_only`) |
| `keyspace_size` | 1 000 000 |

Entry: `scripts/benchmark/run_endurance_test.sh` inside the container.

## Standard test-job sequence

1. Checkout.
2. Build dev container image.
3. Run `ci/build_ubuntu.sh` with flags inside container.
4. Upload artifacts (pass or fail).

`ci/build_ubuntu.sh` bridges GH Actions and `build.sh`:

1. Detect arch/distro for correct `.deb`.
2. Download + install pre-built deps if not cached.
3. `ulimit -c unlimited` (core dumps).
4. `CMAKE_PREFIX_PATH` -> `/opt/valkey-search-deps/`.
5. Integration-only runs: `BUILD_UNIT_TESTS=OFF`.
6. `build.sh --use-system-modules --test-errors-stdout` + original CI flags.

## Branch targeting

Most workflows: PR to `main` / `fulltext`, pushes to `main` / `fulltext`, manual `workflow_dispatch`.

Exceptions:

- macOS: `main` only.
- Spellcheck: all branches.
- Clang format: path-filter triggered (source file changes only).

## Debugging

1. Download failed artifact.
2. Unit: check `tests.out`.
3. Integration: server logs in `valkey-test-framework/`.
4. SAN: look for ASan/TSan reports in test output.
5. Local repro:
   ```bash
   ./build.sh --asan --run-tests --test-errors-stdout
   ./build.sh --run-integration-tests=test_name --retries=1
   ```

### Common patterns

| Symptom | Cause | Fix |
|---------|-------|-----|
| Clang format fails | unformatted file | `./build.sh --format` + commit |
| ASan ODR violation | duplicate symbols | suppressed via `ASAN_OPTIONS=detect_odr_violation=0`; check for real duplicates |
| Integration 140 min timeout | deadlock / slow startup | check server logs for module load errors |
| macOS build fails | platform-specific code / missing guard | check `#ifdef APPLE` + linker flags |
| Spellcheck fails | typo | fix or add to `.config/typos.toml` |

### Run full CI locally

```bash
docker build -t presubmit-image -f .devcontainer/Dockerfile .

docker run --privileged --rm -v "$(pwd):/workspace" \
  --user "ubuntu:ubuntu" presubmit-image \
  sudo ci/build_ubuntu.sh --run-tests

docker run --privileged --rm -v "$(pwd):/workspace" \
  --user "ubuntu:ubuntu" presubmit-image \
  sudo ci/build_ubuntu.sh --run-integration-tests
```
