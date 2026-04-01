# Building Valkey

Use when you need to compile Valkey from source, understand build options, or set up a development environment.

## Contents

- Prerequisites (line 22)
- Quick Start (line 38)
- Build System Architecture (line 46)
- Key Makefile Variables (line 99)
- TLS Support (line 122)
- Dependencies (`deps/`) (line 149)
- Build Targets Reference (line 170)
- Produced Binaries (line 192)
- Cross-Platform Notes (line 207)
- Compiler Detection (line 216)
- Troubleshooting (line 220)
- See Also (line 228)

---

## Prerequisites

Valkey requires a C11-capable compiler (GCC or Clang), GNU Make, and pkg-config. On Linux, jemalloc is the default allocator and is bundled in `deps/`. No external package manager dependencies are needed for a basic build.

For tests, install Tcl 8.5+ and tclx:

```
sudo apt-get install tcl8.6 tclx
```

For unit tests (C++ / Google Test):

```
sudo apt-get install pkg-config libgtest-dev libgmock-dev
```

## Quick Start

```
make -j$(nproc)
make test
make install PREFIX=/usr/local
```

## Build System Architecture

Valkey supports two build systems:

- **GNU Make** (primary) - the root `Makefile` delegates to `src/Makefile`
- **CMake** (alternative) - `CMakeLists.txt` at root, outputs to a build directory

The Make system is used in CI and is the canonical build path. CMake generates `compile_commands.json` for IDE support and places binaries in `build-dir/bin/`.

### Make Build

All real build logic lives in `src/Makefile`. The top-level `Makefile` simply does `cd src && $(MAKE) $@`.

```
# Standard optimized build (default: -O3 with LTO)
make

# Build everything including unit test binary
make all-with-unit-tests

# Debug build (no optimization)
make noopt

# Valgrind-compatible build (no optimization, libc malloc)
make valgrind

# 32-bit build
make 32bit

# Code coverage build
make gcov
```

### CMake Build

```
mkdir build-release && cd build-release
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
```

CMake options:

| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_LUA` | ON | Build Lua scripting engine module |
| `BUILD_UNIT_GTESTS` | OFF | Build valkey-unit-gtests binary |
| `BUILD_TEST_MODULES` | OFF | Build test modules |
| `BUILD_EXAMPLE_MODULES` | OFF | Build example modules |
| `BUILD_TLS` | OFF | Enable TLS support (pass-through to Make, not a CMake `option()`; only ON/OFF - does not support `module` mode) |

CMake copies the `runtest*` scripts into the build directory with `VALKEY_BIN_DIR` set so tests find the CMake-built binaries.

## Key Makefile Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MALLOC` | `jemalloc` (Linux), `libc` (other) | Memory allocator |
| `BUILD_TLS` | (unset) | `yes` for built-in TLS, `module` for loadable module |
| `BUILD_RDMA` | (unset) | `yes` for built-in RDMA, `module` for loadable module |
| `BUILD_LUA` | (implicit yes) | `no` to disable Lua engine |
| `SANITIZER` | (unset) | `address`, `undefined`, or `thread` ([details](sanitizers.md)) |
| `SERVER_CFLAGS` | (empty) | Extra flags for Valkey only (not deps) |
| `SERVER_LDFLAGS` | (empty) | Extra linker flags for Valkey only |
| `OPTIMIZATION` | `-O3` | Override optimization level |
| `OPT` | (derived) | Full optimization flags, overrides all defaults |
| `USE_SYSTEMD` | auto-detect | `yes`/`no` for systemd notify support |
| `USE_LIBBACKTRACE` | `no` | `yes` to link libbacktrace for stack traces |
| `USE_LTTNG` | (unset) | `yes` to enable LTTng tracing |
| `PREFIX` | `/usr/local` | Installation prefix |
| `V` | (unset) | Set to any value for verbose build output |
| `USE_REDIS_SYMLINKS` | `yes` | Install redis-* symlinks alongside valkey-* |
| `PROG_SUFFIX` | (empty) | Suffix appended to binary names |

`SERVER_CFLAGS` is important: it applies only to Valkey source, not to dependencies. Use it for `-Werror` in CI or custom defines. Plain `CFLAGS` propagates to dependency builds too.

## TLS Support

Build with OpenSSL linked directly:

```
make BUILD_TLS=yes
```

Build TLS as a loadable module:

```
make BUILD_TLS=module
```

On macOS, Homebrew OpenSSL is not in the default path. The Makefile auto-detects it:

- arm64: `OPENSSL_PREFIX=/opt/homebrew/opt/openssl`
- x86: `OPENSSL_PREFIX=/usr/local/opt/openssl`

Override with `OPENSSL_PREFIX=/path/to/openssl` if needed.

For TLS testing, generate test certificates first:

```
./utils/gen-test-certs.sh
```

## Dependencies (`deps/`)

All dependencies are vendored in `deps/` and built automatically:

| Directory | What | Notes |
|-----------|------|-------|
| `jemalloc/` | Memory allocator | Custom patches for active defragmentation |
| `libvalkey/` | Official C client library | Used by valkey-cli, valkey-benchmark, Sentinel |
| `linenoise/` | Readline replacement | Used by valkey-cli |
| `lua/` | Lua 5.1 scripting | Security-patched, with cjson/struct/cmsgpack/bit |
| `hdr_histogram/` | Latency histogram tracking | Per-command latency histograms |
| `fpconv/` | Float conversion | Fast float-to-string |
| `fast_float/` | ffc.h - C99 fast_float port | String-to-double conversion |
| `gtest-parallel/` | Google Test parallel runner | Runs unit test binary in parallel |

Dependencies are rebuilt automatically when needed. To force a full clean:

```
make distclean
```

## Build Targets Reference

| Target | Description |
|--------|-------------|
| `make` / `make all` | Build server, sentinel, cli, benchmark, check-rdb, check-aof |
| `make all-with-unit-tests` | Above plus `valkey-unit-gtests` binary |
| `make test` | Build then run integration tests via `./runtest` |
| `make test-unit` | Run C++ unit tests (requires prior `all-with-unit-tests`) |
| `make test-modules` | Run module API tests via `./runtest-moduleapi` |
| `make test-sentinel` | Run Sentinel tests via `./runtest-sentinel` |
| `make test-cluster` | Run cluster tests via `./runtest-cluster` |
| `make install` | Install binaries to `PREFIX/bin`, Lua module to `PREFIX/lib` |
| `make noopt` | Build with `-O0` for debugging |
| `make valgrind` | Build with `-O0` and libc malloc for Valgrind |
| `make helgrind` | Build for Helgrind thread checking |
| `make gcov` | Build with coverage instrumentation |
| `make lcov` | Build with coverage, run tests, generate HTML report |
| `make 32bit` | Cross-compile 32-bit binary |
| `make bench` | Build and run valkey-benchmark |
| `make clean` | Remove build artifacts in `src/` |
| `make distclean` | Clean everything including deps |

## Produced Binaries

After `make`, the following appear in `src/`:

- `valkey-server` - the server
- `valkey-sentinel` - copy of valkey-server (becomes a symlink during `make install`)
- `valkey-cli` - command-line client
- `valkey-benchmark` - benchmarking tool
- `valkey-check-rdb` - copy of valkey-server (becomes a symlink during `make install`)
- `valkey-check-aof` - copy of valkey-server (becomes a symlink during `make install`)

After `make all-with-unit-tests`, additionally:

- `src/unit/valkey-unit-gtests` - C++ unit test binary

## Cross-Platform Notes

- **Linux**: Full support. jemalloc default. `-rdynamic` linked for crash stack traces.
- **macOS**: Clang forced by CMake. Homebrew LLVM needed for full warning set in CI. ARM64 and x86 paths differ for OpenSSL.
- **FreeBSD/DragonFly/OpenBSD/NetBSD**: Supported. Uses `-lpthread -lexecinfo`.
- **Haiku**: Supported with BSD_SOURCE define.
- **SunOS/AIX**: Basic support with platform-specific flags.
- **32-bit**: Requires `libc6-dev-i386` and cross-compile libs on 64-bit hosts.

## Compiler Detection

The Makefile detects C11 `_Atomic` support and uses `-std=gnu11` if available, falling back to `-std=c99`. Clang is detected for LTO flag differences (`-flto` vs `-flto=auto -ffat-lto-objects`).

## Troubleshooting

**"jemalloc/jemalloc.h: No such file"** - Run `make distclean` then `make`. The deps need to be rebuilt.

**Warnings as errors** - CI uses `SERVER_CFLAGS='-Werror'`. Drop this flag for local development if you hit warnings in progress.

**stale object files after switching options** - Run `make distclean` when changing `BUILD_TLS`, `MALLOC`, or `SANITIZER` settings. The Makefile persists settings in `src/.make-settings` and detects mismatches, but a full clean is safest.
