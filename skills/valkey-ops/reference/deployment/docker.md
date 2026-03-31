# Docker Deployment

Use when running Valkey in containers - Docker, Docker Compose, or container orchestration.

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

## Docker Compose Patterns

### Single Instance with Persistence

```yaml
services:
  valkey:
    image: valkey/valkey:9
    container_name: valkey
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - valkey-data:/data
      - ./valkey.conf:/usr/local/etc/valkey/valkey.conf:ro
    command: valkey-server /usr/local/etc/valkey/valkey.conf
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  valkey-data:
```

### Primary with Replica

```yaml
services:
  valkey-primary:
    image: valkey/valkey:9
    container_name: valkey-primary
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - primary-data:/data
    command: >
      valkey-server
        --appendonly yes
        --requirepass replication_secret

  valkey-replica:
    image: valkey/valkey:9
    container_name: valkey-replica
    restart: unless-stopped
    ports:
      - "6380:6379"
    volumes:
      - replica-data:/data
    command: >
      valkey-server
        --replicaof valkey-primary 6379
        --primaryauth replication_secret
        --appendonly yes
    depends_on:
      - valkey-primary

volumes:
  primary-data:
  replica-data:
```

### With Sentinel (3-node)

```yaml
services:
  valkey-primary:
    image: valkey/valkey:9
    container_name: valkey-primary
    network_mode: host
    volumes:
      - primary-data:/data
    command: valkey-server --port 6379 --requirepass secret

  valkey-replica-1:
    image: valkey/valkey:9
    container_name: valkey-replica-1
    network_mode: host
    volumes:
      - replica1-data:/data
    command: >
      valkey-server --port 6380
        --replicaof 127.0.0.1 6379
        --primaryauth secret
        --requirepass secret

  sentinel-1:
    image: valkey/valkey:9
    container_name: sentinel-1
    network_mode: host
    volumes:
      - ./sentinel.conf:/etc/valkey/sentinel.conf
    command: valkey-server /etc/valkey/sentinel.conf --sentinel

volumes:
  primary-data:
  replica1-data:
```

Use `network_mode: host` for Sentinel to avoid NAT/port-mapping issues with auto-discovery. If host networking is not possible, set `sentinel announce-ip` and `sentinel announce-port` explicitly.


## Volume Mounts

| Container Path | Purpose | Mount Type |
|---------------|---------|------------|
| `/data` | RDB/AOF persistence | Named volume or bind mount |
| `/usr/local/etc/valkey/valkey.conf` | Config file | Bind mount (read-only) |

Always use named volumes or bind mounts for `/data`. Without a volume, data is lost when the container stops.

For bind mounts, ensure the host directory has correct permissions:

```bash
sudo mkdir -p /data/valkey
sudo chown 999:999 /data/valkey    # UID 999 = valkey user in official image
```

**UID/GID gotcha**: The GID differs between variants - Debian uses GID 999, Alpine uses GID 1000 (because Alpine reserves GID 999). If switching between variants with the same volume, adjust directory group ownership or the container will fail to write persistence files.


## Networking

### Port Mapping

| Port | Purpose |
|------|---------|
| 6379 | Client connections |
| 16379 | Cluster bus (port + 10000) |
| 26379 | Sentinel |

### Network Modes

- **Bridge (default)**: Fine for standalone instances. Clients connect via mapped port.
- **Host**: Simplest option for Sentinel and Cluster in Docker. Alternatively, configure announced addresses (`cluster-announce-ip`/`sentinel announce-ip`) to avoid NAT issues.
- **Overlay**: For Docker Swarm multi-host deployments.

For Cluster mode, use `--net=host` or set `cluster-announce-ip`, `cluster-announce-port`, and `cluster-announce-bus-port` to the host's external addresses.


## Config Injection Patterns

### Command-Line Arguments

Pass config directly as arguments after `valkey-server`:

```bash
docker run valkey/valkey:9 valkey-server \
  --maxmemory 1gb \
  --maxmemory-policy allkeys-lru \
  --appendonly yes
```

### Config File Mount

Mount a complete config file:

```bash
docker run -v ./valkey.conf:/usr/local/etc/valkey/valkey.conf:ro \
  valkey/valkey:9 valkey-server /usr/local/etc/valkey/valkey.conf
```

### Environment Variables (Bitnami only)

```bash
docker run \
  -e VALKEY_PASSWORD=secret \
  -e VALKEY_DISABLE_COMMANDS=FLUSHDB,FLUSHALL \
  -e VALKEY_AOF_ENABLED=yes \
  bitnami/valkey:9
```


## Resource Limits

Set memory limits in Docker to prevent OOM kills:

```yaml
services:
  valkey:
    image: valkey/valkey:9
    deploy:
      resources:
        limits:
          memory: 2g
    command: valkey-server --maxmemory 1536mb --maxmemory-policy allkeys-lru
```

Set `maxmemory` to roughly 75% of the container memory limit. The remaining 25% covers:
- Fork overhead during BGSAVE/BGREWRITEAOF
- Client output buffers
- Replication backlog
- Internal data structure overhead

## See Also

- [Installing Valkey](install.md) - package manager and source builds
- [Configuration Essentials](../configuration/essentials.md) - all config defaults
- [Workload Presets](../configuration/workload-presets.md) - complete configs by use case
- [Eviction Policies](../configuration/eviction.md) - maxmemory-policy for container memory limits
- [Bare Metal Setup](bare-metal.md) - non-container deployment
- [Kubernetes Helm](../kubernetes/helm.md) - Helm chart deployment
- [Sentinel Deployment Runbook](../sentinel/deployment-runbook.md) - Docker Sentinel considerations
- [Cluster Setup](../cluster/setup.md) - cluster mode with Docker (requires host networking or announce addresses)
- [Production Checklist](../production-checklist.md) - full pre-launch verification
