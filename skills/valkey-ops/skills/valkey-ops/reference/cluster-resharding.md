# Cluster Resharding

Use when moving slots between nodes. Two paths exist: the legacy key-by-key `MIGRATE` path (all Valkey versions) and atomic slot migration (9.0+). The legacy path is Redis-standard operationally; this file focuses on ASM and the interplay.

## Legacy resharding (summary)

Invoked via `valkey-cli --cluster reshard <host>:<port>` (interactive) or with `--cluster-from`/`--cluster-to`/`--cluster-slots`/`--cluster-yes` flags for scripted runs. Under the hood it orchestrates:

```
Target:  CLUSTER SETSLOT <slot> IMPORTING <source-id>
Source:  CLUSTER SETSLOT <slot> MIGRATING <target-id>
Source:  loop { CLUSTER GETKEYSINSLOT + MIGRATE ... KEYS ... }
All:     CLUSTER SETSLOT <slot> NODE <target-id>
```

Same mechanics as Redis. Known failure modes - large keys blocking the event loop, ASK redirect storms, single-DB limitation - are why 9.0 introduced ASM.

## Atomic slot migration (Valkey 9.0+)

Server-driven, fork-based. No external orchestrator - the source opens a direct connection to the target, forks an RDB snapshot of the migrating slots, streams incremental writes, pauses briefly at cutover, the target takes ownership. See `ha.md` in valkey-dev for the internal state machine.

```
CLUSTER MIGRATESLOTS SLOTSRANGE <start> <end> NODE <target-node-id>

# Multi-target in one call:
CLUSTER MIGRATESLOTS \
  SLOTSRANGE 0    5460  NODE <target-1-id> \
  SLOTSRANGE 5461 10922 NODE <target-2-id>
```

Ranges inclusive. All source slots must be owned by the executing node.

## ASM vs legacy - operational differences

| | Legacy | ASM |
|---|---|---|
| Orchestration | External (`valkey-cli`) | Server-driven |
| Per-key ASK redirects | yes | **no** - clients see atomic swap |
| Multi-key ops during migration | Fail (CROSSSLOT) | Work normally |
| Large keys | Block event loop on MIGRATE | Streamed as element commands; no single huge payload |
| All DBs in cluster mode | no (db 0 only) | yes |
| Cancel/rollback | Manual cleanup | `CLUSTER CANCELSLOTMIGRATIONS` |
| valkey-cli reshard integration | yes | planned (not in 9.0 - call `CLUSTER MIGRATESLOTS` directly) |

Don't mix the two on the same slot. Atomic cleanup assumes no legacy MIGRATING/IMPORTING state is also set on the slot being moved.

## Monitoring + cancellation

```
CLUSTER GETSLOTMIGRATIONS      # list jobs: state, slot ranges, source/target, last_update_time
CLUSTER CANCELSLOTMIGRATIONS   # cancel all in-progress exports
```

Job states: `CONNECTING → SEND_AUTH → READ_AUTH_RESPONSE → SEND_ESTABLISH → READ_ESTABLISH_RESPONSE → WAITING_TO_SNAPSHOT → SNAPSHOTTING → STREAMING → WAITING_TO_PAUSE → FAILOVER_PAUSED → FAILOVER_GRANTED → SUCCESS|FAILED`.

## Write-loss window

Between "source grants ownership" and "source sees target's gossiped update", the source is paused. If the target crashes in that window, the source eventually unpauses on timeout and may accept writes the target won't have seen. Logged on the source as:

```
Write loss risk! During slot migration, new owner did not broadcast ownership before we unpaused ourselves.
```

Alert on that log line. It's not a common failure mode but the operator needs to know when it fires.

## Tuning knobs

| Parameter | Purpose |
|-----------|---------|
| `client-output-buffer-limit replica ...` | Target replica COB must hold mutations accumulated during the snapshot phase. Undersize = migration fails. |
| `slot-migration-max-failover-repl-bytes` | Lets high-write workloads proceed to pause phase with some mutations still in flight. |
| `cluster-slot-migration-log-max-len` | Retained completed/failed job entries in memory. |

## CLUSTER SETSLOT resilience (Valkey 8.0+)

Applies to legacy migration: `CLUSTER SETSLOT` replicates to eligible replicas (version > 7.2) and waits up to 2 s for ack before executing locally. Prevents the classic "primary died between SETSLOT and gossip" loss. Falls back to the old non-replicated path if no eligible replicas exist.

## Add / remove nodes

Node addition and removal are Redis-standard flows (`valkey-cli --cluster add-node`, `--cluster-replica`, `--cluster-master-id`, `CLUSTER REPLICATE`, `--cluster del-node`). The only Valkey twist: use `CLUSTER MIGRATESLOTS` instead of `--cluster reshard` to evacuate a primary being removed - faster, doesn't block on large keys.
