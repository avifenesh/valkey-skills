# Sentinel Architecture and Failure Detection

Use when you need to understand how Sentinel provides high availability for non-clustered Valkey - how it monitors instances, detects failures, elects leaders, and promotes replicas.

## Contents

- How Sentinel Works (line 17)
- Quorum and Majority (line 74)
- Failure Detection: SDOWN and ODOWN (line 94)
- Replica Selection Algorithm (line 139)
- Key Timing Constants (line 180)
- Pub/Sub Events (line 206)

---

## How Sentinel Works

Sentinel is a separate process that monitors Valkey primaries, their replicas, and other Sentinels. It provides three capabilities:

1. **Monitoring** - continuously checks whether primaries and replicas are reachable
2. **Notification** - alerts operators and triggers scripts when failures are detected
3. **Automatic failover** - promotes a replica to primary when the current primary fails, and reconfigures other replicas to use the new primary

Sentinel runs as a restricted mode of the Valkey server binary. It can be started with `--sentinel` or via the `valkey-sentinel` symlink. On activation, Sentinel sets port 26379, disables protected-mode, restricts the command set to sentinel-specific commands, and skips AOF/RDB loading.

Source: `server.c` - `checkForSentinelMode()`, `sentinel.c` - `initSentinelConfig()`, `initSentinel()`

### Minimum Deployment

Deploy at least 3 Sentinel instances on independent infrastructure - different VMs, different availability zones. All Sentinels communicate on TCP port 26379.

```
+----------+     +----------+     +----------+
| Sentinel |     | Sentinel |     | Sentinel |
|    S1    |     |    S2    |     |    S3    |
+----------+     +----------+     +----------+
      |                |                |
      v                v                v
+----------+     +----------+     +----------+
|  Primary |---->| Replica  |     | Replica  |
|  (6379)  |     |  (6380)  |     |  (6381)  |
+----------+     +----------+     +----------+
```

**3 Sentinels (quorum=2)** - the minimum viable deployment. Tolerates 1 Sentinel failure. **5 Sentinels (quorum=2 or 3)** - tolerates 2 Sentinel failures. With quorum=2, detection is more sensitive (only 2 agree on SDOWN->ODOWN), but authorization still requires 3 (the majority). With quorum=3, both detection and authorization require 3, reducing false positives. Use 5 for production systems where Valkey is a critical data store. Never use 2 - this is explicitly documented as an anti-pattern (see [Split-Brain Prevention](split-brain.md)).

### Communication Channels

Each Sentinel maintains two async connections per monitored instance:

| Connection | Purpose | Frequency |
|------------|---------|-----------|
| Command (`cc`) | PING, INFO, SENTINEL commands | PING: every 1s (or `down-after-period` if shorter). INFO: every 10s (1s during failover) |
| Pub/Sub (`pc`) | Subscribe to `__sentinel__:hello` | Receives messages every 2s from other Sentinels |

Each primary and replica gets its own dedicated cc+pc connection pair. Connections are reference-counted and shared only between inter-Sentinel links (Sentinels discovered via different primaries but having the same address reuse one link).

Source: `sentinel.c` - `instanceLink` struct, `sentinelReconnectInstance()`, `sentinelSendPeriodicCommands()`

### Discovery

Only primaries are configured manually. Replicas and Sentinels are discovered automatically:

- **Replicas**: Discovered from the primary's INFO output (parsing `slave0:ip=...,port=...` lines)
- **Other Sentinels**: Discovered via hello messages published to `__sentinel__:hello` on monitored primaries

The hello message format: `sentinel_ip,sentinel_port,sentinel_runid,current_epoch,primary_name,primary_ip,primary_port,primary_config_epoch`

Processing in `sentinelProcessHelloMessage()` updates the local view of the cluster and propagates configuration changes (new primary addresses) after failover.

---

## Quorum and Majority

Two authorization levels govern failover:

| Level | What it controls | How it is calculated |
|-------|-----------------|---------------------|
| **Quorum** | Triggers ODOWN (agreement that primary is down) | Configured per primary in `sentinel monitor` directive |
| **Majority** | Authorizes the actual failover | More than half of all known Sentinels (`> voters/2`) |

Both conditions must be met. With 5 Sentinels and quorum=2:

- 2 Sentinels detect failure (triggers ODOWN)
- 3 Sentinels must authorize the failover (majority)

The leader election requires BOTH the majority AND the quorum - whichever is larger. This ensures that even with a low quorum setting, a proper majority is always needed to execute a failover.

Source: `sentinel.c` - `sentinelGetLeader()` checks `> voters/2` AND `>= quorum`

---

## Failure Detection: SDOWN and ODOWN

### SDOWN (Subjective Down)

A single Sentinel's local judgment that an instance is unreachable. Checked by `sentinelCheckSubjectivelyDown()` for every monitored instance (primaries, replicas, other Sentinels).

An instance is marked SDOWN when:

1. No valid PING reply for `down-after-milliseconds` (default 30000ms), OR
2. A primary reports `role:slave` for longer than `down-after-milliseconds + 2 * INFO_PERIOD`, OR
3. A primary reboot is detected and exceeds `primary_reboot_down_after_period`

Valid PING responses are `+PONG`, `-LOADING`, or `-MASTERDOWN`. Any other response (or no response) counts as a failure.

Events: `+sdown` when set, `-sdown` when cleared.

Source: `sentinel.c` line ~4430+ - `sentinelCheckSubjectivelyDown()`

### ODOWN (Objective Down)

Consensus among multiple Sentinels that a primary is unreachable. Checked by `sentinelCheckObjectivelyDown()` - runs only for primaries.

The process:

1. This Sentinel must consider the primary SDOWN (counts as 1 vote)
2. Other Sentinels that replied `SRI_PRIMARY_DOWN` to `SENTINEL IS-PRIMARY-DOWN-BY-ADDR` are counted
3. If total votes >= configured `quorum`, the primary is marked ODOWN

ODOWN is a "weak quorum" - it means enough Sentinels reported the instance unreachable within a time range, but there is no strong guarantee they all agree at the same instant.

Events: `+odown` when set (includes vote count), `-odown` when cleared.

### TILT Mode

If the time delta between two timer invocations is negative or exceeds 2 seconds, Sentinel enters TILT mode. This handles clock jumps or process freezes. During TILT (lasting 30 seconds):

- Monitoring continues (data collection, reconnection)
- Acting is suspended (no SDOWN/ODOWN transitions, no failovers)

Events: `+tilt` on entry, `-tilt` on exit.

Source: `sentinel.c` - `sentinel_tilt_trigger = 2000` (static variable), `sentinel_tilt_period = 30000`

---

## Replica Selection Algorithm

When failover proceeds, `sentinelSelectReplica()` chooses the best replica to promote.

### Filter (disqualify)

| Condition | Rationale |
|-----------|-----------|
| SDOWN, ODOWN, or disconnected | Unreachable replica cannot be promoted |
| Last PING reply older than 5 * PING_PERIOD | Stale connection |
| INFO data older than 3 * INFO_PERIOD | Cannot verify replica state |
| Replication link down too long | Proportional to primary's SDOWN duration |
| `replica-priority = 0` | Explicitly excluded from promotion |

### Sort (best first)

| Priority | Criterion | Direction |
|----------|-----------|-----------|
| 1 | `replica-priority` | Lower is better |
| 2 | Replication offset | Higher is better (more data synced) |
| 3 | Run ID | Lexicographically smaller (tiebreaker) |

The first replica after sorting is selected. A NULL `runid` is treated as larger than any value (old instances that do not publish their run ID are deprioritized).

Source: `sentinel.c` - `sentinelSelectReplica()`, `compareReplicasForPromotion()`

### Leader Election

When a primary enters ODOWN, Sentinels compete to become the failover leader using a Raft-like single-vote-per-epoch protocol:

1. A Sentinel increments `current_epoch` and broadcasts `SENTINEL IS-PRIMARY-DOWN-BY-ADDR` with its own `myid`
2. Each Sentinel votes at most once per epoch (first-come-first-served)
3. The winner must receive both an absolute majority (`> voters/2`) and at least `quorum` votes
4. If no winner, the attempt is aborted after `election_timeout` (min of 10s and `failover_timeout`)

The timer's `hz` is randomized (jitter) to prevent Sentinels started simultaneously from staying synchronized and splitting votes indefinitely.

Source: `sentinel.c` - `sentinelVoteLeader()`, `sentinelGetLeader()`

---

## Key Timing Constants

| Constant | Default | Purpose |
|----------|---------|---------|
| `SENTINEL_PING_PERIOD` | 1000ms | Base PING interval |
| `sentinel_info_period` | 10000ms | INFO poll (drops to 1000ms during failover) |
| `sentinel_publish_period` | 2000ms | Hello message interval |
| `sentinel_default_down_after` | 30000ms | SDOWN threshold |
| `sentinel_election_timeout` | 10000ms | Max election wait |
| `sentinel_default_failover_timeout` | 180000ms | Max failover duration |
| `sentinel_tilt_period` | 30000ms | TILT mode duration |
| `sentinel_replica_reconf_timeout` | 10000ms | Per-replica reconfig timeout |
| Failover cooldown | 2 * failover_timeout | Min interval between failover attempts for same primary |

### Failover Timing

Typical end-to-end failover time is `down-after-milliseconds + 1-2 seconds` for Sentinel coordination. The 1-2 second overhead includes SDOWN->ODOWN gossip convergence, leader election (one round), and the `REPLICAOF NO ONE` + promotion detection.

| `down-after-milliseconds` | Approximate total failover time |
|---------------------------|-------------------------------|
| 5000 (low-latency prod) | ~6-7 seconds |
| 30000 (default) | ~31-32 seconds |
| 60000 (cross-DC) | ~61-62 seconds |

---

## Pub/Sub Events

Clients subscribe to Sentinel's Pub/Sub channels for real-time notifications. The most important event for client libraries:

```
+switch-master <name> <old-ip> <old-port> <new-ip> <new-port>
```

Other key events: `+sdown`/`-sdown`, `+odown`/`-odown`, `+tilt`/`-tilt`, `+failover-end`, `-failover-abort-not-elected`, `-failover-abort-no-good-slave`.

---
