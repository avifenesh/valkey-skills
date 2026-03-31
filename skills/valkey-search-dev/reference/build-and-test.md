# Build and Test

Use when building valkey-search from source, running tests, setting up CI, debugging build issues, or working with sanitizers.

## Contents

- Prerequisites (line 18)
- Build System (line 28)
- Loading the Module (line 66)
- Unit Tests (line 74)
- Integration Tests (line 138)
- Sanitizers (line 166)
- Code Formatting (line 179)
- CI Workflows (`.github/workflows/`) (line 187)
- Benchmark Scripts (line 204)
- Protobuf Generation (line 208)

## Prerequisites

Ubuntu 24.04 (or the devcontainer). Required packages:

```
cmake ninja-build g++ gcc libssl-dev python3-pip python3.12-venv
```

The devcontainer (`.devcontainer/Dockerfile`) is the canonical build environment. It also installs valkey-server for integration tests.

## Build System

CMake with Ninja generator (default). C++20 standard. Produces `libsearch.so` (Linux) or `libsearch.dylib` (macOS).

### Quick Build

```bash
./build.sh                    # Release build (runs cmake if needed)
./build.sh --configure        # Force re-run cmake
./build.sh --debug            # Debug build
./build.sh --clean            # Clean build artifacts
./build.sh --verbose          # Verbose output
./build.sh --jobs=4           # Limit parallel jobs
./build.sh --no-build         # Skip build (for test-only runs)
```

Build output goes to `.build-release/` or `.build-debug/`.

### CMake Options

| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_UNIT_TESTS` | ON | Build GTest unit tests |
| `WITH_SUBMODULES_SYSTEM` | OFF | Use system gRPC/Protobuf/Abseil instead of submodules (CLI: `--use-system-modules`) |
| `SAN_BUILD` | "" | Sanitizer: `address` or `thread` |

### Submodules

Dependencies are vendored as git submodules in `submodules/`: gRPC, Protobuf, GTest, Abseil. First build clones and builds these (slow). ICU is built from `third_party/icu/source` into the build directory.

### Manual CMake

```bash
mkdir -p .build-release && cd .build-release
cmake .. -DCMAKE_BUILD_TYPE=Release -G Ninja -DBUILD_UNIT_TESTS=ON
ninja
```

## Loading the Module

```bash
valkey-server --loadmodule .build-release/libsearch.so
```

In cluster mode, the gRPC coordinator port is auto-derived (`valkey_port + 20294`). The `use-coordinator` module config controls whether the coordinator starts. No `--coordinator-port` CLI argument needed.

## Unit Tests

GTest-based. Test sources in `testing/`. Each test file corresponds to a source file.

```bash
./build.sh --run-tests                    # Run all unit tests
./build.sh --run-tests=vector_test        # Run single test binary
./build.sh --run-tests --test-errors-stdout  # Dump failures to stdout
```

Test binaries are in `.build-release/tests/`. Each `*_test.cc` compiles to a separate binary.

### Key Test Files

| Test | What it covers |
|------|----------------|
| `vector_test.cc` | HNSW and FLAT vector operations |
| `ft_search_test.cc` | FT.SEARCH command end-to-end |
| `ft_search_parser_test.cc` | Query string parsing |
| `filter_test.cc` | Filter predicate evaluation |
| `ft_create_test.cc` | FT.CREATE index creation |
| `ft_create_parser_test.cc` | FT.CREATE argument parsing |
| `ft_aggregate_parser_test.cc` | FT.AGGREGATE parsing |
| `ft_aggregate_exec_test.cc` | FT.AGGREGATE execution |
| `ft_dropindex_test.cc` | FT.DROPINDEX operations |
| `ft_info_test.cc` | FT.INFO output |
| `ft_list_test.cc` | FT._LIST operations |
| `text_test.cc` | Full-text indexing |
| `text_index_schema_test.cc` | TextIndexSchema management |
| `lexer_test.cc` | Text tokenization |
| `posting_test.cc` | Posting list operations |
| `flat_position_map_test.cc` | Position storage for phrase queries |
| `radix_test.cc` | Radix tree operations |
| `rax_wrapper_test.cc` | Rax C wrapper |
| `numeric_index_test.cc` | Numeric range index |
| `tag_index_test.cc` | Tag index |
| `index_schema_test.cc` | IndexSchema lifecycle |
| `schema_manager_test.cc` | SchemaManager operations |
| `rdb_serialization_test.cc` | RDB save/load |
| `search_test.cc` | Search execution paths |
| `acl_test.cc` | ACL permission checks |
| `attribute_data_type_test.cc` | Hash vs JSON field extraction |
| `keyspace_event_manager_test.cc` | Keyspace event routing |
| `server_events_test.cc` | Server event handlers |
| `multi_exec_test.cc` | MULTI/EXEC transaction handling |
| `vector_externalizer_test.cc` | Vector denormalization |
| `valkey_search_test.cc` | ValkeySearch singleton |
| `segment_tree_test.cc` | Segment tree for range counts |

### Subdirectory Tests

| Directory | Tests |
|-----------|-------|
| `testing/commands/` | `ft_internal_update_test.cc` |
| `testing/coordinator/` | `client_test.cc`, `metadata_manager_test.cc` |
| `testing/utils/` | `allocator_test.cc`, `intrusive_list_test.cc`, `intrusive_ref_count_test.cc`, `lru_test.cc`, `patricia_tree_test.cc`, `scanner_test.cc`, `segment_tree_test.cc`, `string_interning_test.cc` |
| `testing/expr/` | `expr_test.cc`, `value_test.cc` |
| `testing/query/` | `response_generator_test.cc` |

### Test Utilities

- `testing/common.h` / `common.cc` - shared test fixtures, mock helpers
- `testing/coordinator/common.h` - coordinator-specific test helpers

## Integration Tests

Two integration test suites:

### C++ Integration Tests (`testing/integration/`)

Python-based tests that start a real Valkey server with the module loaded.

```bash
./build.sh --run-integration-tests
```

Key files: `vector_search_integration_test.py`, `stability_test.py`, `stability_runner.py`, `ft_internal_update_integration_test.py`

### Python Integration Tests (`integration/`)

Comprehensive pytest suite. Run via `integration/run.sh`.

```bash
./build.sh --run-integration-tests          # All integration tests
./build.sh --run-integration-tests=pattern  # Filter by pattern
./build.sh --retries=3                      # Retry flaky tests
```

Key test files cover: VSS basic, non-vector search, full-text (including in-flight blocking and space performance), filter expressions, HNSW (allow_replace_deleted), JSON, RDB save/restore (including module v1.0 load and load-without-module), cluster fan-out (info cluster, info primary, metadata cluster validation, search/info partition consistency controls), ACL, eviction, expired keys, OOM handling, reclaimable memory, query parser, post-filter, aggregation metrics, multi/Lua, copy, debug, versioning, multi-DB search, FT.CREATE/DROPINDEX consistency, cancel, single-slot, skip-initial-scan, skip-index-load, cross-module compat, FT.INTERNAL_UPDATE, flushall.

Test base class: `valkey_search_test_case.py` - manages server lifecycle, module loading.

## Sanitizers

Address Sanitizer (ASan) and Thread Sanitizer (TSan) builds:

```bash
./build.sh --asan                           # Build with ASan
./build.sh --asan --run-tests               # Build + test with ASan
./build.sh --tsan                           # Build with TSan
./build.sh --tsan --run-tests               # Build + test with TSan
```

ASan builds go to `.build-release-asan/`, TSan to `.build-release-tsan/`. When running sanitizer tests, all test binaries run even if one fails (no early exit).

## Code Formatting

```bash
./build.sh --format    # Run clang-format on src/ testing/ vmsdk/
```

Applies to `*.h` and `*.cc` files. Excludes `src/indexes/text/rax/` (vendored code).

## CI Workflows (`.github/workflows/`)

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `unittests.yml` | PR to main, push to main | Build + unit tests in Docker |
| `unittests-asan.yml` | PR/push | ASan unit tests |
| `unittests-tsan.yml` | PR/push | TSan unit tests |
| `integration_tests.yml` | PR/push | Full integration test suite |
| `integration_tests-asan.yml` | PR/push | ASan integration tests |
| `endurance_tests.yml` | PR/push | Long-running stability tests |
| `clang_tidy_format.yml` | PR/push | Formatting and linting |
| `spell_check.yml` | PR/push | Spell check |
| `macos.yml` | PR/push | macOS build verification |
| `trigger-search-release.yml` | Release published | Triggers valkey-bundle extension update |

All CI runs in Docker using the devcontainer image. Concurrency groups cancel in-progress runs for the same branch.

## Benchmark Scripts

`scripts/benchmark/` contains benchmark tooling. `scripts/common.rc` is shared shell config. Additional scripts in `ci/` handle Docker build (`build_ubuntu.sh`), format checks (`check_clang_format.sh`), change detection (`check_changes.sh`), sanitizer suppressions (`asan.supp`, `tsan.supp`), and the CI entrypoint (`entrypoint.sh`).

## Protobuf Generation

Proto files: `src/index_schema.proto`, `src/rdb_section.proto`, `src/coordinator/coordinator.proto`. Generated during CMake configure step using `protoc` and `grpc_cpp_plugin` from submodules. Output goes to build directory.
