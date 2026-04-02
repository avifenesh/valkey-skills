# Docker Compose Patterns and Configuration

Use when writing Docker Compose files for Valkey - single instance, primary-replica, Sentinel patterns.

Standard Docker Compose patterns apply. Valkey-specific names and gotchas:

## Image and Binary Names

```yaml
image: valkey/valkey:9          # official image
command: valkey-server ...       # not redis-server
healthcheck:
  test: ["CMD", "valkey-cli", "ping"]
```

## Valkey-Specific Config Parameters

Use `--replicaof` (not `--slaveof`) and `--primaryauth` (not `--masterauth`) in Compose commands:

```yaml
command: >
  valkey-server
    --replicaof valkey-primary 6379
    --primaryauth secret
```

## Sentinel Networking

Use `network_mode: host` for Sentinel in Docker to avoid NAT issues with auto-discovery. If host networking is unavailable, set `sentinel announce-ip` and `sentinel announce-port` explicitly.

## UID/GID Gotcha

Debian image uses GID 999, Alpine image uses GID 1000. Switching between variants with the same volume requires adjusting directory group ownership or persistence writes will fail.

## Bitnami Environment Variables

```bash
-e VALKEY_PASSWORD=secret
-e VALKEY_DISABLE_COMMANDS=FLUSHDB,FLUSHALL
-e VALKEY_AOF_ENABLED=yes
```

For the full Compose YAML templates (single instance, primary-replica, Sentinel 3-node), see the Redis Compose documentation - patterns are identical with the name substitutions above.
