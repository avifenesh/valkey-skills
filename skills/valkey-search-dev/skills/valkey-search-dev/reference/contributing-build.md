# Build system

Use when building valkey-search, configuring CMake, or troubleshooting build failures.

Source: `CMakeLists.txt`, `build.sh`, `submodules/CMakeLists.txt`, `third_party/CMakeLists.txt`, `cmake/Modules/valkey_search.cmake`.

## Requirements

- C++20 (GCC 12+ or Clang 16+).
- CMake 3.16+.
- Ninja (default) or Make.
- Linux or macOS only (top-level CMakeLists rejects non-UNIX).
- `CMAKE_POSITION_INDEPENDENT_CODE ON` globally.

## Layout

```
CMakeLists.txt        # root: options, submodule init, subdirs
submodules/           # gRPC, Protobuf, Abseil, GoogleTest, HighwayHash, Benchmark
third_party/          # hnswlib, ICU, SimSIMD, Snowball, hdrhistogram_c
vmsdk/                # Valkey Module SDK C++ wrapper
src/                  # module (libsearch.{so,dylib})
testing/              # GoogleTest unit tests
```

CMake options:

| Option | Default | Purpose |
|--------|---------|---------|
| `BUILD_UNIT_TESTS` | ON | GoogleTest binaries |
| `WITH_SUBMODULES_SYSTEM` | OFF | Use system gRPC/Protobuf/Abseil instead of building |
| `SAN_BUILD` | "" | `address` or `thread` |

`cmake/Modules/valkey_search.cmake` provides `valkey_search_add_static_library` / `_shared_library` helpers that apply consistent compile flags and link GoogleTest (for `gtest_prod.h`).

## Submodules (built from source by default)

| Dependency | Version | Use |
|------------|---------|-----|
| gRPC | v1.70.1 | coordinator RPC |
| Protobuf | via gRPC | schema + RDB section |
| Abseil | via gRPC | data structures, status, sync |
| GoogleTest | main | unit tests |
| HighwayHash | master | index fingerprints |
| Google Benchmark | v1.8.3 | micro-benchmarks (disabled under SAN) |

`--use-system-modules` skips building submodules. CI uses pre-built `.deb`s from `/opt/valkey-search-deps/`.

## Third-party (vendored)

| Library | Dir | Use |
|---------|-----|-----|
| hnswlib | `third_party/hnswlib/` | HNSW ANN |
| ICU | `third_party/icu/` | Unicode normalization |
| SimSIMD | `third_party/simsimd/` | SIMD vector distance |
| Snowball | `third_party/snowball/` | stemming |
| hdrhistogram_c | `third_party/hdrhistogram_c/` | latency histograms |

ICU is built static with embedded data. `build_icu_if_needed()` in `build.sh` builds out-of-tree in `${BUILD_DIR}/icu/`, producing `libicudata.a`, `libicui18n.a`, `libicuuc.a` under `${BUILD_DIR}/icu/install/lib/`.

## VMSDK layer (`vmsdk/`)

In-tree C++ wrapper over raw ValkeyModule C API. Compiled as static `vmsdklib`, linked into final `.so`. Ships `testing_infra/` with mocked contexts.

| Header | Purpose |
|--------|---------|
| `managed_pointers.h` | RAII (e.g. `UniqueValkeyString` for `ValkeyModuleString*`) |
| `blocked_client.h` | blocked clients + category tracking |
| `module_config.h` | type-safe configs (builder) |
| `module.h` | `VALKEY_MODULE()`, `Options`, command registration |
| `thread_pool.h` | async search + utility pools |
| `cluster_map.h` | cluster topology + fanout targets |
| `module_type.h` | custom data type registration |
| `memory_allocation.h` | Valkey-aware allocation |
| `latency_sampler.h` | latency sampling |
| `time_sliced_mrmw_mutex.h` | MRMW mutex with time slicing |

## `build.sh`

Auto-detects CMake reconfigure (compares `CMakeLists.txt` + `.cmake` timestamps vs build output).

```bash
./build.sh                                # default release
./build.sh --configure --debug
./build.sh --asan                         # AddressSanitizer
./build.sh --tsan                         # ThreadSanitizer
./build.sh --format                       # clang-format
./build.sh --run-tests                    # all unit tests
./build.sh --run-tests=vector_test        # one suite
./build.sh --run-integration-tests
./build.sh --run-integration-tests=oss    # pattern
./build.sh --jobs=4
./build.sh --clean
```

Build dirs by config:

| Config | Dir |
|--------|-----|
| Release | `.build-release/` |
| Debug | `.build-debug/` |
| Release + ASan | `.build-release-asan/` |
| Release + TSan | `.build-release-tsan/` |
| Debug + ASan | `.build-debug-asan/` |
| Debug + TSan | `.build-debug-tsan/` |

Output: `.build-release/libsearch.{so,dylib}`. Load with `valkey-server --loadmodule .build-release/libsearch.so`.

### Flow

1. `build_icu_if_needed()` (cached in `${BUILD_DIR}/icu/`).
2. Auto-detect CMake reconfigure via timestamp comparison.
3. `configure()` - `cmake` with generator + options.
4. `build()` - Ninja or Make.
5. Optionally tests.

### Env

| Var | Use |
|-----|-----|
| `CMAKE_GENERATOR` | override generator (default `Ninja`) |
| `CMAKE_EXTRA_ARGS` | extra cmake args |
| `SAN_BUILD` | `address` / `thread` for downstream scripts |

## Sanitizer builds

AddressSanitizer / ThreadSanitizer compile the entire dependency stack with sanitizer flags (submodules rebuilt with `-fsanitize=address` / `=thread` in `CXXFLAGS`, `CFLAGS`, `LDFLAGS`).

- ASan runtime: `ASAN_OPTIONS="detect_odr_violation=0"`.
- Suppressions: `ci/asan.supp`, `ci/tsan.supp`.
- Sanitizer tests continue past failures to collect all reports.
- Google Benchmark disabled under SAN (instrumentation distorts timing).

## Platform notes

### Linux

- Ninja default; Make fallback.
- `ninja` (Debian) vs `ninja-build` (RedHat).
- Linker uses `--version-script` from `vmsdk/versionscript.lds`.
- `--allow-multiple-definition` + `--start-group`/`--end-group` handle circular library deps.

### macOS

- Apple `clang` + Xcode command line tools.
- Suppresses `-Wno-defaulted-function-deleted` from Apple Clang.
- Works around gRPC submodule zlib `fdopen` detection.
- `.dylib` output.
- No integration tests in CI on macOS (build-only verification).

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| CMake can't find gRPC/Protobuf | submodules not built | `./build.sh --configure` (full configure) |
| ICU build fails | missing source in `third_party/icu/` | ICU source is committed - check checkout |
| Ninja not found | package name varies | `ninja-build` (RH) / `ninja` (Debian/macOS) |
| Multiple-definition link errors | missing `--start-group` | ensure Linux build uses generated link flags |
| "GCC version too old" | GCC < 12 | upgrade or use dev container |
| "Benchmark disabled" warning | `SAN_BUILD` set | expected - skipped for SAN builds |
