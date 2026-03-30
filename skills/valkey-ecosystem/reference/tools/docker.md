# Docker

Use when running Valkey in Docker containers for development, testing, or production - choosing images, configuring persistence, and hardening containers.

---

## Official Images

### valkey/valkey

The primary Docker image, published to Docker Hub and GitHub Container Registry (ghcr.io/valkey-io/valkey). Forked from docker-library/redis and maintained by the Valkey community.

**Registries**:
- Docker Hub: `docker pull valkey/valkey`
- GHCR: `docker pull ghcr.io/valkey-io/valkey`

**Available versions** (each with Debian and Alpine variants, as of 2026-03):

| Version | Latest Patch | Base OS Options | Notes |
|---------|-------------|-----------------|-------|
| 7.2 | 7.2.12 | Debian Trixie, Alpine 3.23 | LTS |
| 8.0 | 8.0.7 | Debian Trixie, Alpine 3.23 | CLUSTER SLOT-STATS |
| 8.1 | 8.1.6 | Debian Trixie, Alpine 3.23 | COMMANDLOG |
| 9.0 | 9.0.3 | Debian Trixie, Alpine 3.23 | Latest stable |
| 9.1 | 9.1.0-rc1 | Debian Trixie, Alpine 3.23 | Release candidate |
| unstable | HEAD | Debian Trixie, Alpine 3.23 | Dev only |

**Tag conventions**:
- `valkey/valkey:9.0` - latest patch in the 9.0 series (Debian-based)
- `valkey/valkey:9.0.3` - exact patch version
- `valkey/valkey:9.0-alpine` - Alpine variant of the 9.0 series
- `valkey/valkey:9.0.3-alpine` - exact patch, Alpine variant
- `valkey/valkey:latest` - latest stable release
- `valkey/valkey:unstable` - development build from HEAD

**Default port**: 6379

**Data directory**: `/data`

**Runs as**: `valkey` user (UID varies by image). The entrypoint automatically chowns the data directory and drops privileges from root to the `valkey` user via `setpriv`.

### valkey/valkey-bundle

Packages Valkey with all official modules in a single image. Use this when you need JSON, Bloom, Search, or LDAP capabilities.

```bash
docker pull valkey/valkey-bundle
```

Included modules: valkey-json, valkey-bloom, valkey-search, valkey-ldap.

### Bitnami Images

Bitnami publishes Valkey images at `docker.io/bitnami/valkey`. The Bitnami Helm
charts (`bitnami/valkey` and `bitnami/valkey-cluster`) use these images along
with bundled redis-exporter for Prometheus metrics. Note that Bitnami charts
require a commercial subscription for production use.

For Testcontainers usage, see the [Testing Tools](testing.md) reference.

---

## Quick Start

### Standalone

```bash
docker run -d --name valkey \
  -p 6379:6379 \
  valkey/valkey:9.0
```

### With Custom Configuration

Pass config directives as command arguments:

```bash
docker run -d --name valkey \
  -p 6379:6379 \
  valkey/valkey:9.0 \
  valkey-server --maxmemory 256mb --maxmemory-policy allkeys-lru
```

Or mount a configuration file:

```bash
docker run -d --name valkey \
  -p 6379:6379 \
  -v /path/to/valkey.conf:/usr/local/etc/valkey/valkey.conf \
  valkey/valkey:9.0 \
  valkey-server /usr/local/etc/valkey/valkey.conf
```

### Extra Flags via Environment

The entrypoint appends the `VALKEY_EXTRA_FLAGS` environment variable to the server command:

```bash
docker run -d --name valkey \
  -e VALKEY_EXTRA_FLAGS="--loglevel verbose" \
  valkey/valkey:9.0
```

---

## Docker Compose Patterns

### Development (Standalone)

```yaml
services:
  valkey:
    image: valkey/valkey:9.0
    ports:
      - "6379:6379"
    volumes:
      - valkey-data:/data

volumes:
  valkey-data:
```

### Primary-Replica

```yaml
services:
  valkey-primary:
    image: valkey/valkey:9.0
    ports:
      - "6379:6379"
    volumes:
      - primary-data:/data

  valkey-replica:
    image: valkey/valkey:9.0
    command: valkey-server --replicaof valkey-primary 6379
    depends_on:
      - valkey-primary

volumes:
  primary-data:
```

### Cluster (6-Node Minimum)

Each node needs `--cluster-enabled yes`, `--cluster-config-file nodes.conf`, and `--cluster-node-timeout 5000`. Define 6 services (3 primaries + 3 replicas) with per-node volumes, then use an init container to run `valkey-cli --cluster create` with `--cluster-replicas 1 --cluster-yes`.

### With Modules (Bundle)

Replace `valkey/valkey:9.0` with `valkey/valkey-bundle:latest` to get valkey-json, valkey-bloom, valkey-search, and valkey-ldap.

Spring Boot auto-detects Valkey services in `compose.yaml` when `spring-boot-docker-compose` is on the classpath. See [Framework Integrations](frameworks.md) for details.

---

## Volume Mounts and Persistence

The default data directory is `/data`. Mount a volume there to persist RDB snapshots and AOF files across container restarts.

```bash
docker run -d --name valkey \
  -v valkey-data:/data \
  valkey/valkey:9.0 \
  valkey-server --save 60 1000 --appendonly yes
```

**Key persistence flags**:
- `--save 60 1000` - RDB snapshot every 60 seconds if at least 1000 keys changed
- `--appendonly yes` - enable AOF logging
- `--appendfsync everysec` - fsync AOF once per second (default, good balance)

The entrypoint checks directory writability and warns if the data directory is not writable by the current user.

---

## Production Container Hardening

### Non-Root Execution

The official image handles this automatically. The entrypoint detects if running as root, chowns the data directory to the `valkey` user, and drops privileges via `setpriv`. No manual configuration needed.

To explicitly run as non-root from the start:

```bash
docker run -d --user valkey \
  -v valkey-data:/data \
  valkey/valkey:9.0
```

### Read-Only Filesystem

```bash
docker run -d --name valkey \
  --read-only \
  --tmpfs /tmp \
  -v valkey-data:/data \
  valkey/valkey:9.0
```

### Additional Hardening

- **Resource limits**: Set `deploy.resources.limits` for CPU and memory in Compose, or `--memory` / `--cpus` with `docker run`
- **Security options**: Use `--security-opt no-new-privileges:true` and `--cap-drop ALL`
- **Authentication**: Always set `--requirepass` or configure ACL users for any exposed deployment
- **Umask**: The entrypoint sets umask to `0077` if the default `0022` is detected, preventing world-readable files

---

## Image Tag Pinning Strategy

| Environment | Tag Strategy | Example |
|-------------|-------------|---------|
| Development | Major.minor series | `valkey/valkey:9.0` |
| CI/Testing | Exact patch version | `valkey/valkey:9.0.3` |
| Production | Exact patch + digest | `valkey/valkey:9.0.3@sha256:...` |

Avoid `latest` in CI and production - it creates non-reproducible builds. The `unstable` tag tracks the development branch and should never be used outside of Valkey development.

Protected mode is disabled in the Docker image at build time (patched in the Dockerfile) since Docker's network isolation provides equivalent protection. Enable authentication via `--requirepass` or ACLs for any exposed deployment.

---

## See Also

- [Testing Tools](testing.md) - Testcontainers for disposable Valkey instances in tests
- [Infrastructure as Code](iac.md) - Helm charts for Kubernetes deployment
- [CI/CD](ci-cd.md) - Using Valkey containers in CI pipelines
- [Security](security.md) - ACL, TLS, and supply chain security
- **valkey-ops** skill - Production deployment, persistence tuning, and monitoring
