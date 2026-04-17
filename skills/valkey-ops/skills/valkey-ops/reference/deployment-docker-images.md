# Docker Images

Use when picking between Valkey Docker images.

## Official vs Bitnami

| | `valkey/valkey` (official) | `bitnami/valkey` |
|---|---|---|
| Base | Debian Trixie (slim) or Alpine 3.23 | Photon Linux (legacy Debian variants moved to `bitnamilegacy/`) |
| Build flags | `BUILD_TLS=yes`, `USE_FAST_FLOAT=yes` (≥8.1), `USE_SYSTEMD=yes` (Debian only) | Similar, plus Bitnami's non-root hardening |
| Runs as | `valkey` user (via `setpriv`) with umask `0077` | non-root UID 1001 |
| Persistence default | off (mount `/data` to enable) | AOF enabled on `/bitnami/valkey/data` |
| Config | file or `VALKEY_EXTRA_FLAGS` env | `VALKEY_*` env-var schema |
| Architectures | amd64, arm64, arm (32-bit), ppc64le | amd64, arm64 |
| Protected mode | patched off (port isolation replaces it) | on |

Pick **official** for upstream defaults, broader arch support, and config-file clarity. Pick **Bitnami** when you're already on Bitnami's chart ecosystem, need non-root enforcement out of the box, or want env-var-driven config.

## Quick shapes

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

Official image gotchas: `/data` is the working dir - RDB/AOF land there, so mount it as a volume. `VALKEY_EXTRA_FLAGS` env var appends args without rewriting the command (e.g., `VALKEY_EXTRA_FLAGS="--loglevel verbose"`).

## Bitnami env vars worth knowing

`VALKEY_PASSWORD`, `VALKEY_AOF_ENABLED` (default `yes`), `VALKEY_RDB_POLICY`, `VALKEY_RDB_POLICY_DISABLED`, `VALKEY_DISABLE_COMMANDS`, `VALKEY_IO_THREADS`, `VALKEY_REPLICATION_MODE` (`primary` / `replica`), `VALKEY_PRIMARY_HOST`, `VALKEY_TLS_ENABLED`, `VALKEY_ACLFILE`, `ALLOW_EMPTY_PASSWORD` (must be `yes` to run without auth).

Bitnami quirks: `@` character in `VALKEY_PASSWORD` is not supported (known limitation). Partial config overrides go in `/opt/bitnami/valkey/mounted-etc/overrides.conf`; if you mount a full `valkey.conf`, overrides are ignored.

## Cluster bootstrap in Compose

For a three-node cluster in Compose, `network_mode: host` is the simplest path (the cluster bus port `+10000` pattern doesn't play well with port remapping - see `kubernetes-tuning-k8s.md`). After containers are up:

```sh
valkey-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 \
           --cluster-replicas 0 --cluster-yes
```

For non-`hostNetwork` deployments, use `cluster-announce-ip` / `--cluster-announce-port` / `--cluster-announce-bus-port` per node to paper over the NAT.
