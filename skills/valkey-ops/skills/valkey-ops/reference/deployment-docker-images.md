# Docker Images and Cluster Setup

Use when choosing a Valkey Docker image (official vs Bitnami), running quick containers, or setting up a Docker Compose cluster.

## Contents

- Official Image (line 14)
- Bitnami Image (line 68)
- Tested Example: 3-Node Cluster via Docker Compose (line 105)

---

## Official Image

The official image is `valkey/valkey` on Docker Hub.

### Base Images and Tag Convention

| Tag Format | Base OS | Notes |
|------------|---------|-------|
| `<version>` or `<version>-trixie` | `debian:trixie-slim` | Default variant |
| `<version>-alpine` or `<version>-alpine3.23` | `alpine:3.23` | Smaller image |
| `latest` | Debian Trixie | Latest stable |
| `alpine` | Alpine | Latest stable Alpine |

Supported architectures: `amd64`, `arm64`, `arm` (32-bit), `ppc64le`.

The image is built with `BUILD_TLS=yes` (TLS always available), `USE_FAST_FLOAT=yes` (>= 8.1), and `USE_SYSTEMD=yes` (Debian variant only).

### Quick Start

```bash
docker run -d --name valkey \
  -p 6379:6379 \
  valkey/valkey:9
```

### Production Single Instance

```bash
docker run -d --name valkey \
  -p 6379:6379 \
  -v /data/valkey:/data \
  valkey/valkey:9 \
  valkey-server --appendonly yes --requirepass "YOUR_PASSWORD"
```

### Custom Config File

```bash
docker run -d --name valkey \
  -v /myvalkey/conf:/usr/local/etc/valkey \
  -v /myvalkey/data:/data \
  valkey/valkey:9 \
  valkey-server /usr/local/etc/valkey/valkey.conf
```

Key points:
- The working directory inside the container is `/data`
- RDB and AOF files are written to `/data` by default
- Always mount `/data` as a volume for persistence
- Protected mode is disabled at build time (source-patched) - Docker port isolation provides equivalent protection
- The entrypoint sets umask `0077` and drops privileges to the `valkey` user via `setpriv` when running as root
- Append extra flags without modifying the command via the `VALKEY_EXTRA_FLAGS` env var (e.g., `-e VALKEY_EXTRA_FLAGS="--loglevel verbose"`)


## Bitnami Image

The Bitnami image (`bitnami/valkey`) includes AOF persistence by default and supports environment-variable-based configuration.

```bash
docker run -d --name valkey \
  -e VALKEY_PASSWORD=secretpassword \
  -v valkey_data:/bitnami/valkey/data \
  bitnami/valkey:9
```

Bitnami differences from official image:
- Base OS is **Photon Linux** (VMware), not Debian. Legacy Debian images moved to `bitnamilegacy/` namespace.
- Runs as non-root (UID 1001) by default
- AOF enabled out of the box
- Config via `VALKEY_*` environment variables
- Data directory at `/bitnami/valkey/data`
- The `@` character is NOT supported in `VALKEY_PASSWORD` - known limitation
- `ALLOW_EMPTY_PASSWORD=yes` is required even for development without auth
- Partial config overrides via `/opt/bitnami/valkey/mounted-etc/overrides.conf` (ignored if a full `valkey.conf` is mounted)

Key Bitnami env vars beyond `VALKEY_PASSWORD`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `VALKEY_AOF_ENABLED` | `yes` | Toggle AOF persistence |
| `VALKEY_RDB_POLICY` | (none) | Custom RDB save policy |
| `VALKEY_RDB_POLICY_DISABLED` | `no` | Set `yes` to disable all RDB |
| `VALKEY_DISABLE_COMMANDS` | (none) | Comma-separated list of disabled commands |
| `VALKEY_IO_THREADS` | (none) | Number of I/O threads |
| `VALKEY_REPLICATION_MODE` | (none) | `primary` or `replica` |
| `VALKEY_PRIMARY_HOST` | (none) | Primary hostname for replicas |
| `VALKEY_TLS_ENABLED` | `no` | Enable TLS |
| `VALKEY_ACLFILE` | (none) | Path to ACL file |
| `VALKEY_EXTRA_FLAGS` | (none) | Additional server arguments |


## Tested Example: 3-Node Cluster via Docker Compose

Save as `docker-compose-cluster.yml` and run `docker compose -f docker-compose-cluster.yml up -d`:

```yaml
services:
  node1:
    image: valkey/valkey:9
    network_mode: host
    command: valkey-server --port 7000 --cluster-enabled yes
      --cluster-config-file nodes.conf --appendonly yes --save ""
  node2:
    image: valkey/valkey:9
    network_mode: host
    command: valkey-server --port 7001 --cluster-enabled yes
      --cluster-config-file nodes.conf --appendonly yes --save ""
  node3:
    image: valkey/valkey:9
    network_mode: host
    command: valkey-server --port 7002 --cluster-enabled yes
      --cluster-config-file nodes.conf --appendonly yes --save ""
```

After all three containers are running, create the cluster:

```bash
valkey-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 \
  --cluster-replicas 0 --cluster-yes
# Verify: valkey-cli -c -p 7000 CLUSTER INFO | grep cluster_state
# Expected: cluster_state:ok
```

---

## See Also

- [docker-patterns](docker-patterns.md) - Compose patterns, volumes, networking, config injection, resource limits
- [bare-metal](bare-metal.md) - Non-container deployment
