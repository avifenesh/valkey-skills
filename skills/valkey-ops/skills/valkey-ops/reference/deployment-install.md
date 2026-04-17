# Installing Valkey

Use when setting up Valkey on a new host - this covers Valkey-specific bits on top of a standard Linux package install.

## Versions

| Branch | Latest GA | Notes |
|--------|-----------|-------|
| 9.0.x (stable) | 9.0.3 | Use 9.0.3+ in production - earlier 9.0.x had hash field TTL bugs and CVE patches. |
| 8.1.x | 8.1.6 | |
| 8.0.x | 8.0.7 | |
| 7.2.x | 7.2.12 | Upstream Redis OSS compatibility branch. |

Subscribe to `valkey-io/valkey` releases for CVE advisories. Binary artifacts on arm64 and x86_64 for Ubuntu Jammy/Noble; Homebrew, apt, dnf, pacman, apk, and FreeBSD pkg all carry packages.

## Build flags worth knowing

Redis-standard build (`make && sudo make install`) works; the Valkey-specific knobs:

| Flag | Default | Effect |
|------|---------|--------|
| `USE_REDIS_SYMLINKS` | `yes` | Installs `redis-*` symlinks next to `valkey-*` binaries. Set `no` to avoid collision when Redis is also installed. |
| `BUILD_TLS` | unset | `yes` = linked, `module` = `valkey-tls<PROG_SUFFIX>.so`. |
| `BUILD_RDMA` | unset | `yes` / `module`. Linux only. |
| `BUILD_LUA` | implicit `yes` | `no` drops the Lua module entirely. |
| `PROG_SUFFIX` | empty | Suffixes every produced binary + module `.so`. Useful for side-by-side installs. |
| `MALLOC` | Linux=`jemalloc`, other=`libc` | Jemalloc is required for active defrag - don't override on Linux production. |
| `SANITIZER` | unset | `address` / `undefined` / `thread`. Forces `MALLOC=libc` for ASan/UBSan. Dev/test only. |

CMake asymmetry: `cmake` accepts only `ON`/`OFF` for `BUILD_TLS` (passing `module` triggers a warning and disables TLS), but accepts `ON`/`OFF`/`module` for `BUILD_RDMA`. The Makefile accepts `module` for both. Prefer `make` if you want TLS-as-module.

## Binaries and their identities

```
valkey-server
valkey-cli
valkey-benchmark
valkey-sentinel      -> symlink to valkey-server (Sentinel mode)
valkey-check-rdb     -> symlink to valkey-server (RDB checker)
valkey-check-aof     -> symlink to valkey-server (AOF checker)
```

With `USE_REDIS_SYMLINKS=yes` (default), the full `redis-*` set is also installed as symlinks. Legacy scripts that `exec redis-server` keep working; new scripts should use `valkey-*`.

## Allocator choice

- **Linux**: jemalloc (required for `activedefrag`).
- **macOS / BSD / musl**: libc (jemalloc build flakiness; activedefrag not supported there).

Override only if you have a reason: `make USE_JEMALLOC=no` forces libc on Linux. Tcmalloc is buildable (`USE_TCMALLOC=yes`) but not tested against active defrag.

Confirm at runtime:
```sh
valkey-cli INFO server | grep mem_allocator
```

## Verify

```sh
valkey-server --version
valkey-cli INFO server | grep -E 'valkey_version|os|gcc_version|mem_allocator'
valkey-cli ping       # PONG
```

`LOLWUT` output changed from "Redis ver." to "Valkey ver." in 9.0 - scripts that parsed LOLWUT for version detection break. Use `INFO server` instead.
