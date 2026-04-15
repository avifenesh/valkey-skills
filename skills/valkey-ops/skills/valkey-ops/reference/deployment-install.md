# Installing Valkey

Use when setting up Valkey on a new machine - package manager, source build, or PREFIX install.

## Current Versions (as of 2026-03-29)

| Branch | Latest | Docker Tags | Notes |
|--------|--------|-------------|-------|
| 9.0.x (stable) | 9.0.3 | `9`, `9.0`, `9.0.3`, `latest` | Security release - patch immediately |
| 8.1.x | 8.1.6 | `8`, `8.1`, `8.1.6` | |
| 8.0.x | 8.0.7 | `8.0`, `8.0.7` | |
| 7.2.x | 7.2.12 | `7`, `7.2`, `7.2.12` | |

**9.0.3 is a security release** fixing three CVEs:
- CVE-2025-67733: RESP protocol injection via Lua error_reply
- CVE-2026-21863: Remote DoS with malformed cluster bus message
- CVE-2026-27623: Reset request type after handling empty requests

Subscribe to [valkey-io/valkey releases](https://github.com/valkey-io/valkey/releases) for security advisories.

Binary artifacts are published for arm64 and x86_64 on Ubuntu Jammy and Noble.


## Package Manager Install

| OS | Command |
|----|---------|
| Debian/Ubuntu | `sudo apt install valkey` |
| RHEL/CentOS | `sudo yum install valkey` |
| Fedora | `sudo dnf install valkey` |
| Arch Linux | `sudo pacman -Sy valkey` |
| Alpine | `sudo apk add valkey` |
| macOS (Homebrew) | `brew install valkey` |
| macOS (MacPorts) | `sudo port install valkey` |
| FreeBSD | `sudo pkg install valkey` |
| openSUSE | `sudo zypper install valkey` |

Valkey is not officially supported on Windows. Use WSL for development only.

After install, verify with:

```bash
valkey-server --version
valkey-cli ping    # returns PONG
```


## Building from Source

### Basic Build

```bash
# Download from https://github.com/valkey-io/valkey/releases
tar xzf valkey-<version>.tar.gz
cd valkey-<version>
make -j$(nproc)
make test              # optional but recommended
sudo make install      # installs to /usr/local/bin by default
```

The `make install` target installs these binaries to `PREFIX/bin` (default `/usr/local/bin`):
- `valkey-server` - the server binary
- `valkey-cli` - command-line client
- `valkey-benchmark` - benchmarking tool
- `valkey-check-rdb` - symlink to valkey-server (RDB file checker)
- `valkey-check-aof` - symlink to valkey-server (AOF file checker)
- `valkey-sentinel` - symlink to valkey-server (Sentinel mode)

Redis-compatible symlinks (`redis-server`, `redis-cli`, etc.) are created by default. Disable with `USE_REDIS_SYMLINKS=no`.

### Custom Install Prefix

```bash
make -j$(nproc)
sudo make install PREFIX=/opt/valkey
```

### Build Flags

Source-verified from `src/Makefile`:

| Flag | Values | Effect |
|------|--------|--------|
| `BUILD_TLS` | `yes`, `module`, (unset) | TLS support: linked in, loadable module, or disabled |
| `BUILD_RDMA` | `yes`, `module`, (unset) | RDMA transport support |
| `BUILD_LUA` | `no`, (unset) | Disable Lua scripting module (enabled by default) |
| `MALLOC` | `jemalloc`, `libc`, `tcmalloc`, `tcmalloc_minimal` | Memory allocator |
| `USE_SYSTEMD` | `yes`, `no`, (unset) | systemd notify support (auto-detected by default) |
| `USE_REDIS_SYMLINKS` | `yes`, `no` | Create redis-* compatibility symlinks (default: yes) |
| `SANITIZER` | `address`, `undefined`, `thread` | Build with sanitizers (forces libc allocator) |
| `USE_LTTNG` | `yes` | LTTng tracing support |
| `PREFIX` | path | Install prefix (default: `/usr/local`) |

### Memory Allocator Selection

The default allocator depends on platform:
- **Linux**: jemalloc (provides active defragmentation support)
- **All other OS**: libc

To override:

```bash
make MALLOC=jemalloc     # explicit jemalloc
make USE_JEMALLOC=no     # force libc on Linux
make USE_TCMALLOC=yes    # Google tcmalloc
```

Jemalloc is strongly recommended for production on Linux - it enables `activedefrag` and provides better memory fragmentation behavior.

Official Docker images are built with `BUILD_TLS=yes` and `USE_FAST_FLOAT=yes` (>= 8.1), so TLS is available out of the box in containers without a custom build.

### TLS Build

```bash
# Linked directly (smaller overhead, always available)
make BUILD_TLS=yes

# As loadable module (can be toggled without rebuild)
make BUILD_TLS=module
```

On macOS, Homebrew's OpenSSL path is auto-detected:
- arm64: `/opt/homebrew/opt/openssl`
- x86: `/usr/local/opt/openssl`

Override with `OPENSSL_PREFIX=/path/to/openssl`.

### Optimization

The default optimization level is `-O3` with LTO (Link-Time Optimization):
- Clang: `-O3 -flto`
- GCC: `-O3 -flto=auto -ffat-lto-objects`

For debug builds:

```bash
make noopt              # -O0 build
make OPTIMIZATION=-O0   # same effect
```

### Running Tests After Build

```bash
make test               # full integration test suite (Tcl-based)
make test-unit          # C unit tests
```


## Verifying the Installation

```bash
# Check version and build info
valkey-server --version

# Start with default config
valkey-server

# Start with custom config
valkey-server /etc/valkey/valkey.conf

# Test connectivity
valkey-cli ping
# PONG
```

Check build details at runtime:

```bash
valkey-cli INFO server | grep -E 'valkey_version|os|gcc_version|mem_allocator'
```

This shows the exact version, OS, compiler, and allocator in use.
