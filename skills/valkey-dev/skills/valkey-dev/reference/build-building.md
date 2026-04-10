# Building Valkey

Use when you need to compile Valkey from source, understand build options, or set up a development environment.

Standard `make` build (delegates to `src/Makefile`). CMake alternative also available. Valkey-specific build options:

| Variable | Default | Valkey-Specific Notes |
|----------|---------|----------------------|
| `USE_REDIS_SYMLINKS` | `yes` | Install `redis-*` symlinks alongside `valkey-*` binaries |
| `BUILD_RDMA` | (unset) | `yes` for built-in RDMA, `module` for loadable module |
| `BUILD_TLS` | (unset) | `yes` built-in, `module` loadable; CMake only supports ON/OFF (not `module`) |
| `BUILD_LUA` | implicit yes | `no` to disable Lua engine entirely |
| `PROG_SUFFIX` | (empty) | Suffix appended to binary names |
| `SERVER_CFLAGS` | (empty) | Applies only to Valkey source, not deps |

Produced binaries: `valkey-server`, `valkey-sentinel`, `valkey-cli`, `valkey-benchmark`, `valkey-check-rdb`, `valkey-check-aof`. Unit tests: `make all-with-unit-tests` produces `src/unit/valkey-unit-gtests` (C++/Google Test).

Bundled deps in `deps/`: jemalloc, libvalkey (replaces hiredis), linenoise, lua, hdr_histogram, fpconv, fast_float, gtest-parallel.

Quick start: `make -j$(nproc) && make test && make install PREFIX=/usr/local`.
