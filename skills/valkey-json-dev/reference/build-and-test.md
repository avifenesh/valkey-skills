# Build and Test

Use when building valkey-json from source, running unit or integration tests, debugging build issues, or understanding the CI pipeline.

## Contents

- Prerequisites (line 16)
- Build Commands (line 23)
- Build System Internals (line 94)
- Unit Test Structure (line 111)
- Integration Test Structure (line 129)
- CI Pipeline (line 145)
- Loading the Module (line 160)
- Debugging Tips (line 173)

## Prerequisites

- CMake 3.17+
- C++17 compiler (GCC or Clang)
- Python 3.9+ (for integration tests)
- Linux x86_64 or ARM64 (aarch64/arm64 only)

## Build Commands

### Release Build (default)

```bash
./build.sh              # builds libjson.so in build/src/
./build.sh --release    # same as above, explicit
```

Output: `build/src/libjson.so`

### Unit Tests

```bash
./build.sh --unit
```

This builds the module and a GoogleTest binary (`build/tst/unit/unitTests`), then runs all unit tests. Tests use `module_sim.cc` to mock the `ValkeyModule_*` API.

### Integration Tests

```bash
./build.sh --integration
```

This:
1. Builds the module and valkey-server from source (default: `unstable` branch)
2. Fetches `valkey-test-framework` (pytest-based)
3. Installs Python dependencies from `requirements.txt`
4. Runs pytest against a live valkey-server with the module loaded

### Targeting a Specific Valkey Version

```bash
SERVER_VERSION=8.1 ./build.sh --integration
SERVER_VERSION=9.0 ./build.sh --release
```

### Running a Single Integration Test

```bash
TEST_PATTERN=test_sanity ./build.sh --integration
TEST_PATTERN=test_rdb.py ./build.sh --integration
```

### ASAN Build

```bash
export ASAN_BUILD=true
./build.sh --integration    # AddressSanitizer + leak detection
./build.sh --unit           # ASAN for unit tests too
```

ASAN builds use `-fsanitize=address` for both compile and link. Integration tests additionally check for `LeakSanitizer: detected memory leaks` in output and fail if found.

### Custom Compiler Flags

```bash
CFLAGS="-O0 -Wno-unused-function" ./build.sh
```

Default flags: `-g -O3 -fno-omit-frame-pointer -Wall -Werror -Wextra`

### Cleaning

```bash
./build.sh --clean
```

Removes `build/`, `tst/integration/valkeytests`, `tst/integration/.build`, `src/include`, and test artifacts.

## Build System Internals

The CMake build (`CMakeLists.txt`) does:

1. Fetches valkey-server source via `ExternalProject_Add` (for the `valkeymodule.h` header and optionally building the server binary)
2. Fetches RapidJSON via `FetchContent_Declare` (pinned commit)
3. Fetches `valkey-test-framework` via `ExternalProject_Add` (for integration tests)
4. Builds `json-objects` as an OBJECT library, then links into `libjson.so`

Source files compiled (from `src/CMakeLists.txt`):

```
json/json.cc, json/dom.cc, json/alloc.cc, json/util.cc,
json/stats.cc, json/selector.cc, json/keytable.cc,
json/memory.cc, json/json_api.cc, json/shared_api.cc
```

## Unit Test Structure

Location: `tst/unit/`

| File | Tests |
|------|-------|
| `dom_test.cc` | Document parsing, serialization, CRUD, path operations |
| `selector_test.cc` | JSONPath v1/v2 parsing, filter expressions, slices |
| `json_test.cc` | Command-level logic, config, error codes |
| `keytable_test.cc` | String interning, refcounting, sharding |
| `hashtable_test.cc` | Vendored RapidJSON object member hash table (auto-convert, rehash, load factors) |
| `stats_test.cc` | Memory tracking, histograms |
| `util_test.cc` | Number formatting, overflow checks |
| `traps_test.cc` | Memory trap diagnostics |
| `module_sim.cc/.h` | ValkeyModule API mock for unit testing |

Framework: GoogleTest 1.12.1 (fetched by CMake). All tests run as a single `unitTests` binary with 10-second per-test timeout.

## Integration Test Structure

Location: `tst/integration/`

| File | Tests |
|------|-------|
| `test_json_basic.py` | All JSON.* commands, path syntax, error cases |
| `test_rdb.py` | RDB save/load, persistence round-trip |
| `json_test_case.py` | Base test case class with server setup/teardown |
| `error_handlers.py` | Custom pytest error handling |
| `utils_json.py` | Test utilities |
| `data/` | Test fixtures |
| `run.sh` | Test runner (kills stale processes, invokes pytest) |

The test framework copies the built valkey-server binary to `tst/integration/.build/binaries/{version}/` and launches it with the module loaded.

## CI Pipeline

File: `.github/workflows/ci.yml`

Four parallel job groups, each running against a matrix of Valkey versions: `unstable`, `8.0`, `8.1`, `9.0`.

| Job | What It Does |
|-----|-------------|
| `build-release` | `./build.sh` - verifies the module compiles |
| `unit-tests` | `./build.sh --unit` - runs GoogleTest suite |
| `integration-tests` | `./build.sh --integration` - pytest against live server |
| `asan-tests` | `ASAN_BUILD=true ./build.sh --integration` - memory safety |

All jobs run on `ubuntu-latest`. Integration and ASAN jobs install Python 3.9 and pip dependencies first.

## Loading the Module

```bash
# Via command line
valkey-server --loadmodule ./build/src/libjson.so

# Via config file (add to valkey.conf)
loadmodule /path/to/libjson.so

# At runtime
valkey-cli MODULE LOAD /path/to/libjson.so
```

## Debugging Tips

- Enable compile_commands.json: already configured (`CMAKE_EXPORT_COMPILE_COMMANDS ON`)
- Instrumentation: set `INSTRUMENT_V2PATH=yes` env var before build to enable JSONPath trace output
- Memory traps: enable at runtime via `JSON.DEBUG` commands for diagnosing memory corruption
- ASAN: use `ASAN_BUILD=true` for any build to catch memory errors early
