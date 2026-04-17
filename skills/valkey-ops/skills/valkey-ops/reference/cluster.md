# Cluster

Use when deploying, operating, or resharding a Valkey Cluster. Redis-baseline mechanics (16384 slots, hash tags, MOVED/ASK, PFAIL/FAIL state machine, `valkey-cli --cluster check/fix`) apply - below is Valkey divergence.

## Setup

```sh
valkey-cli --cluster create \
  192.168.1.10:7000 192.168.1.11:7001 192.168.1.12:7002 \
  192.168.1.10:7003 192.168.1.11:7004 192.168.1.12:7005 \
  --cluster-replicas 1 -a "cluster-password"

valkey-cli -c -p 7000 CLUSTER INFO
valkey-cli --cluster check 192.168.1.10:7000 -a "cluster-password"
```

Minimum viable: 3 primaries (1 shard each). Production: 6 nodes (3P+3R). Both client port and cluster bus port (`client + 10000`) must be reachable between all nodes. `cluster-config-file nodes.conf` is auto-managed - do not edit.

## Key config

| Parameter | Default | Note |
|-----------|---------|------|
| `cluster-enabled` | `no` | Must be `yes`. Immutable. |
| `cluster-node-timeout` | `15000` ms | Affects failover timing and minority-partition bound. |
| `cluster-require-full-coverage` | `yes` | Stops all writes if any slot uncovered. |
| `cluster-port` | `0` (auto) | Bus port = client port + 10000. |
| `cluster-manual-failover-timeout` | `5000` ms | Valkey-only - Redis hardcodes this. |
| `cluster-slot-stats-enabled` | `no` | Enables per-slot CPU + network accounting. |
| `cluster-config-save-behavior` | `sync` | Controls `nodes.conf` save timing. |
| `availability-zone` | `""` | Gossiped; surfaced in `CLUSTER SHARDS`/`SLOTS`. |

## CLUSTER FAILOVER modes

| Mode | Catch-up | Majority vote | When |
|------|---------|---------------|------|
| (default) | yes | yes | Planned maintenance, zero data loss |
| `FORCE` | no | yes | Primary unreachable but enough voting primaries are up |
| `TAKEOVER` | no | **no** - replica bumps `configEpoch` and claims slots | Majority of primaries unreachable |

`TAKEOVER` is the escape hatch when quorum can't be formed. Two clusters re-merging with overlapping slot ownership is the usual consequence - don't reach for it unless a real election is impossible.

## Valkey cluster improvements (9.x)

- **Atomic slot migration** (`CLUSTER MIGRATESLOTS`) - fork-based bulk transfer, replaces key-by-key `MIGRATE`/`ASK`. See below.
- **Serialized failover election** - shards ranked by lexicographic shard ID; higher-rank shards elect first. Prevents vote collisions when several primaries fail at once.
- **Reconnection throttling** - nodes no longer storm TCP reconnects to downed peers every 100 ms. Backoff is tied to `cluster-node-timeout`.
- **Lightweight pub/sub cluster-bus headers** - internal publish messages drop the 2 KB full slot bitmap in favor of a ~30-byte header.
- **Cluster bus byte metrics** - `cluster_stats_bytes_sent`/`received` + pubsub/module splits in `CLUSTER INFO` (see `monitoring.md`).

## Observability

### CLUSTER SHARDS

Shard-grouped output (primary + replicas + slot ranges per shard) scales better than `CLUSTER NODES` for large topologies. Each shard entry includes `availability-zone` when nodes set the config.

### CLUSTER SLOT-STATS

Per-slot metrics. `key-count` is always populated; CPU + network need `cluster-slot-stats-enabled yes` (costs per-command accounting).

```
CLUSTER SLOT-STATS SLOTSRANGE <start> <end>
CLUSTER SLOT-STATS ORDERBY <metric> [LIMIT N] [ASC|DESC]
```

Metric names: `key-count | cpu-usec | network-bytes-in | network-bytes-out`.

## Resharding - legacy path

```sh
valkey-cli --cluster reshard <host>:<port>  # interactive
# or --cluster-from / --cluster-to / --cluster-slots / --cluster-yes for scripted
```

Under the hood: `CLUSTER SETSLOT IMPORTING/MIGRATING`, loop of `CLUSTER GETKEYSINSLOT` + `MIGRATE ... KEYS`, then `CLUSTER SETSLOT NODE`. Same mechanics as Redis. Known pain points (large keys blocking event loop, ASK redirect storms, single-DB limitation) are why 9.0 introduced ASM.

### CLUSTER SETSLOT resilience (8.0+)

`CLUSTER SETSLOT` replicates to eligible replicas (version > 7.2) and waits up to 2 s for ack before executing locally. Prevents the classic "primary died between SETSLOT and gossip" loss. Falls back to the old non-replicated path if no eligible replicas exist.

## Atomic slot migration (9.0+)

Server-driven, fork-based. Source opens a direct connection to target, forks an RDB snapshot of the migrating slots, streams incremental writes, pauses briefly at cutover, target takes ownership.

```
CLUSTER MIGRATESLOTS SLOTSRANGE <start> <end> NODE <target-node-id>

# Multi-target in one call
CLUSTER MIGRATESLOTS \
  SLOTSRANGE 0    5460  NODE <target-1-id> \
  SLOTSRANGE 5461 10922 NODE <target-2-id>
```

Ranges inclusive. All source slots must be owned by the executing node.

### ASM vs legacy

| | Legacy | ASM |
|---|---|---|
| Orchestration | External (`valkey-cli`) | Server-driven |
| Per-key ASK redirects | yes | **no** - clients see atomic swap |
| Multi-key ops during migration | Fail (CROSSSLOT) | Work normally |
| Large keys | Block event loop on MIGRATE | Streamed as element commands |
| All DBs in cluster mode | no (db 0 only) | yes |
| Cancel/rollback | Manual cleanup | `CLUSTER CANCELSLOTMIGRATIONS` |
| `valkey-cli --cluster reshard` integration | yes | planned - call command directly |

Don't mix the two on the same slot. Atomic cleanup assumes no legacy MIGRATING/IMPORTING state is also set.

### Monitoring + cancellation

```
CLUSTER GETSLOTMIGRATIONS      # list jobs: state, slot ranges, source/target, last_update_time
CLUSTER CANCELSLOTMIGRATIONS   # cancel all in-progress exports
```

Job states: `CONNECTING → SEND_AUTH → READ_AUTH_RESPONSE → SEND_ESTABLISH → READ_ESTABLISH_RESPONSE → WAITING_TO_SNAPSHOT → SNAPSHOTTING → STREAMING → WAITING_TO_PAUSE → FAILOVER_PAUSED → FAILOVER_GRANTED → SUCCESS|FAILED`.

### Write-loss window

Between "source grants ownership" and "source sees target's gossiped update", the source is paused. If the target crashes in that window, the source eventually unpauses on timeout and may accept writes the target won't have seen. Source logs:

```
Write loss risk! During slot migration, new owner did not broadcast ownership before we unpaused ourselves.
```

Alert on that log line.

### Tuning knobs

| Parameter | Purpose |
|-----------|---------|
| `client-output-buffer-limit replica ...` | Target replica COB must hold mutations during snapshot phase. Undersize = migration fails. |
| `slot-migration-max-failover-repl-bytes` | Lets high-write workloads proceed to pause phase with some mutations still in flight. |
| `cluster-slot-migration-log-max-len` | Retained completed/failed job entries in memory. |

## Replica migration

`cluster-migration-barrier` (default 1) controls how many replicas a primary keeps before donating one to an orphan. `cluster-allow-replica-migration yes` (default) makes Valkey pick the smallest-node-ID replica among the most-covered primaries - deterministic, so concurrent decisions don't stampede.

Practical pattern: give a handful of extras to arbitrary primaries instead of pairing every primary with two replicas. Migration redistributes on failure. Turn off only if you pin replicas for locality.

## Rolling restart

Replicas first, then primaries via failover:

```sh
# phase 1 - replicas
for p in 7003 7004 7005; do
  valkey-cli -p $p -a $PW SHUTDOWN NOSAVE
  until valkey-cli -p $p -a $PW PING >/dev/null 2>&1; do sleep 1; done
done

# phase 2 - primaries via failover
for p in 7000 7001 7002; do
  R_PORT=$(valkey-cli -p $p -a $PW INFO replication | awk -F, '/^slave0:/ {split($2,a,"="); print a[2]}')
  valkey-cli -p $R_PORT -a $PW CLUSTER FAILOVER
  until [ "$(valkey-cli -p $p -a $PW INFO replication | awk -F: '/^role:/ {print $2}' | tr -d '\r')" = "slave" ]; do sleep 1; done
  valkey-cli -p $p -a $PW SHUTDOWN NOSAVE
  until valkey-cli -p $p -a $PW PING >/dev/null 2>&1; do sleep 1; done
done
```

The `role:slave` wait is easy to miss - without it, `SHUTDOWN NOSAVE` can race the failover and cause a brief write outage.

## Evacuating a primary

Use `CLUSTER MIGRATESLOTS` to drain slots before removal - faster than `--cluster reshard`, doesn't block on large keys. Then standard `valkey-cli --cluster del-node`.

## Consistency

Asynchronous replication, eventual consistency, write loss on primary crash before replication.

Write-safety mechanisms (same as Redis):
- `WAIT <numreplicas> <timeout>` - synchronous replication confirmation per command
- `min-replicas-to-write 1` + `min-replicas-max-lag 10` - stops writes when isolated
- `cluster-require-full-coverage yes` - stops writes when any slot uncovered
- `cluster-allow-reads-when-down no` - stops reads when cluster FAIL

An isolated primary stops accepting writes after `cluster-node-timeout` when it loses majority contact - automatic data-loss bound without requiring `min-replicas-to-write`.

| Use case | Settings |
|----------|----------|
| Cache | `cluster-require-full-coverage no`, `cluster-allow-reads-when-down yes` |
| Session store | `cluster-require-full-coverage yes`, `min-replicas-to-write 1` |
| Critical data | All of the above + `WAIT 1 5000` per write |

## Troubleshooting handles

- **Stuck migrating/importing slot** - `valkey-cli --cluster fix <host>:<port>` clears orphaned MIGRATING/IMPORTING state. Review proposed fixes before confirming.
- **`noaddr` flag in CLUSTER NODES** - node lost its advertised address. Restart with correct `cluster-announce-ip` or peers can't reach it.
- **`nofailover` flag** - `cluster-replica-no-failover yes` is set on the replica. Intentional if the replica is a read-only or backup target.
