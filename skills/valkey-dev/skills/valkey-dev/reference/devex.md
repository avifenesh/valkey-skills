# Developer Experience: Build, Test, Config-System, Contributing

How to build, test, add configs, and land a PR.

## Contribution workflow

- PRs target **`unstable`**.
- **DCO sign-off** on every commit: `git commit -s`. CI blocks without it.
- **Formatter**: `clang-format-18` (config: `src/.clang-format`). CI enforces the exact version - different clang-format versions produce diffs that fail the check.
- **New source files**: BSD-3-Clause header with `Copyright (c) Valkey Contributors` (patterns visible by grepping existing `.c` / `.h` headers).
- **Tests required** - TCL for integration, gtest for unit (see sections below).
- **Docs** live in a separate repo (`valkey-io/valkey-doc`); add label `needs-doc-pr` on user-facing changes.
- **Keep PRs small** - backporting to stable branches is routine and easier with focused diffs.

## Governance (agent-relevant)

- Technical major decisions (new APIs, data structures, breaking changes) need TSC approval - simple majority, with a two-week no-objections fast path.
- Org diversity rule: max 1/3 of TSC from the same employer. Expect review comments from TSC reviewers at different orgs; a single LGTM isn't enough for major changes.
- Membership + escalation path: `MAINTAINERS.md`.
- License: BSD-3-Clause for code; CC-BY-4.0 for the governance doc.

## Build (`src/Makefile`, `CMakeLists.txt`)

make/cmake driver is standard. Non-obvious:

### Makefile variables

| Variable | Default | Non-obvious behavior |
|----------|---------|----------------------|
| `USE_REDIS_SYMLINKS` | `yes` | Installs `redis-*` symlinks next to `valkey-*` binaries. Set `no` to skip. |
| `BUILD_TLS` | unset | `yes` = linked; `module` = `valkey-tls<PROG_SUFFIX>.so`. |
| `BUILD_RDMA` | unset | `yes` = linked; `module` = `valkey-rdma<PROG_SUFFIX>.so`. Linux only. |
| `BUILD_LUA` | yes (implicit) | `no` drops the Lua module build entirely. |
| `PROG_SUFFIX` | empty | Suffixes **every** produced binary and module `.so`. |
| `REDIS_CFLAGS` / `REDIS_LDFLAGS` | - | Aliases for `SERVER_CFLAGS` / `SERVER_LDFLAGS` (backward-compat). |

### CMake mismatch vs Makefile

`cmake/Modules/ValkeySetup.cmake` handles `BUILD_TLS` and `BUILD_RDMA` asymmetrically:
- `BUILD_TLS`: accepts only `ON`/`OFF`. Passing `module` triggers a warning and disables TLS.
- `BUILD_RDMA`: accepts `ON`/`OFF`/`module` (parsed to `USE_RDMA = 1|2`).

Makefile accepts `module` for both.

### Non-obvious artifacts

- `src/unit/valkey-unit-gtests` - C++ / GoogleTest unit binary. Requires `make all-with-unit-tests`; run with `make test-unit`.
- `src/modules/lua/libvalkeylua.so` - the Lua engine is a module, not a static part of the server.
- `deps/libvalkey/` - Valkey's own hiredis fork, statically linked for TLS/RDMA client libs and used by tests.

### Targets worth knowing beyond `make && make test`

- `make all-with-unit-tests` - build including gtests.
- `make test-unit` - run the gtests via `gtest-parallel`.
- `make distclean` - also cleans `deps/` (needed when switching sanitizer mode or `MALLOC`).

## Sanitizer builds

`make SANITIZER=address|undefined|thread` is standard. Valkey-specific:

### Allocator override

| Sanitizer | Makefile forces `MALLOC=` |
|-----------|---------------------------|
| `address` | `libc` |
| `undefined` | `libc` |
| `thread` | (no override - jemalloc stays) |

Run `make distclean` between modes - objects compiled against jemalloc can't be re-linked when `MALLOC=libc` kicks in.

### Test framework scrapes sanitizer output

`check_sanitizer_errors` (`tests/support/server.tcl`) runs after every server stops in the TCL integration suite. It calls `sanitizer_errors_from_file` (`tests/support/util.tcl`) which matches `Sanitizer` OR `runtime error` in stderr (GCC UBSAN uses the second form). Huge-alloc warnings `AddressSanitizer failed to allocate` are filtered out.

A sanitizer finding that reaches stderr will fail the test even if the server didn't crash. For a legitimate suppression, update the filter in `util.tcl` rather than silencing stderr.

## TCL Test Framework

Standard TCL test harness (`tests/support/test.tcl`, `tests/support/server.tcl`). Baseline idioms (`start_server {tags {...}}`, `r` as client proc, `assert_equal` / `assert_error` / `assert_match` / `assert_encoding`, `wait_for_condition`) are agent-knowable.

Valkey-specific:

- **Test directories**: `tests/unit/` (commands), `tests/unit/cluster/`, `tests/unit/moduleapi/`, `tests/integration/` (replication, persistence, sentinel).
- **`check_sanitizer_errors` auto-runs on every server stop** - see sanitizers above.
- **`run_solo`** reserves exclusive access to the test runner (large memory, specific ports). Use sparingly.

### Test runner entry points

- `./runtest` - core integration
- `./runtest-cluster` - legacy cluster tests (the `tests/cluster/` tree, not `tests/unit/cluster/`)
- `./runtest-moduleapi` - module API tests
- `./runtest-sentinel` - Sentinel tests

Flags: `--single unit/file`, `--only "name"`, `--tags -slow` (CI default), `--verbose`, `--dump-logs`, `--tls`, `--io-threads`, `--valgrind`, `--loop`, `--accurate`, `--clients N`.

Tags: `slow` excluded in PR CI. Others: `needs:debug`, `needs:other-server`, `large-memory`. Exclude with `-<tag>`, include (AND) with `<tag>`. Runner logic: `tests/test_helper.tcl`.

## C++ Unit Tests (Valkey-only)

Redis has no gtest suite. Valkey added one at `src/unit/`.

- Framework: Google Test + Google Mock.
- Binary: `src/unit/valkey-unit-gtests` - built by `make all-with-unit-tests`.
- Run: `make test-unit` (uses `deps/gtest-parallel/`). Filter: `--gtest_filter="SdsTest.*"`.
- Custom flags: `--accurate` (longer runs), `--large-memory`, `--seed <N>`.
- Coverage today: SDS, dict, hashtable, intset, listpack, quicklist, rax, kvstore, bitops, CRC, SHA, zmalloc, networking, object, entry, vector.

When writing a new test:
- File: `src/unit/test_mymodule.cpp`.
- Wrap any C headers in `extern "C"`.
- Use `wrappers.h` for function mocking (linker-level wrap via `--wrap=<sym>`; see `src/unit/wrappers.h` + `generated_wrappers.o`).

## CI

`.github/workflows/ci.yml` (PR gate) and `.github/workflows/daily.yml` (extended).

### PR gate

Builds with `SERVER_CFLAGS='-Werror'`, runs:
- `./runtest --verbose --tags -slow --dump-logs` (integration)
- `make test-unit` (gtest)
- `make test-moduleapi`
- Commands table consistency: `make commands.def` must leave no diff (regenerated from `src/commands/*.json` by `utils/generate-command-code.py`).
- `clang-format-18 -i` must leave no diff.
- Matrix: ASan, TLS, RDMA, 32-bit, macOS.

### Daily

Required for release-branch PRs, informational for `unstable` (add `run-extra-tests` label to opt in). Covers: Valgrind, UBSan, ARM, FreeBSD, Alpine, I/O threads, RPM distros, reply-schema validation.

### Common failures

| Failure | Cause | Fix |
|---------|-------|-----|
| clang-format diff | formatter version or edits | `clang-format-18 -i <files>` |
| `commands.def` diff | edited `src/commands/*.json` without regen | `make commands.def` and commit the result |
| Reply-schema CI failure | command's `reply_schema` in JSON doesn't match actual reply | update JSON or fix command reply |
| Sanitizer stderr find | check `check_sanitizer_errors` output | see sanitizers section |

## Config system (`src/config.c`)

Registration-table / `standardConfig` model, `loadServerConfig` / `CONFIG GET` / `CONFIG SET` / `CONFIG REWRITE` pipeline, and flags (`IMMUTABLE_CONFIG`, `PROTECTED_CONFIG` with `enable-protected-configs`, `HIDDEN_CONFIG`, `SENSITIVE_CONFIG`, `DEBUG_CONFIG`, `DENY_LOADING_CONFIG`) match Redis. `CONFIG SET` accepts multiple key-value pairs atomically with rollback - also Redis 7+.

### Valkey grep hazard: renamed configs

Valkey flipped primary/legacy direction on replication-related configs. Grepping the Redis name finds only the alias. Primary names:

| Primary (Valkey) | Legacy alias |
|------------------|--------------|
| `replicaof` | `slaveof` |
| `replica-priority` | `slave-priority` |
| `primaryuser` | `masteruser` |
| `primaryauth` | `masterauth` |

Many other `slave-*` → `replica-*` renames follow the same pattern - search `createStringConfig\|createIntConfig\|createBoolConfig` with the legacy name as the second arg in `src/config.c` to find the current primary name.
