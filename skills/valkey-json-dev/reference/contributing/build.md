# Build System

Use when configuring the CMake build, understanding compiler flags, adding dependencies, or troubleshooting build failures in valkey-json.

Source: `CMakeLists.txt`, `build.sh`, `tst/unit/CMakeLists.txt` in valkey-io/valkey-json

## Contents

- [CMake Configuration](#cmake-configuration)
- [External Dependencies](#external-dependencies)
- [CMake Build Options](#cmake-build-options)
- [build.sh Wrapper](#buildsh-wrapper)
- [Output Artifact](#output-artifact)
- [Build Directory Layout](#build-directory-layout)
- [Instrumentation](#instrumentation)

## CMake Configuration

CMake 3.17+ required. The root `CMakeLists.txt` defines project `ValkeyJSONModule`.

### Language Standards

| Language | Standard | Required |
|----------|----------|----------|
| C | C11 | Yes |
| C++ | C++17 | Yes |

Set at lines 184-187 of `CMakeLists.txt`:

```cmake
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED True)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED True)
```

### Compiler Flags

Default flags (line 82):

```
-g -O3 -fno-omit-frame-pointer -Wall -Werror -Wextra
```

Override via `-DCFLAGS="..."` on the cmake command line. Additional flags applied unconditionally:

- `-fPIC` - all architectures (required for shared library)
- `-Wno-mismatched-tags -Wno-format` - suppress C++ warnings

Clang detection triggers `VALKEYMODULE_ATTR_COMMON=__attribute__((weak))`. On macOS, if the default compiler is not Clang, CMake forces Clang.

### Supported Architectures

| Architecture | SIMD Flag | Purpose |
|--------------|-----------|---------|
| x86_64 | `-march=nehalem` | Enables SSE4.2 for RapidJSON SIMD parsing |
| aarch64 | `-march=armv8-a` | Enables NEON for RapidJSON SIMD parsing |
| arm64 | (none) | Accepted at the arch check but no explicit SIMD flag set |

Other architectures cause a fatal CMake error (lines 20-23).

## External Dependencies

### Valkey Server

Fetched via `ExternalProject_Add` from `https://github.com/valkey-io/valkey.git`. The version defaults to `unstable` unless `-DVALKEY_VERSION=<tag>` is passed. Only the `valkeymodule.h` header is needed for release builds - the full server binary is built only when integration tests are enabled.

### RapidJSON

Fetched via `FetchContent` from `https://github.com/Tencent/rapidjson.git` at a pinned commit. Tests, examples, and docs are disabled. Provides the JSON parser and DOM representation.

### GoogleTest

Fetched for unit tests. The unit test binary links `GTest::gtest_main` and `GTest::gmock_main`. See `tst/unit/CMakeLists.txt`.

### valkey-test-framework

Fetched only when `ENABLE_INTEGRATION_TESTS=ON`. Cloned from `https://github.com/valkey-io/valkey-test-framework.git` at a pinned commit. Provides `ValkeyTestCase` base class and pytest infrastructure. Copied into `tst/integration/valkeytests/`.

## CMake Build Options

| Option | Default | Effect |
|--------|---------|--------|
| `BUILD_RELEASE` | OFF | Build only the shared library, skip tests |
| `ENABLE_UNIT_TESTS` | ON | Build unit test binary |
| `ENABLE_INTEGRATION_TESTS` | ON | Build server + fetch test framework |
| `ENABLE_ASAN` | OFF | Enable AddressSanitizer |
| `VALKEY_VERSION` | unstable | Valkey server git tag to build against |
| `CFLAGS` | (see above) | Override compiler flags |

## build.sh Wrapper

The `build.sh` script in the repo root wraps CMake with common configurations.

### Options

| Flag | Effect |
|------|--------|
| `--release` | Release build only (default if no flags) |
| `--unit` | Build and run unit tests |
| `--integration` | Build module + server, install Python deps, run pytest |
| `--clean` | Remove `build/`, test artifacts, copied headers |
| `--help` / `-h` | Print usage and exit |

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `SERVER_VERSION` | Valkey git tag (default: `unstable`) |
| `ASAN_BUILD` | Set to `true` for AddressSanitizer build |
| `CFLAGS` | Override compiler flags |
| `TEST_PATTERN` | Filter integration tests by name (passed to `pytest -k`) |

### Typical Workflows

```bash
# Release build
./build.sh --release

# Unit tests against Valkey 9.0 headers
SERVER_VERSION=9.0 ./build.sh --unit

# Integration tests
SERVER_VERSION=unstable ./build.sh --integration

# ASAN integration tests
ASAN_BUILD=true ./build.sh --integration

# Run only specific integration tests
TEST_PATTERN="test_json_set" ./build.sh --integration

# Clean everything
./build.sh --clean
```

### ASAN Support

When `ASAN_BUILD=true`, build.sh passes `-DCMAKE_BUILD_TYPE=Debug -DENABLE_ASAN=ON`. This adds `-fsanitize=address` to compile and link flags. The integration test runner (`tst/integration/run.sh`) automatically checks output for `LeakSanitizer: detected memory leaks` and fails the build if found.

## Output Artifact

The module shared library is produced at:

```
build/src/libjson.so
```

Load it with:

```bash
valkey-server --loadmodule ./build/src/libjson.so
```

## Build Directory Layout

```
build/
  src/
    libjson.so              # Module shared library
  tst/
    unit/
      unitTests             # GoogleTest binary
    integration/            # Copied test files for isolated runs
  _deps/
    valkey-src/             # Valkey server source and binary
    rapidjson-src/          # RapidJSON headers
    valkey-test-framework-src/  # pytest framework (integration only)
```

## Instrumentation

The `INSTRUMENT_V2PATH` environment variable enables JSONPath v2 instrumentation when set to `yes`. This adds the `INSTRUMENT_V2PATH` compile definition for performance profiling of path evaluation.

## See Also

- [testing.md](testing.md) - Unit and integration test details
- [ci-pipeline.md](ci-pipeline.md) - GitHub Actions CI configuration
- [adding-commands.md](adding-commands.md) - Command implementation patterns
- [rdb-format.md](../persistence/rdb-format.md) - RDB encoding versions and persistence format
- [memory-layers.md](../document/memory-layers.md) - Three-layer memory architecture (relevant to ASAN builds)
