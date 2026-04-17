# Cluster Operations

Use when doing manual failovers, health checks, or rolling restarts on a Valkey cluster.

Redis-baseline mechanics (CLUSTER INFO fields, `CLUSTER NODES` flags, PFAIL/FAIL state machine, `valkey-cli --cluster check/fix`, slot-bitmap ownership) work the same way in Valkey. Below is what diverges or is non-obvious.

## CLUSTER FAILOVER modes

| Mode | Catch-up | Majority vote | When |
|------|---------|---------------|------|
| (default) | yes | yes | Planned maintenance, zero data loss |
| `FORCE` | no | yes | Primary unreachable but enough voting primaries are up |
| `TAKEOVER` | no | **no** - replica bumps `configEpoch` and claims slots | Majority of primaries unreachable (multi-DC failure with the DC holding the majority down) |

`TAKEOVER` is the escape hatch when quorum can't be formed. Two clusters that later re-merge with overlapping slot ownership are the usual consequence. Don't reach for it unless a real election is impossible.

Manual failover timeout is `cluster-manual-failover-timeout` (default 5000 ms). In Redis this was a compiled-in constant - Valkey made it configurable.

## Valkey cluster-scale improvements

The 9.x tree shipped several ops-visible changes:

- **Atomic slot migration** (`CLUSTER MIGRATESLOTS`) - see `cluster-resharding.md`. Replaces key-by-key `MIGRATE`/`ASK` with a fork-based bulk transfer.
- **Serialized failover election** - shards are ranked by lexicographic shard ID; higher-rank shards elect first, lower-rank ones delay. Prevents vote collisions when several primaries fail at once.
- **Reconnection throttling** - nodes no longer storm TCP reconnects to a downed peer every 100 ms. The backoff is tied to `cluster-node-timeout`.
- **Lightweight pub/sub cluster-bus headers** - internal publish messages drop the 2 KB full slot bitmap in favor of a ~30-byte header. Reduces cluster-bus traffic on pub/sub-heavy workloads.
- **Cluster bus byte metrics** (see `monitoring-metrics.md`) - `cluster_stats_bytes_sent`/`received` + pubsub/module splits exposed in `CLUSTER INFO`.

## Replica migration

`cluster-migration-barrier` (default 1) controls how many replicas a primary keeps before donating one to an orphan. `cluster-allow-replica-migration yes` (default) lets Valkey pick the smallest-node-ID replica among the most-covered primaries as the migration candidate - deterministic, so concurrent decisions don't stampede.

Practical pattern: instead of giving every primary two replicas (expensive), give a handful of extras to arbitrary primaries. Migration redistributes them on failure. Turn it off (`cluster-allow-replica-migration no`) only if you pin replicas for locality.

## Cluster observability - CLUSTER SHARDS

```sh
valkey-cli CLUSTER SHARDS
```

Shard-grouped output (primary + replicas + slot ranges per shard) scales better than `CLUSTER NODES` for large topologies. Each shard entry now also includes `availability-zone` (see `ha.md` in valkey-dev for the config wiring) if nodes set the `availability-zone` config.

## CLUSTER SLOT-STATS

Per-slot metrics (key count plus, when `cluster-slot-stats-enabled yes`, CPU usec + network bytes). Two query modes:

```
CLUSTER SLOT-STATS SLOTSRANGE <start> <end>              # specific range
CLUSTER SLOT-STATS ORDERBY <metric> [LIMIT N] [ASC|DESC] # top-K
```

Metric names: `key-count | cpu-usec | network-bytes-in | network-bytes-out`. `key-count` is always populated; the others require the enabled flag because they cost per-command accounting.

## Rolling restart recipe

Replicas first, then primaries with a failover each:

```sh
# phase 1 - replicas
for p in 7003 7004 7005; do
  valkey-cli -p $p -a $PW SHUTDOWN NOSAVE
  # systemd restarts; give it a moment
  until valkey-cli -p $p -a $PW PING >/dev/null 2>&1; do sleep 1; done
done

# phase 2 - primaries via failover
for p in 7000 7001 7002; do
  # point a replica at this primary to promote
  R_PORT=$(valkey-cli -p $p -a $PW INFO replication | awk -F, '/^slave0:/ {split($2,a,"="); print a[2]}')
  valkey-cli -p $R_PORT -a $PW CLUSTER FAILOVER
  # wait for the old primary to become a replica
  until [ "$(valkey-cli -p $p -a $PW INFO replication | awk -F: '/^role:/ {print $2}' | tr -d '\r')" = "slave" ]; do sleep 1; done
  valkey-cli -p $p -a $PW SHUTDOWN NOSAVE
  until valkey-cli -p $p -a $PW PING >/dev/null 2>&1; do sleep 1; done
done
```

The `role:slave` wait is the piece that's easy to miss - without it, the `SHUTDOWN NOSAVE` on the old primary can race the failover and cause a brief write outage.

## Troubleshooting handles

- **Stuck migrating/importing slot** - `valkey-cli --cluster fix <host>:<port>` clears orphaned MIGRATING/IMPORTING state. Review the proposed fixes before confirming.
- **`noaddr` flag in CLUSTER NODES** - node lost its advertised address; restart with correct `cluster-announce-ip` or the node can't be reached by peers.
- **`nofailover` flag** - `cluster-replica-no-failover yes` is set on the replica; intentional if the replica is meant as a read-only or backup target.
