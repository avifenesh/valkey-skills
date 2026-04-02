# Primary-Replica Replication Setup

Use when configuring Valkey replication or setting up read replicas.

Standard Redis replication model applies - PSYNC, full/partial sync, replication backlog, chained replication. See Redis docs for full details. For tuning (backlog sizing, diskless sync, timeouts), see replication-tuning.md.

## Valkey Terminology Differences

| Redis | Valkey |
|-------|--------|
| `slaveof` | `replicaof` (preferred; `slaveof` still works) |
| `masterauth` | `primaryauth` (preferred; `masterauth` still works) |
| `masteruser` | `primaryuser` (preferred; `masteruser` still works) |
| `slave-read-only` | `replica-read-only` |
| `slave-priority` | `replica-priority` |

## Basic Config

```
replicaof 192.168.1.10 6379
primaryauth YOUR_PASSWORD
replica-read-only yes
```

## Verify Replication

```bash
valkey-cli INFO replication   # on primary: check connected_slaves, offset
valkey-cli INFO replication   # on replica: check master_link_status:up
```

## Promote Replica

```bash
valkey-cli REPLICAOF NO ONE
```

## Notes

`replicaof` is immutable in config files but changeable at runtime via `REPLICAOF` command. Set `replica-priority 0` on dedicated backup replicas to prevent promotion.
