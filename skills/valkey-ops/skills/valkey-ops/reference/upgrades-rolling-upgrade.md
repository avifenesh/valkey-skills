# Rolling Upgrades

Use when doing zero-downtime Valkey upgrades. Redis-style mechanics carry over; this file is the Valkey-specific delta.

## Baseline (same as Redis)

Upgrade replicas first, then promote-and-upgrade each primary. For Sentinel: upgrade non-primary instances, `SENTINEL FAILOVER <name>` to shift ownership, upgrade the old primary, then upgrade the Sentinel processes. For cluster: upgrade all replicas across all shards first, then `CLUSTER FAILOVER` per shard and upgrade the old primary one at a time. Never upgrade more than one primary simultaneously; wait for `master_link_status:up` between steps.

## Valkey 9.0 coordinated failover (`SENTINEL FAILOVER <name> COORDINATED`)

Sentinel 9.0 added a coordinated failover path that drives the swap through the **primary** rather than sending `REPLICAOF NO ONE` to the replica:

```
MULTI
CLIENT PAUSE WRITE <ms>
FAILOVER TO <replica-host> <replica-port> TIMEOUT <ms>
EXEC
```

The primary pauses writes, waits for the replica to catch up, and atomically swaps roles. Result: fewer spurious `-REDIRECT`s at cutover and no risk of promoting a still-catching-up replica. Prefer this over the standard `SENTINEL FAILOVER` for planned upgrades - it's exactly the case it was built for.

Needs `SRI_COORD_FAILOVER` support on the Sentinel side (9.0+) **and** `master_failover_state` reported in INFO by the Valkey instance (also 9.0+). Mixed versions fall back to classic `REPLICAOF NO ONE`.

## Mixed 8.x/9.0 cluster concerns

- **Atomic slot migration is off** until every node is 9.0+. During the upgrade window, any resharding falls back to the legacy key-by-key `MIGRATE`/`ASK` path. Delay planned reshards until the upgrade completes.
- **`CLUSTER SYNCSLOTS CAPA`** gates ASM availability - 9.0+ primaries advertise the capability; replicas and peer primaries gate behavior on the set. Operators don't touch this, but it's what keeps the mixed state safe.
- **Light-weight cluster bus headers** (9.0+) reduce cluster bus traffic on pub/sub-heavy workloads. A duplicate multi-meet packet bug in mixed 8.x/9.0 meshes was fixed in **9.0.1** - if you hit gossip-storm symptoms during the upgrade window, that's the fix.

## Module ASM opt-in

Modules must explicitly declare Atomic Slot Migration support. If any loaded module hasn't opted in, ASM is disabled cluster-wide (not just for that module). Before a 9.0 upgrade, audit every module:

```sh
valkey-cli MODULE LIST
# for each: check the module's release notes or ValkeyModule_* flags for ASM capability
```

Plan a module upgrade before the server upgrade, or accept that the cluster will use legacy migration.

## `replica_version` gate on CLUSTER SETSLOT

`CLUSTER SETSLOT` replicates to eligible replicas before executing (adds topology-change resilience). Replicas must report `replica_version > 0x702ff` (i.e. > 7.2) to be eligible. During a mixed upgrade from Redis OSS 7.2 -> Valkey 8.x+, the replicated-before-executed path is skipped until replicas are on a version that supports it. Falls back cleanly - doesn't block, just loses the consistency guarantee.

## 9.0 production gotchas

- **9.0.0-9.0.1 had hash field expiration bugs** - memory leaks, crashes, occasional data corruption. Also a Lua VM crash after `FUNCTION FLUSH ASYNC + FUNCTION LOAD`, and a crash when aborting a slot migration mid-snapshot. **Use 9.0.3+**.
- **RDB version 80** (`VALKEY080` magic) is only read by 9.0+. A replica on 8.x can't load a snapshot from a 9.0 primary with keys that require RDB 80 features (e.g., hash field TTL). Primary downgrades RDB to version 11 for older replicas automatically (`replicaRdbVersion()` in `src/replication.c`), but keys that can't be represented in RDB 11 fall back to their pre-TTL form. Audit hash field TTL usage before mixing versions.

## Zero-downtime host swap (non-HA)

For a standalone primary without Sentinel or cluster, use replication as the mechanism:

1. Start new instance with `--replicaof <old-primary> 6379` (or `primaryof` - same knob, new name).
2. Wait for `master_link_status:up` + `master_sync_in_progress:0`.
3. `WAIT 1 5000` on the old primary to confirm the new replica has the latest writes.
4. Flip client endpoints (DNS/LB/config).
5. `REPLICAOF NO ONE` on the new instance.
6. `SHUTDOWN NOSAVE` on the old one.

The `WAIT` step is the one you skip at your peril - client endpoint flips without it can leave straggler writes on the abandoned primary.

## Rollback

Downgrades work as long as you haven't crossed an RDB major. Valkey 9.0 writes RDB 80 once a hash-field-TTL key exists; a downgrade to 8.x after that point fails to load. Keep an RDB from just before the upgrade and be prepared to restore rather than downgrade in place.
