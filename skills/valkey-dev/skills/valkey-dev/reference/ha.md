# High Availability (Cluster + Sentinel)

Topology, failover, slot migration. Base algorithms (16,384-slot hash cluster, gossip, MOVED/ASK, bus port = port+10000, PFAIL -> FAIL quorum, Raft-like leader election for Sentinel, SDOWN/ODOWN/TILT) are unchanged from Redis. Everything below is divergence.

## Cluster shape

- Cluster mode is not limited to DB 0. `getKVStoreIndexForKey()` routes by slot; `selectDb()` works in cluster mode; migrations transfer all DBs.
- `clusterState.shards` maps `shard_id -> list(clusterNode)` for shard-level operations.
- `clusterState.slot_migration_jobs` lives alongside legacy `migrating_slots_to` / `importing_slots_from`. Topology queries must consult both.
- `availability-zone` is a free-form SDS propagated via gossip and surfaced in `CLUSTER SHARDS` / `CLUSTER SLOTS`. Node field: `clusterNode.availability_zone`.
- `cluster-config-save-behavior` (default `sync`) controls when `nodes.conf` is persisted; alternatives trade I/O for recovery precision after crash.

## Cluster bus

- `clusterMsg` vs `clusterMsgLight` have `data` at different byte offsets. Receive-side casts must pick the right type before dereferencing.
- All numeric wire fields are network byte order. New gossip/ext/aux scalars require htons/ntohs before memcpy.
- Ports gossiped: TCP + TLS only. RDMA requires `rdma-port == port` (config contract, unenforced in code). MOVED/ASK/CLUSTER SLOTS return ports based on the originating client's connection type.
- Cluster bus byte counters are per-category (admin gossip / PUBLISH+PUBLISHSHARD / MODULE) and incremented only after validation. Adding a new cluster-bus message type requires a `clusterBusAddNetworkBytesByType` call at send and receive.
- Extension-support tracking lives on `clusterLink`, not `clusterNode`. During handshake the sender-node lookup returns NULL until the node is added, so bit-on-node loses the capability.
- Light-header support is per-peer. 8.0 and 9.0 use the same bit for LIGHT_PUBLISH and LIGHT_HDR_MODULE respectively - any new LIGHT_HDR_* bit must be checked for collision against the 8.x assignment before it ships.
- Module sender_id is fixed 40 bytes: NOT null-terminated pre-8.1, null-terminated from 8.1+. Cross-version module ABI hazard.
- INFO / CLUSTER INFO bus metrics are always populated: `cluster_stats_bytes_{sent,received}` plus per-category splits `cluster_stats_pubsub_bytes_{sent,received}` and `cluster_stats_module_bytes_{sent,received}`, all via `clusterBusAddNetworkBytesByType`.

## Failover

- Coordinated failover (via the `FAILOVER` command, used by Sentinel's coordinated branch) is primary-driven: primary pauses writes, waits for replica catch-up, swaps roles atomically. See `sentinelFailoverSendFailover` (coordinated) vs `sentinelFailoverSendReplicaOfNoOne` (classic) in `src/sentinel.c`.
- `failover_auth_time` must reset to 0 on abort/restart of a replica election. A stale timer leaves the replica stuck waiting for votes.
- Rank-convergence delay (500 ms + random) exists for offset broadcasting, not FAIL-propagation. Shrinking to 0 reproduces split-vote failures. `shouldRepeatReadFromPrimary` must precede `beforeNextClient` to avoid UAF ordering.
- Primary sends full ~4 KB UPDATE back to the replica on failover-auth denial; the replica otherwise cannot recover.
- `CLUSTER REPLICATE NO ONE` vs `REPLICAOF NO ONE` diverge by design. Cluster variant must `emptyData` and move the node into a fresh shard (the detached node remains a cluster member); standalone variant keeps data.
- Slot-bitmap comparisons in auth paths are endian-sensitive. `clusterSendFailoverAuthIfNeeded` tests must include a non-64-bit-aligned slot boundary (e.g. slot 12287); a test using only slots 0-1023 passes on both endians and hides the bug.
- Cluster-aware lazyfree re-inits `slotToKeyInit` after async flush - `slotToKeyFlush` alone is not enough, because `emptyDbAsync` allocates a fresh `db->dict` and `clusterDictMetadata`.
- `clusterSetNodeAsPrimary` + `replicationUnsetPrimary` are paired atomically. Separating them opens a window where `server.cluster->myself->flags` and `server.replication_state` disagree.
- "Multi-primary claiming one slot" assert is not fatal during a legitimate replica-role broadcast - must not abort the process.
- Once in FAIL state, `clusterNodeAddFailureReport` short-circuits and returns 0. `CLUSTER COUNT-FAILURE-REPORTS` decays; tests asserting a growing count after FAIL are flaky by design.
- `cluster-manual-failover-timeout`: 1 to INT_MAX range; `now + timeout*PAUSE_MULT` overflows at large timeouts. Write-pause is capped at `CLUSTER_MF_TIMEOUT = 500 ms` regardless.
- Gossip shard_id propagation: replica adopts primary's shard_id, not the reverse. Opportunistic, eventually consistent.
- Coordinated immediate start: when all replicas in the shard agree the primary is down AND the best-ranked replica has a rank-0 primary, election starts with zero delay.
- `clusterGetFailedPrimaryRank()` contributes to election start delay so concurrent elections across multiple failing shards don't collide.
- `server.cluster_mf_timeout` (config `cluster-manual-failover-timeout`, default 5000 ms) is configurable; in Redis it is a hardcoded constant.

All in `src/cluster_legacy.c`.

## Slot migration

Two mechanisms coexist: traditional `CLUSTER SETSLOT` + per-key `MIGRATE`, and atomic server-driven `CLUSTER MIGRATESLOTS` (new in Valkey, `src/cluster_migrateslots.c`).

- `CLUSTER SETSLOT` replicates via the replication stream before executing, to prevent topology loss on primary crash between execute and gossip. Version-gated on `replica_version > 0x702ff` in `clusterCommandSetSlot`.
- `delKeysInSlot` on the source during slot migration needs a version flag: DEL for pre-9.0 replicas, FLUSHSLOT for 9.0+. Mixed-version clusters otherwise reject the propagated FLUSHSLOT.
- Slot-migration connections use `tls-replication` config, not `tls-cluster`. They connect to the peer's data-plane port, not the cluster-bus port.
- Atomic slot migration child type is `CHILD_TYPE_SLOT_MIGRATION`; mutually exclusive with RDB `bgsave` (like any forked child). `killSlotMigrationChild` is the teardown symmetric to `killRDBChild`.
- Atomic slot migration target persists in-flight import state as an RDB aux/opcode; replicas that full-sync mid-import inherit the state. Module `IMPORT_STARTED` event fires before imported keys load.
- Module-replicated cross-slot commands must abort during atomic slot migration - the target applies against a single slot's staging kvstore, so multi-slot writes corrupt ownership.
- Importing keys are excluded from Fenwick counts and from fair-random-slot selection. `kvstore` exposes `HASHTABLE_ITER_INCLUDE_IMPORTING` as an opt-in iterator flag. `DBSIZE` differs from `COUNTKEYSINSLOT` during migration by design - do not cross-check the two.
- Cutover write-loss window is a known hardening concern, not a correctness guarantee. Between "source grants failover" and "source sees target's ownership gossip", the source is paused; target crash in this window leaves the source eventually timeout-unpaused to accept writes the target won't see. Logged as *"Write loss risk!"*. Extending the pause is almost always the wrong fix - tighten the gossip-learn-loop on the source instead.
- `CLUSTERSCAN` cursor carries a seed fingerprint because primary/replica have independent hash seeds; rerouting a cursor mid-iteration without the fingerprint silently skips or double-visits. `scan.seed` derives deterministically from the `hash-seed` config via SHA-256.

`getNodeByQuery()` in `src/cluster.c` is the single source of truth for redirect decisions.

## Gossip

- 80% sampling of known nodes per ping with HANDSHAKE-state nodes excluded. Strict equality tests are flaky by design - expect +2 for self and link.
- `clusterNodeCleanupFailureReports` runs per PING/PONG with a millisecond-bucketed RAX key `(bucketed_second, clusterNode*)`. CPU scaled from 100% to 32% at 450 concurrent failovers - do not regress the bucketing.
- Stale PING/PONG after primary quiesce is a real hazard. Cross-check `nodeEpoch(sender_claimed_primary) > sender_claimed_config_epoch` before latching a new role.

## SCAN cross-node

- Cluster SCAN is primary-only. Per-node hash seeds mean results are not comparable across primary/replica of the same shard, and RDB dump-then-load does not preserve SCAN order.

## CLUSTER SLOT-STATS

Valkey-only per-slot observability (`src/cluster_slot_stats.c`). Accounting hooks (network in/out, CPU, key count) live in `cluster_slot_stats.c` - add one call per metric in any new code path that attributes cost to a slot. Gated on `cluster-slot-stats-enabled` (default off) for everything except `KEY_COUNT`.

## Sentinel

Monitoring (SDOWN/ODOWN/TILT, PING/INFO/`__sentinel__:hello` discovery) and classic failover match Redis. Activation: `--sentinel` flag, or binary named `valkey-sentinel` (also accepts `redis-sentinel`). Coordinated failover (`SENTINEL FAILOVER <name> COORDINATED`, sets `SRI_COORD_FAILOVER`) is primary-driven and atomic - see the failover invariant above and `sentinelFailoverSendFailover` in `src/sentinel.c`.
