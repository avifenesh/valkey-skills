# High Availability (Cluster + Sentinel)

Topology, failover, slot migration. Base algorithms (16,384-slot hash cluster, gossip, MOVED/ASK, bus port = port+10000, PFAIL → FAIL quorum, Raft-like leader election for Sentinel, SDOWN/ODOWN/TILT) are all unchanged from Redis. Everything below is divergence.

## Cluster shape

- **Multi-database cluster**: cluster mode is **not** limited to DB 0. `getKVStoreIndexForKey()` routes by slot; `selectDb()` works in cluster mode. Migrations transfer all DBs.
- **Shard dictionary**: `clusterState.shards` maps `shard_id -> list(clusterNode)` for shard-level operations.
- **Atomic slot migration jobs**: `clusterState.slot_migration_jobs` alongside the legacy `migrating_slots_to` / `importing_slots_from`.
- **Availability zone per node**: `availability-zone` config is a free-form SDS propagated via gossip and surfaced in `CLUSTER SHARDS` / `CLUSTER SLOTS` replies. Node field: `clusterNode.availability_zone`. Used by clients for AZ-aware replica selection.
- **`cluster-config-save-behavior`**: enum config controlling when `nodes.conf` is persisted. Default `sync` (save immediately on change). Alternatives reduce I/O at the cost of recovery precision after crash.

INFO / CLUSTER INFO bus metrics (always populated): `cluster_stats_bytes_{sent,received}`, plus per-category splits `cluster_stats_pubsub_bytes_{sent,received}` and `cluster_stats_module_bytes_{sent,received}`. Accounted in `clusterBusAddNetworkBytesByType` - add a call there when introducing new cluster-bus message types.

Files: `src/cluster.c`, `src/cluster_legacy.c`, `src/cluster_migrateslots.c`, `src/cluster_slot_stats.c`.

## Cluster failover (replica election)

- **Coordinated immediate start**: when all replicas in the shard agree the primary is down AND the best-ranked replica has a rank-0 primary, election starts with zero delay (rather than standard jittered wait).
- **Failed-primary rank in election delay**: `clusterGetFailedPrimaryRank()` contributes to the election start delay so concurrent elections across multiple failing shards don't collide.
- **Configurable manual-failover timeout**: `server.cluster_mf_timeout` (config `cluster-manual-failover-timeout`, default 5000 ms). In Redis this is a hardcoded constant.

All in `src/cluster_legacy.c`.

## Slot migration - two mechanisms coexist

### Traditional `CLUSTER SETSLOT` + `MIGRATE` (Redis baseline)

`MIGRATING`/`IMPORTING`/`STABLE`/`NODE` subcommand loop + key-by-key `MIGRATE` + `ASK`/`MOVED`/`TRYAGAIN` redirects. Valkey-specific wrinkle:

- **`CLUSTER SETSLOT` replicates before executing**: primary blocks the client, replicates the command, waits for eligible replicas (version > 7.2) to ACK, then executes locally. Prevents topology loss on primary crash between execute and gossip. `clusterCommandSetSlot` in `cluster_legacy.c` has the version check (`replica_version > 0x702ff`).

`getNodeByQuery()` in `src/cluster.c` is the single source of truth for redirect decisions.

### Atomic slot migration (`src/cluster_migrateslots.c`)

Server-driven, fork-based transfer of entire slot ranges. No external orchestrator. Added in Valkey - not present in Redis.

#### Command

```
CLUSTER MIGRATESLOTS SLOTSRANGE <start> <end> [<start> <end> ...] NODE <target-id>
                    [SLOTSRANGE <start> <end> ... NODE <target-id> ...]
```

Multiple ranges to multiple targets in one command. All ranges must currently be owned by the executing node.

#### Flow

1. **Establish**: source connects to target, optionally AUTH, sends `CLUSTER SYNCSLOTS ESTABLISH`.
2. **Snapshot**: source waits for no active child process, then forks. Child writes RDB-format snapshot of migrating slots' keys to the target's socket. Parent keeps serving (COW).
3. **Stream**: writes touching migrating slots stream to the target (replication-style).
4. **Pause**: target requests pause; source drains output and installs `PAUSE_DURING_SLOT_MIGRATION` on writes.
5. **Cutover**: target bumps `configEpoch`, claims ownership; source detects via gossip, unpauses.
6. **Cleanup**: SUCCESS or FAILED; on success the source deletes any remaining keys in transferred slots.

#### State machines

Source (export): `CONNECTING → SEND_AUTH → READ_AUTH_RESPONSE → SEND_ESTABLISH → READ_ESTABLISH_RESPONSE → WAITING_TO_SNAPSHOT → SNAPSHOTTING → STREAMING → WAITING_TO_PAUSE → FAILOVER_PAUSED → FAILOVER_GRANTED → SUCCESS|FAILED`.

Target (import): `WAIT_ACK → RECEIVE_SNAPSHOT → WAITING_FOR_PAUSED → FAILOVER_REQUESTED → FAILOVER_GRANTED → SUCCESS`. Replicas tracking a primary's import sit in `OCCURRING_ON_PRIMARY`.

#### Key functions (all in `cluster_migrateslots.c`)

| Function | Purpose |
|----------|---------|
| `clusterCommandMigrateSlots` | Entry point for `CLUSTER MIGRATESLOTS` |
| `proceedWithSlotMigration` | Drives the export state machine |
| `clusterSlotMigrationCron` | Periodic job maintenance |
| `clusterCommandSyncSlots` | Handles `CLUSTER SYNCSLOTS` subcommands (`ESTABLISH`, `FINISH`, etc.) |
| `clusterCommandCancelSlotMigrations` | `CLUSTER CANCELSLOTMIGRATIONS` |
| `backgroundSlotMigrationDoneHandler` | Child-process completion callback |
| `performSlotImportJobFailover` | Target-side ownership takeover |
| `finishSlotMigrationJob` | Transitions job to SUCCESS/FAILED + cleanup |

#### Gotchas

- **Write-loss window at cutover**: between "source grants failover" and "source sees target's topology update", the source is paused. If the target crashes in this window, the source eventually timeout-unpauses and accepts writes the target won't see. Logged as *"Write loss risk! During slot migration, new owner did not broadcast ownership before we unpaused ourselves."*
- **Failures**: connection loss, ACK timeout (`repl-timeout`), OOM during snapshot, concurrent slot-ownership change, `FLUSHDB`, replica demotion, or user cancel. On failure, both sides auto-clean; operator restarts.
- **Replicas learn about in-progress migrations** via replicated `SYNCSLOTS ESTABLISH`, the `cluster-slot-states` RDB aux field during full sync, and `SYNCSLOTS FINISH` messages.
- **Monitoring**: `CLUSTER GETSLOTMIGRATIONS` (jobs + human-readable state), `CLUSTER CANCELSLOTMIGRATIONS` (cancel all in-progress exports).

#### Why pick atomic over traditional

Traditional blocks the event loop on each `MIGRATE` call (bad for large keys), needs an external resharding tool, causes redirect storms. Atomic is fork-based (non-blocking), handles all DBs in cluster mode, bounded cutover latency.

## CLUSTER SLOT-STATS (`src/cluster_slot_stats.c`)

Valkey-only. Per-slot observability command. Four metrics tracked in `server.cluster->slot_stats[slot]`: `KEY_COUNT`, `CPU_USEC`, `NETWORK_BYTES_IN`, `NETWORK_BYTES_OUT`.

Gate: `cluster-slot-stats-enabled` (bool, default off). `KEY_COUNT` is always available; the other three require the flag (they need in-line accounting on every command). When the flag is off, `CLUSTER SLOT-STATS` only returns `key_count`.

Syntax:

```
CLUSTER SLOT-STATS SLOTSRANGE <start> <end>                          -- range
CLUSTER SLOT-STATS ORDERBY <metric> [LIMIT N] [ASC|DESC]             -- top-K
```

`metric` = `key-count | cpu-usec | network-bytes-in | network-bytes-out`. Accounting hooks live in `cluster_slot_stats.c` (network in/out, CPU) - add one call per metric in any new code path that attributes cost to a slot.

## Sentinel (`src/sentinel.c`)

Monitoring (SDOWN/ODOWN/TILT, PING/INFO/`__sentinel__:hello` discovery) and classic failover (`SENTINEL FAILOVER <name>`, Raft-like leader election, pub/sub events, script hooks) match Redis. Activation: `--sentinel` flag, or binary named `valkey-sentinel` (accepts `redis-sentinel`).

### Coordinated failover

Command: `SENTINEL FAILOVER <name> COORDINATED`. Sets `SRI_COORD_FAILOVER` on the master record.

Instead of sending `REPLICAOF NO ONE` to the replica, Sentinel drives failover through the **primary**:

```
MULTI
CLIENT PAUSE WRITE <ms>
FAILOVER TO <replica-host> <replica-port> TIMEOUT <ms>
EXEC
```

The primary pauses writes, waits for the replica to catch up, swaps roles atomically. Avoids data loss from promoting a still-catching-up replica.

Where to look:

- `sentinelFailoverSendFailover()` (coordinated branch) vs `sentinelFailoverSendReplicaOfNoOne()` (classic) in `src/sentinel.c`.
- `master_failover_state` in the primary's INFO reply - Sentinel checks this before choosing the coordinated path.
- State machine (unchanged): `NONE → WAIT_START → SELECT_REPLICA → SEND_REPLICAOF_NOONE → WAIT_PROMOTION → RECONF_REPLICAS → UPDATE_CONFIG`. Coordinated path branches inside `SEND_REPLICAOF_NOONE`.
