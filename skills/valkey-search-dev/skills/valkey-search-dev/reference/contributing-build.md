# Build System

Use when building valkey-search from source, configuring CMake, understanding dependencies, or troubleshooting build failures.

Source: `CMakeLists.txt`, `build.sh`, `submodules/CMakeLists.txt`, `third_party/CMakeLists.txt`, `cmake/Modules/valkey_search.cmake`

## Contents

- [Build Requirements](#build-requirements)
- [CMake Structure](#cmake-structure)
- [Dependencies](#dependencies)
- [VMSDK Abstraction Layer](#vmsdk-abstraction-layer)
- [build.sh](#buildsh)
- [Sanitizer Builds](#sanitizer-builds)
- [Platform Notes](#platform-notes)
- [Troubleshooting](#troubleshooting)

## Build Requirements

- C++20 (GCC 12+ or Clang 16+)
- CMake 3.16+
- Ninja (default) or Make
- Linux or macOS only - the top-level CMakeLists.txt rejects non-UNIX platforms
- Position-independent code enabled globally (`CMAKE_POSITION_INDEPENDENT_CODE ON`)

## CMake Structure

The top-level `CMakeLists.txt` orchestrates the build:

```
CMakeLists.txt          # Project root - options, submodule init, subdirectories
  submodules/           # gRPC, Protobuf, Abseil, GoogleTest, HighwayHash, Benchmark
  third_party/          # hnswlib, ICU, SimSIMD, Snowball, hdrhistogram_c
  vmsdk/                # Valkey Module SDK abstraction layer
  src/                  # Module source (produces libsearch.so/.dylib)
  testing/              # GoogleTest unit tests
```

Key CMake options:

| Option | Default | Purpose |
|--------|---------|---------|
| `BUILD_UNIT_TESTS` | ON | Build GoogleTest unit test binaries |
| `WITH_SUBMODULES_SYSTEM` | OFF | Use system-installed gRPC/Protobuf/Abseil instead of building from source |
| `SAN_BUILD` | "" | Sanitizer: `address` or `thread` |

The `cmake/Modules/valkey_search.cmake` module provides helper functions (`valkey_search_add_static_library`, `valkey_search_add_shared_library`) that apply consistent compile flags and link GoogleTest for `gtest_prod.h` support.

## Dependencies

### Submodules (built from source by default)

These are cloned and built during the CMake configure step via `submodules/CMakeLists.txt`:

| Dependency | Version | Purpose |
|------------|---------|---------|
| gRPC | v1.70.1 | Cluster coordinator inter-node RPC |
| Protobuf | (via gRPC) | Index schema and RDB section serialization |
| Abseil | (via gRPC) | Data structures, status, synchronization |
| GoogleTest | main | Unit test framework |
| HighwayHash | master | Fast hashing for index fingerprints |
| Google Benchmark | v1.8.3 | Micro-benchmarks (disabled during sanitizer builds) |

Use `--use-system-modules` to skip building these from source and use system-installed versions instead. CI uses pre-built `.deb` packages from `/opt/valkey-search-deps/` for speed.

### Third-party (vendored in `third_party/`)

Built via `third_party/CMakeLists.txt`, these are committed or vendored sources:

| Library | Directory | Purpose |
|---------|-----------|---------|
| hnswlib | `third_party/hnswlib/` | HNSW approximate nearest neighbor index |
| ICU | `third_party/icu/` | Unicode normalization and locale-aware text processing |
| SimSIMD | `third_party/simsimd/` | SIMD-accelerated vector distance computations |
| Snowball | `third_party/snowball/` | Stemming for full-text search |
| hdrhistogram_c | `third_party/hdrhistogram_c/` | High dynamic range histogram for latency metrics |

ICU is built as static libraries with embedded data. The `build_icu_if_needed()` function in `build.sh` runs an out-of-tree build in `${BUILD_DIR}/icu/`, producing `libicudata.a`, `libicui18n.a`, and `libicuuc.a` under `${BUILD_DIR}/icu/install/lib/`.

## VMSDK Abstraction Layer

The `vmsdk/` directory is an in-tree SDK that wraps the raw ValkeyModule C API into C++ abstractions:

| Header | Purpose |
|--------|---------|
| `managed_pointers.h` | RAII wrappers (`UniqueValkeyString`) for `ValkeyModuleString*` |
| `blocked_client.h` | Blocked client management with category tracking |
| `module_config.h` | Type-safe module configuration with builder pattern |
| `module.h` | `VALKEY_MODULE()` macro, `Options` struct, command registration |
| `thread_pool.h` | Thread pool for async search and utility tasks |
| `cluster_map.h` | Cluster topology and fanout target computation |
| `module_type.h` | Custom data type registration |
| `memory_allocation.h` | Valkey-aware memory allocation wrappers |
| `latency_sampler.h` | Latency measurement sampling |
| `time_sliced_mrmw_mutex.h` | Multi-reader multi-writer mutex with time slicing |

VMSDK is compiled as a static library (`vmsdklib`) and linked into the final shared library. It also ships a `testing_infra/` directory providing mocked ValkeyModule contexts for unit tests.

## build.sh

The primary developer build script. It auto-detects when CMake reconfiguration is needed by comparing timestamps of `CMakeLists.txt` and `.cmake` files against the build output.

### Common Commands

```bash
# Default release build (auto-configures if needed)
./build.sh

# Force CMake reconfigure + debug build
./build.sh --configure --debug

# Build with AddressSanitizer
./build.sh --asan

# Build with ThreadSanitizer
./build.sh --tsan

# Apply clang-format to all source files
./build.sh --format

# Run all unit tests after build
./build.sh --run-tests

# Run a specific test binary
./build.sh --run-tests=vector_test

# Run integration tests
./build.sh --run-integration-tests

# Run integration tests matching a pattern
./build.sh --run-integration-tests=oss

# Limit parallel build jobs
./build.sh --jobs=4

# Clean build directory
./build.sh --clean
```

### Build Directories

| Configuration | Directory |
|---------------|-----------|
| Release | `.build-release/` |
| Debug | `.build-debug/` |
| Release + ASan | `.build-release-asan/` |
| Release + TSan | `.build-release-tsan/` |
| Debug + ASan | `.build-debug-asan/` |
| Debug + TSan | `.build-debug-tsan/` |

### Output

The build produces a single shared library:

- Linux: `.build-release/libsearch.so`
- macOS: `.build-release/libsearch.dylib`

Load it with:

```bash
valkey-server --loadmodule .build-release/libsearch.so
```

### Build Flow

1. `build_icu_if_needed()` - builds ICU static libraries in `${BUILD_DIR}/icu/` if not cached
2. Auto-detect if CMake configure is required (timestamp comparison of `CMakeLists.txt` and `*.cmake` files)
3. `configure()` - runs `cmake` with the selected generator and options
4. `build()` - runs Ninja (or Make) to compile and link
5. Optionally runs unit tests, integration tests, or both

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `CMAKE_GENERATOR` | Override build generator (default: `Ninja`) |
| `CMAKE_EXTRA_ARGS` | Additional CMake arguments |
| `SAN_BUILD` | Sanitizer type (`address` or `thread`) for downstream scripts |

## Sanitizer Builds

AddressSanitizer and ThreadSanitizer builds compile the entire dependency stack with sanitizer flags. Submodules are rebuilt with `-fsanitize=address` or `-fsanitize=thread` in `CXXFLAGS`, `CFLAGS`, and `LDFLAGS`.

ASan builds set `ASAN_OPTIONS="detect_odr_violation=0"` at runtime. Suppression files are in `ci/asan.supp` and `ci/tsan.supp`.

During sanitizer test runs, all unit tests continue running even after a failure (rather than stopping at the first failure) to collect the full set of sanitizer reports.

Google Benchmark is disabled for sanitizer builds since instrumentation distorts timing results.

## Platform Notes

### Linux

- Default build uses Ninja. Falls back to Make if Ninja is unavailable.
- On Debian-based systems, Ninja is invoked as `ninja`. On RedHat-based systems, it is `ninja-build`.
- The linker uses `--version-script` from `vmsdk/versionscript.lds` to control exported symbols.
- `--allow-multiple-definition` and `--start-group`/`--end-group` flags handle circular library dependencies.

### macOS

- Uses `clang` (Apple's default). Requires Xcode command line tools.
- Suppresses `-Wno-defaulted-function-deleted` warnings from Apple Clang.
- Works around a zlib `fdopen` detection issue in the gRPC submodule.
- Module output is `.dylib` instead of `.so`.
- No integration tests run on macOS in CI - build-only verification.

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| CMake fails to find gRPC/Protobuf | Submodules not built | Run `./build.sh --configure` to trigger full configure |
| ICU build fails | Missing source in `third_party/icu/` | ICU source is committed to the repo - check your checkout |
| Ninja not found | Package name varies by distro | Install `ninja-build` (RedHat) or `ninja` (Debian/macOS) |
| Link errors about multiple definitions | Missing `--start-group` | Ensure Linux build uses the CMake-generated link flags |
| `GCC version too old` | GCC below 12 | Upgrade to GCC 12+ or use the dev container |
| Benchmark disabled warning | SAN_BUILD is set | Expected - Google Benchmark is skipped for sanitizer builds |
