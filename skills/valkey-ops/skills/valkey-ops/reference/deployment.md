# Deployment

Use when installing Valkey on a host, configuring systemd, picking a Docker image, or writing Compose files.

## Versions

| Branch | Latest GA | Notes |
|--------|-----------|-------|
| 9.0.x (stable) | 9.0.3 | Use 9.0.3+ - earlier 9.0.x had hash field TTL bugs and CVE patches. |
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

## Binaries

```
valkey-server
valkey-cli
valkey-benchmark
valkey-sentinel      -> symlink to valkey-server (Sentinel mode)
valkey-check-rdb     -> symlink to valkey-server (RDB checker)
valkey-check-aof     -> symlink to valkey-server (AOF checker)
```

With `USE_REDIS_SYMLINKS=yes` (default), the full `redis-*` set is also installed as symlinks. Legacy scripts that `exec redis-server` keep working; new scripts should use `valkey-*`.

## Allocator

- **Linux**: jemalloc (required for `activedefrag`).
- **macOS / BSD / musl**: libc (jemalloc build flakiness; activedefrag not supported).

Override only with a reason: `make USE_JEMALLOC=no` forces libc on Linux. Tcmalloc (`USE_TCMALLOC=yes`) is buildable but not tested against active defrag.

Confirm at runtime: `valkey-cli INFO server | grep mem_allocator`.

## Verify install

```sh
valkey-server --version
valkey-cli INFO server | grep -E 'valkey_version|os|gcc_version|mem_allocator'
valkey-cli ping       # PONG
```

`LOLWUT` output changed from "Redis ver." to "Valkey ver." in 9.0 - scripts that parsed LOLWUT for version detection break. Use `INFO server` instead.

## Bare metal

Path and user names (differ from Redis):

| Redis | Valkey |
|-------|--------|
| `redis-server` | `valkey-server` |
| `redis-cli` | `valkey-cli` |
| `/etc/redis/` | `/etc/valkey/` |
| `/var/lib/redis/` | `/var/lib/valkey/` |
| `redis` user | `valkey` user |

### Systemd unit

```ini
[Unit]
Description=Valkey In-Memory Data Store
After=network-online.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/bin/valkey-server /etc/valkey/valkey.conf --supervised systemd
ExecStop=/usr/bin/valkey-cli -a $PASSWORD shutdown
Restart=always
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=full
ReadWriteDirectories=/var/lib/valkey /var/log/valkey /var/run/valkey
```

### Kernel tuning (same as Redis)

- `vm.overcommit_memory = 1` (required for fork/BGSAVE)
- `net.core.somaxconn = 65535`
- Disable THP system-wide: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`

Valkey disables THP for its own process by default (`disable-thp yes`), but system-wide disable is still recommended.

### Multiple instances

Use systemd template `valkey@.service` with per-instance configs at `/etc/valkey/valkey-<port>.conf`.

On EC2: `repl-diskless-sync yes` avoids disk-write latency during replication on EBS volumes.

## Docker: official vs Bitnami

| | `valkey/valkey` (official) | `bitnami/valkey` |
|---|---|---|
| Base | Debian Trixie (slim) or Alpine 3.23 | Photon Linux (legacy Debian variants moved to `bitnamilegacy/`) |
| Build flags | `BUILD_TLS=yes`, `USE_FAST_FLOAT=yes` (≥8.1), `USE_SYSTEMD=yes` (Debian only) | Similar, plus Bitnami's non-root hardening |
| Runs as | `valkey` user (via `setpriv`) with umask `0077` | non-root UID 1001 |
| Persistence default | off (mount `/data` to enable) | AOF enabled on `/bitnami/valkey/data` |
| Config | file or `VALKEY_EXTRA_FLAGS` env | `VALKEY_*` env-var schema |
| Architectures | amd64, arm64, arm (32-bit), ppc64le | amd64, arm64 |
| Protected mode | patched off (port isolation replaces it) | on |

Pick **official** for upstream defaults, broader arch support, and config-file clarity. Pick **Bitnami** when you're already on Bitnami's chart ecosystem, need non-root enforcement, or want env-var-driven config.

### Quick shapes

```sh
# Official, single instance with persistence
docker run -d --name valkey -p 6379:6379 \
  -v /data/valkey:/data \
  valkey/valkey:9 \
  valkey-server --appendonly yes --requirepass "$PW"

# Official, with a mounted config
docker run -d --name valkey \
  -v /myvalkey/conf:/usr/local/etc/valkey \
  -v /myvalkey/data:/data \
  valkey/valkey:9 \
  valkey-server /usr/local/etc/valkey/valkey.conf

# Bitnami
docker run -d --name valkey \
  -e VALKEY_PASSWORD=secret \
  -v valkey_data:/bitnami/valkey/data \
  bitnami/valkey:9
```

Official gotchas: `/data` is the working dir - mount it as a volume. `VALKEY_EXTRA_FLAGS` env var appends args without rewriting the command (e.g., `VALKEY_EXTRA_FLAGS="--loglevel verbose"`).

### Bitnami env vars

`VALKEY_PASSWORD`, `VALKEY_AOF_ENABLED` (default `yes`), `VALKEY_RDB_POLICY`, `VALKEY_RDB_POLICY_DISABLED`, `VALKEY_DISABLE_COMMANDS`, `VALKEY_IO_THREADS`, `VALKEY_REPLICATION_MODE` (`primary` / `replica`), `VALKEY_PRIMARY_HOST`, `VALKEY_TLS_ENABLED`, `VALKEY_ACLFILE`, `ALLOW_EMPTY_PASSWORD` (must be `yes` to run without auth).

Bitnami quirks: `@` character in `VALKEY_PASSWORD` is not supported (known limitation). Partial config overrides go in `/opt/bitnami/valkey/mounted-etc/overrides.conf`; if you mount a full `valkey.conf`, overrides are ignored.

## Docker Compose

Use Valkey names in command, healthcheck, and config params:

```yaml
image: valkey/valkey:9
command: valkey-server ...
healthcheck:
  test: ["CMD", "valkey-cli", "ping"]
```

Use `--replicaof` (not `--slaveof`) and `--primaryauth` (not `--masterauth`):

```yaml
command: >
  valkey-server
    --replicaof valkey-primary 6379
    --primaryauth secret
```

### Compose gotchas

- **UID/GID**: Debian image uses GID 999, Alpine uses GID 1000. Switching variants with the same volume requires adjusting directory group ownership or writes will fail.
- **Sentinel networking**: Use `network_mode: host` to avoid NAT issues with auto-discovery. If host networking is unavailable, set `sentinel announce-ip` and `sentinel announce-port` explicitly.
- **Cluster bootstrap**: `network_mode: host` is the simplest path (the cluster bus port `+10000` pattern doesn't play well with port remapping - see `kubernetes.md`). After containers are up: `valkey-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 --cluster-replicas 0 --cluster-yes`. For non-host-network deployments, use `cluster-announce-ip` / `cluster-announce-port` / `cluster-announce-bus-port` per node.
