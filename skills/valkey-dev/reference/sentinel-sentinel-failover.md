# Sentinel Failover and Configuration

Use when understanding Sentinel leader election, the failover state machine, coordinated failover, Sentinel commands, configuration directives, Pub/Sub events, script hooks, or timing constants.

Source: `src/sentinel.c` (5,441 lines)

Standard Sentinel failover with Raft-like leader election. Valkey-specific addition:

## Coordinated Failover (Valkey 9.0+)

Instead of sending `REPLICAOF NO ONE` to the replica, Sentinel sends `FAILOVER TO <replica> TIMEOUT <ms>` to the primary itself. The primary pauses writes, waits for the replica to catch up, then swaps roles atomically - avoiding data loss from promoting a lagging replica.

Triggered by: `SENTINEL FAILOVER <name> COORDINATED`

Requires the primary to support `FAILOVER` (checked via `master_failover_state` in INFO). The `SRI_COORD_FAILOVER` flag controls the branch in state 3 (SEND_REPLICAOF_NOONE) of the failover state machine.

In state 3, coordinated failover calls `sentinelFailoverSendFailover()` which sends `FAILOVER TO <host> <port> TIMEOUT <ms>` wrapped in MULTI with `CLIENT PAUSE WRITE`. Standard failover calls `sentinelFailoverSendReplicaOfNoOne()` instead.

Failover state machine: NONE -> WAIT_START -> SELECT_REPLICA -> SEND_REPLICAOF_NOONE -> WAIT_PROMOTION -> RECONF_REPLICAS -> UPDATE_CONFIG. Election requires absolute majority (>voters/2) AND >= quorum votes.
