# Replication Safety

Use when hardening replication against data loss. Redis baseline applies - this file is the ops-gotcha list.

## min-replicas knobs

| Parameter | Default | Notes |
|-----------|---------|-------|
| `min-replicas-to-write` | `0` | Minimum online replicas required to accept writes. `0` = disabled. |
| `min-replicas-max-lag` | `10` s | A replica counts as "online" only if its last interaction was within this window. |

Example: `min-replicas-to-write 1` + `min-replicas-max-lag 10` means the primary rejects writes (`-NOREPLICAS ...`) when it has no replica within 10 seconds. Reads still work.

Trade-off is availability: higher `min-replicas-to-write` makes the primary read-only during replica maintenance. Typical prod setting for a 1+2 topology is `1`/`10`; strict-durability setups use `2`/`10` and accept reduced availability.

## `WAIT` - per-command sync

```
WAIT <numreplicas> <timeout-ms>
```

Blocks until `numreplicas` replicas acknowledge the **in-memory** apply, or the timeout hits. Returns the number that ack'd.

Caveats: `WAIT` confirms memory application, not disk fsync. It doesn't make Valkey strongly consistent - a subsequent failover can still lose writes if the ack'd replicas aren't all up-to-date. Use sparingly - adds latency equal to replication-ACK RTT per call.

## Incident patterns

### 1. Primary without persistence → cascading data loss

**Scenario**: primary runs pure in-memory (no `appendonly`, no `save`). systemd restarts it after a crash. It comes back empty. Replicas connect, full-sync from the empty primary, wipe their own data. Total loss.

This is a real production outage pattern, not theoretical. Prevention:

- Turn on persistence on every primary (`appendonly yes` + `save 3600 1 300 100 60 10000`), **or**
- Set `Restart=no` / `Restart=on-failure` + `StartLimitBurst=0` in systemd so the empty primary doesn't come back automatically, **or**
- Run Sentinel with `down-after-milliseconds` tight enough that promotion wins the race.

If you take nothing else from this file: persistence on the primary is the single most important safety knob.

### 2. Writable replicas

Default is `replica-read-only yes`. Flipping it to `no` lets writes land on a replica, where they exist until the next full resync wipes them. Symptoms: clients see "phantom" writes that vanish post-resync, monitoring shows divergent key counts. Don't change this unless the use case is truly niche.

### 3. Network partition split-brain

Classic Sentinel/cluster case: primary + client on one side of the partition, replica + failover quorum on the other. Partition heals, old primary becomes a replica of the promoted one, writes from the isolated window are lost.

Mitigation is `min-replicas-to-write` + `min-replicas-max-lag` - the isolated primary goes read-only after the lag threshold, bounding the write-loss window to roughly `min-replicas-max-lag` seconds.

### 4. Cascading full resyncs

Primary restart or brief network blip → all replicas reconnect simultaneously → if `repl-backlog-size` is undersized → all trigger **full** resync. The primary forks (or batches with `repl-diskless-sync-delay`), CPU/memory spike cascades into more lag, more resyncs.

Mitigation:

- Size `repl-backlog-size` generously (see `replication-tuning.md`).
- Keep `repl-diskless-sync-delay 5` so multiple replicas arriving together share one transfer.
- Stagger replica restarts during maintenance.
- Alert on `sync_full` counter (should be ~0 in steady state).

### 5. Replication lag under write burst

Replicas fall behind when they can't keep up with the primary's write rate. Once a replica exceeds `min-replicas-max-lag`, it stops counting toward `min-replicas-to-write` - if enough replicas lag out, the primary goes read-only.

Check `INFO replication`'s `slave*:lag` field. Sustained lag > 5 s is worth investigating; > 30 s usually means the replica is underprovisioned (CPU or network) relative to the primary's write rate.

### 6. Bandwidth-bound failures

Large payload distributions saturate network before CPU or memory thresholds trip. Alert on NIC utilization per node (> 70% of line rate) alongside the classic command-count metrics. MPTCP (`mptcp yes` / `repl-mptcp yes`, Valkey 9.0+, Linux 5.6+) can help by using multiple network paths, but only if both ends of the link support it.

## What to alert on

- `master_link_status:down` on any replica.
- `slave*:lag` on primary > 5 s warn, > 30 s crit.
- `rdb_last_bgsave_status:err` on primary.
- `connected_slaves` lower than expected.
- `sync_full` counter incrementing in steady state (indicates backlog is undersized).
- `master_repl_offset - slave_repl_offset` approaching `repl_backlog_size * 0.8`.
