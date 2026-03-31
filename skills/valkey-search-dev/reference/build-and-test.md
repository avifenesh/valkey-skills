# Build and Test

Use when building valkey-search from source, running tests, setting up CI, debugging build issues, or working with sanitizers.

Source: `build.sh`, `CMakeLists.txt`, `testing/`, `integration/`, `.github/workflows/`, `.devcontainer/`

---

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
```

Build output goes to `.build-release/` or `.build-debug/`.

### CMake Options

| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_UNIT_TESTS` | ON | Build GTest unit tests |
| `WITH_SUBMODULES_SYSTEM` | OFF | Use system gRPC/Protobuf/Abseil instead of submodules |
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
# Or with coordinator port for cluster mode:
valkey-server --loadmodule .build-release/libsearch.so --coordinator-port 6380
```

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
| `ft_aggregate_parser_test.cc` | FT.AGGREGATE parsing |
| `ft_aggregate_exec_test.cc` | FT.AGGREGATE execution |
| `text_test.cc` | Full-text indexing |
| `lexer_test.cc` | Text tokenization |
| `numeric_index_test.cc` | Numeric range index |
| `tag_index_test.cc` | Tag index |
| `index_schema_test.cc` | IndexSchema lifecycle |
| `schema_manager_test.cc` | SchemaManager operations |
| `rdb_serialization_test.cc` | RDB save/load |
| `search_test.cc` | Search execution paths |
| `acl_test.cc` | ACL permission checks |

### Test Utilities

- `testing/common.h` / `common.cc` - shared test fixtures, mock helpers
- `testing/commands/` - command-specific test helpers
- `testing/coordinator/` - coordinator test helpers
- `testing/utils/` - utility test helpers

## Integration Tests

Two integration test suites:

### C++ Integration Tests (`testing/integration/`)

Abseil-based tests that start a real Valkey server with the module loaded.

```bash
./build.sh --run-integration-tests
```

Key files: `vector_search_integration_test.py`, `stability_test.py`

### Python Integration Tests (`integration/`)

Comprehensive pytest suite. Run via `integration/run.sh`.

```bash
./build.sh --run-integration-tests          # All integration tests
./build.sh --run-integration-tests=pattern  # Filter by pattern
./build.sh --retries=3                      # Retry flaky tests
```

Key test files cover: VSS basic, non-vector search, full-text, filter expressions, HNSW, JSON, RDB save/restore, cluster fan-out, ACL, eviction, OOM handling, query parser, aggregation metrics, multi/Lua, copy, debug, versioning.

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

All CI runs in Docker using the devcontainer image. Concurrency groups cancel in-progress runs for the same branch.

## Protobuf Generation

Proto files: `src/index_schema.proto`, `src/rdb_section.proto`, `src/coordinator/coordinator.proto`. Generated during CMake configure step using `protoc` and `grpc_cpp_plugin` from submodules. Output goes to build directory.
