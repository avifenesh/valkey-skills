# Pub/Sub Operational Configuration

Use when running Pub/Sub workloads, managing subscriber memory, configuring keyspace notifications, or using sharded Pub/Sub in cluster mode.

Standard Redis Pub/Sub configuration applies. See Redis docs for general Pub/Sub config, buffer limits, and keyspace notifications.

## Valkey Default Values (same as Redis)

- `client-output-buffer-limit pubsub 32mb 8mb 60`
- `notify-keyspace-events ""` (disabled by default)
- `acl-pubsub-default resetchannels` (new users have no channel access)

## Valkey-Specific: Sharded Pub/Sub

Valkey supports sharded Pub/Sub in cluster mode via `SSUBSCRIBE`/`SPUBLISH`. Messages route by hash slot instead of broadcasting to all nodes. Use for high-throughput cluster deployments.

```
cluster-allow-pubsubshard-when-down yes   # default
```

## Valkey-Specific: maxmemory-clients Interaction

When `maxmemory-clients` is set, client eviction may disconnect slow Pub/Sub subscribers before they hit the output buffer hard limit. Use `CLIENT NO-EVICT on` for critical monitoring subscribers.

## Monitoring

```bash
valkey-cli INFO clients | grep pubsub
valkey-cli CLIENT LIST TYPE pubsub
```
