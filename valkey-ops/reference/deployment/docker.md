# Docker Deployment

Use when running Valkey in containers - Docker, Docker Compose, or container orchestration.

---

## Official Image

The official image is `valkey/valkey` on Docker Hub.

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


## Bitnami Image

The Bitnami image (`bitnami/valkey`) includes AOF persistence by default and supports environment-variable-based configuration.

```bash
docker run -d --name valkey \
  -e VALKEY_PASSWORD=secretpassword \
  -v valkey_data:/bitnami/valkey/data \
  bitnami/valkey:9
```

Bitnami differences from official image:
- Runs as non-root (UID 1001) by default
- AOF enabled out of the box
- Config via `VALKEY_*` environment variables
- Data directory at `/bitnami/valkey/data`


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


## Networking

### Port Mapping

| Port | Purpose |
|------|---------|
| 6379 | Client connections |
| 16379 | Cluster bus (port + 10000) |
| 26379 | Sentinel |

### Network Modes

- **Bridge (default)**: Fine for standalone instances. Clients connect via mapped port.
- **Host**: Required for Sentinel and Cluster in Docker. Avoids NAT issues with node discovery.
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

- [Configuration Essentials](../configuration/essentials.md) - all config defaults
- [Bare Metal Setup](bare-metal.md) - non-container deployment
- [Kubernetes Helm](../kubernetes/helm.md) - Helm chart deployment
- [Sentinel Deployment Runbook](../sentinel/deployment-runbook.md) - Docker Sentinel considerations
- [Production Checklist](../production-checklist.md) - full pre-launch verification
