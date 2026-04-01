# Sentinel Mode

Use when understanding Valkey's high-availability subsystem - how Sentinel monitors
instances, detects failures, elects leaders, and executes failovers.

Source: `src/sentinel.c` (5,441 lines)

## Contents

- Activation (line 27)
- Core Data Structures (line 50)
- Main Timer Loop (line 82)
- Monitoring (line 118)
- Failure Detection (line 152)
- Leader Election (line 194)
- Failover State Machine (line 229)
- Coordinated Failover (line 300)
- Sentinel Commands (line 309)
- Configuration Directives (line 328)
- Pub/Sub Event Channels (line 340)
- Script Execution (line 367)
- Key Timing Constants (line 379)
- See Also (line 395)

---

## Activation

Sentinel mode is activated in one of two ways, checked at startup by
`checkForSentinelMode()` in `server.c`:

1. The `--sentinel` flag: `./valkey-server /etc/sentinel.conf --sentinel`
2. The binary name contains `valkey-sentinel` or `redis-sentinel` (symlink convention)

When active, `server.sentinel_mode` is set to 1 before `initServerConfig()`. The
startup sequence then calls:

```
initSentinelConfig()   -- sets port to 26379, disables protected-mode
initSentinel()         -- zeros out sentinelState, creates primaries dict
loadSentinelConfigFromQueue() -- parses sentinel directives from config file
sentinelCheckConfigFile()     -- exits if no writable config file (Sentinel rewrites it)
sentinelIsRunning()    -- generates myid if absent, emits +monitor events
```

Sentinel mode restricts the command set. Only commands flagged `CMD_SENTINEL` are
loaded. Modules are not loaded. AOF/RDB loading is skipped. The INFO command is
redirected to `sentinelInfoCommand()`.

## Core Data Structures

### sentinelState (global singleton)

Key fields: `myid` (persistent 40-char hex ID), `current_epoch` (Raft-like monotonic
counter), `primaries` (dict of name -> sentinelValkeyInstance), `tilt` (safety mode
flag), `scripts_queue`, `announce_ip`/`announce_port` (override gossiped address),
`sentinel_auth_pass`/`sentinel_auth_user` (inter-sentinel auth),
`resolve_hostnames`/`announce_hostnames` (DNS support).

### sentinelValkeyInstance

Represents any monitored entity - primary, replica, or another Sentinel. The `flags`
bitmask (`SRI_*` constants) determines type and state. Key fields by category:

- **Identity**: `flags`, `name`, `runid`, `config_epoch`, `addr`, `link`
- **Failure detection**: `s_down_since_time`, `o_down_since_time`, `down_after_period`
- **Primary-specific**: `sentinels` dict, `replicas` dict, `quorum`, `parallel_syncs`
- **Replica-specific**: `primary_link_down_time`, `replica_priority`, `replica_repl_offset`, `primary` pointer
- **Failover**: `leader` (elected leader runid), `leader_epoch`, `failover_epoch`, `failover_state`, `failover_start_time`, `failover_timeout`, `promoted_replica`
- **Scripts**: `notification_script`, `client_reconfig_script`

### instanceLink

Each instance has a link with two async libvalkey connections: `cc` (commands - PING,
INFO, SENTINEL) and `pc` (Pub/Sub - subscribes to `__sentinel__:hello`). Links are
reference-counted and shared among Sentinel instances monitoring the same primaries.
5 Sentinels monitoring 100 primaries create 5 outgoing connections, not 500.

Key timing fields: `act_ping_time` (when unanswered ping was sent, 0 if answered),
`last_avail_time` (last valid reply), `last_pong_time` (last reply of any kind).

## Main Timer Loop

`sentinelTimer()` runs from the server event loop at ~10 Hz (with jitter):

```c
void sentinelTimer(void) {
    sentinelCheckTiltCondition();
    sentinelHandleDictOfValkeyInstances(sentinel.primaries);
    sentinelRunPendingScripts();
    sentinelCollectTerminatedScripts();
    sentinelKillTimedoutScripts();
    server.hz = CONFIG_DEFAULT_HZ + rand() % CONFIG_DEFAULT_HZ;  /* desync jitter */
}
```

The `hz` randomization is deliberate - it prevents Sentinels started at the same time
from staying synchronized and splitting votes indefinitely.

### Per-Instance Processing

`sentinelHandleValkeyInstance()` runs for every known instance (primaries, their
replicas, their sentinels) via recursive `sentinelHandleDictOfValkeyInstances()`:

```
MONITORING HALF (all instance types):
  sentinelReconnectInstance()       -- establish cc/pc if disconnected
  sentinelSendPeriodicCommands()    -- INFO, PING, PUBLISH hello

ACTING HALF (skipped during TILT):
  sentinelCheckSubjectivelyDown()   -- all instance types
  sentinelCheckObjectivelyDown()    -- primaries only
  sentinelStartFailoverIfNeeded()   -- primaries only
  sentinelFailoverStateMachine()    -- primaries only
  sentinelAskPrimaryStateToOtherSentinels()  -- primaries only
```

## Monitoring

### Periodic Commands

`sentinelSendPeriodicCommands()` sends: **INFO** to primaries every 10s; to replicas
every 10s (1s when their primary is in ODOWN/failover or the replication link is down)
for replica discovery and role change detection. **PING** to
all instances every min(down_after_period, 1s) for liveness. **PUBLISH** to the
`__sentinel__:hello` channel every 2s to announce self and current config.

### Hello Message Protocol

Sentinels discover each other via the `__sentinel__:hello` Pub/Sub channel on
monitored primaries and replicas. The message format:

```
sentinel_ip,sentinel_port,sentinel_runid,current_epoch,
primary_name,primary_ip,primary_port,primary_config_epoch
```

Processing in `sentinelProcessHelloMessage()`:
1. Look up the primary by name; ignore if unknown
2. Find or create the sentinel instance (by address + runid)
3. Handle address changes (remove old, add with new address)
4. Update local `current_epoch` if the received epoch is higher
5. If the received `primary_config_epoch` is higher, adopt the new primary address
   (this is how configuration propagates after failover)

### Instance Discovery

Replicas are discovered automatically from the primary's INFO output (parsing
`slave0:ip=...,port=...` lines). Sentinels are discovered via hello messages.
Only primaries are configured manually.

## Failure Detection

### SDOWN (Subjective Down)

`sentinelCheckSubjectivelyDown()` - runs for every instance type. An instance is
marked SDOWN when:

1. No valid PING reply for `down_after_period` milliseconds (default 30s), OR
2. A primary reports `role:slave` for longer than `down_after_period + 2*INFO_PERIOD`, OR
3. A primary-reboot is detected and exceeds `primary_reboot_down_after_period`

The function also forces reconnection when a pending PING exceeds half the
`down_after_period` or the Pub/Sub channel is idle for `3 * PUBLISH_PERIOD`.

Events: `+sdown` when set, `-sdown` when cleared.

### ODOWN (Objective Down)

`sentinelCheckObjectivelyDown()` - runs only for primaries. Requires agreement from
multiple Sentinels:

1. This Sentinel must consider the primary SDOWN (counts as 1 vote)
2. Other Sentinels that replied `SRI_PRIMARY_DOWN` to `SENTINEL IS-PRIMARY-DOWN-BY-ADDR`
   are counted
3. If total votes >= configured `quorum`, the primary is marked ODOWN

ODOWN is a "weak quorum" - it means enough Sentinels reported the instance unreachable
within a time range, but there is no strong guarantee they all agree simultaneously.

Events: `+odown` when set (includes vote count), `-odown` when cleared.

### TILT Mode

If the time delta between two timer invocations is negative or exceeds 2 seconds
(`SENTINEL_TILT_TRIGGER`), Sentinel enters TILT mode. This handles clock jumps or
process freezes. During TILT (lasting `SENTINEL_TILT_PERIOD` = 30s):

- Monitoring continues (data collection, reconnection)
- Acting is suspended (no SDOWN/ODOWN transitions, no failovers)

Events: `+tilt` on entry, `-tilt` on exit.

## Leader Election

When a primary enters ODOWN, Sentinels compete to become the failover leader using
a Raft-like voting protocol.

### Vote Request

`sentinelAskPrimaryStateToOtherSentinels()` sends `SENTINEL IS-PRIMARY-DOWN-BY-ADDR`
to other Sentinels. When `failover_state > NONE`, it includes the requesting Sentinel's
own `myid` (requesting a vote); otherwise it sends `*` (just asking about down state).

### Voting

`sentinelVoteLeader()` implements the single-vote-per-epoch rule:

1. If the request epoch is higher than `current_epoch`, adopt it
2. If this Sentinel hasn't voted in this epoch yet (`leader_epoch < req_epoch`),
   vote for the requester and persist the config
3. If voting for another Sentinel (not self), add a random delay to
   `failover_start_time` to reduce split-brain contention

### Counting Votes

`sentinelGetLeader()` determines the election winner:

1. Tally votes from all known Sentinels for the current epoch
2. This Sentinel casts its own vote (for the front-runner, or for itself if no votes)
3. Winner must achieve BOTH:
   - Absolute majority: `> voters/2` (where voters = all known Sentinels + 1)
   - At least `quorum` votes

If no winner, `sentinelFailoverWaitStart()` waits up to `election_timeout` (min of
10s and `failover_timeout`), then aborts the failover attempt with
`-failover-abort-not-elected`.

## Failover State Machine

`sentinelFailoverStateMachine()` advances through these states:

### State 0: NONE
No failover in progress.

### State 1: WAIT_START
Set by `sentinelStartFailover()`. Increments `current_epoch`, sets
`SRI_FAILOVER_IN_PROGRESS`. Waits for leader election result.

Handler: `sentinelFailoverWaitStart()` - checks if this Sentinel won the election.
If not leader and not `SRI_FORCE_FAILOVER`, waits or aborts on timeout.

### State 2: SELECT_REPLICA
Handler: `sentinelFailoverSelectReplica()` - calls `sentinelSelectReplica()`.

Replica selection criteria (filtering, then sorting):

**Filter out replicas that are:**
- SDOWN, ODOWN, or disconnected
- Last PING reply older than 5 * PING_PERIOD
- INFO data older than 3 * INFO_PERIOD (or 5 * PING_PERIOD during SDOWN)
- Replication link down too long (proportional to primary's SDOWN duration)
- Priority = 0 (explicitly excluded from promotion)

**Sort remaining by (best first):**
1. Lower `replica_priority`
2. Higher `replica_repl_offset` (more data processed)
3. Lexicographically smaller `runid` (tiebreaker)

### State 3: SEND_REPLICAOF_NOONE
Two paths depending on failover type:

**Standard failover** (`sentinelFailoverSendReplicaOfNoOne()`):
Sends `REPLICAOF NO ONE` to the selected replica via a MULTI/EXEC transaction that
also includes FAILOVER ABORT (if stuck), CONFIG REWRITE, and CLIENT KILL.

**Coordinated failover** (`sentinelFailoverSendFailover()`):
Sends `FAILOVER TO <host> <port> TIMEOUT <ms>` to the *primary* (not the replica),
wrapped in MULTI with CLIENT PAUSE WRITE. The primary itself orchestrates the role
swap. This path is triggered by `SENTINEL FAILOVER <name> COORDINATED`.

### State 4: WAIT_PROMOTION
Handler: `sentinelFailoverWaitPromotion()` - waits for the promoted replica to report
`role:master` in its INFO output. Detection happens in `sentinelRefreshInstanceInfo()`
which advances to state 5 when it sees the role change.

On promotion detection, `config_epoch` is set to the `failover_epoch`, and for
coordinated failovers, CLIENT KILL is sent to both the old primary and new primary.

### State 5: RECONF_REPLICAS
Handler: `sentinelFailoverReconfNextReplica()` - sends `REPLICAOF <new-primary>` to
remaining replicas, respecting `parallel_syncs` to limit concurrent resyncs.

Tracks replica reconfiguration through sub-states:
- `SRI_RECONF_SENT` - REPLICAOF command sent
- `SRI_RECONF_INPROG` - replica reports correct primary host (detected via INFO)
- `SRI_RECONF_DONE` - replica link to new primary is UP

Times out individual replicas after `sentinel_replica_reconf_timeout` (10s). When all
replicas are done (or on overall `failover_timeout`), moves to state 6.

### State 6: UPDATE_CONFIG
Handler: `sentinelFailoverSwitchToPromotedReplica()` - emits the `+switch-master`
event and calls `sentinelResetPrimaryAndChangeAddress()` which:
1. Saves all current replica addresses
2. Resets the primary instance
3. Changes the primary's address to the promoted replica's address
4. Re-adds old replicas (including the old primary as a new replica)

## Coordinated Failover

Valkey 9.0+ addition. Instead of sending `REPLICAOF NO ONE` to the replica, Sentinel
sends `FAILOVER TO <replica> TIMEOUT <ms>` to the primary itself, which pauses writes,
waits for the replica to catch up, then swaps roles atomically. Avoids data loss from
promotion of lagging replicas. Triggered by `SENTINEL FAILOVER <name> COORDINATED`.
Requires the primary to support `FAILOVER` (checked via `master_failover_state` in
INFO). The `SRI_COORD_FAILOVER` flag controls the state 3 branch in the state machine.

## Sentinel Commands

Implemented in `sentinelCommand()`. Key subcommands:

**Query**: `PRIMARIES`, `PRIMARY <name>`, `REPLICAS <name>`, `SENTINELS <name>`,
`MYID`, `GET-PRIMARY-ADDR-BY-NAME <name>`, `CKQUORUM <name>`, `INFO-CACHE <name>`

**Mutate**: `MONITOR <name> <ip> <port> <quorum>`, `REMOVE <name>`,
`SET <name> <option> <value>`, `FAILOVER <name> [COORDINATED]`, `FLUSHCONFIG`,
`RESET <pattern>`, `CONFIG SET/GET`

**Internal**: `IS-PRIMARY-DOWN-BY-ADDR <ip> <port> <epoch> <runid>` (inter-sentinel
voting protocol)

**Debug**: `SIMULATE-FAILURE [CRASH-AFTER-ELECTION|CRASH-AFTER-PROMOTION]`, `DEBUG`

Legacy aliases: `MASTERS`/`MASTER`/`SLAVES`/`IS-MASTER-DOWN-BY-ADDR`/
`GET-MASTER-ADDR-BY-NAME`.

## Configuration Directives

Parsed by `sentinelHandleConfiguration()`. Per-primary directives: `monitor`,
`down-after-milliseconds` (30s), `failover-timeout` (180s), `parallel-syncs` (1),
`notification-script`, `client-reconfig-script`, `auth-pass`, `auth-user`.
Global directives: `current-epoch`, `myid`, `deny-scripts-reconfig`,
`resolve-hostnames`, `announce-hostnames`, `announce-ip`, `announce-port`,
`sentinel-user`, `sentinel-pass`.

Sentinel rewrites its own config file to persist state (current epoch, known replicas,
known sentinels, voted leaders). A writable config file is mandatory.

## Pub/Sub Event Channels

Events are published via `sentinelEvent()` to channels named after the event type.
Clients subscribe to these channels on the Sentinel instance for notifications.

**Failover lifecycle**: `+try-failover`, `+elected-leader`,
`+failover-state-select-slave`, `+selected-slave`,
`+failover-state-send-slaveof-noone`, `+failover-state-wait-promotion`,
`+promoted-slave`, `+failover-state-reconf-slaves`, `+failover-end`,
`+failover-end-for-timeout`, `-failover-abort-not-elected`,
`-failover-abort-no-good-slave`

**Primary address change** (most important for clients):
`+switch-master` - format: `<name> <old-ip> <old-port> <new-ip> <new-port>`

**Instance state**: `+sdown`/`-sdown`, `+odown`/`-odown`, `+tilt`/`-tilt`,
`+reboot`, `+role-change`/`-role-change`

**Discovery**: `+monitor`/`-monitor`, `+slave`, `+sentinel`,
`+sentinel-address-switch`

**Reconfiguration**: `+slave-reconf-sent`, `+slave-reconf-inprog`,
`+slave-reconf-done`, `+config-update-from`, `+convert-to-slave`,
`+fix-slave-config`, `+new-epoch`

Only events at `LL_WARNING` level trigger notification scripts.

## Script Execution

Two hooks per monitored primary. `notification-script` fires on every `LL_WARNING`
event with args `<event-type> <description>`. `client-reconfig-script` fires during
failover with args `<name> <role> <state> <from-ip> <from-port> <to-ip> <to-port>`
where role is `leader` or `observer`.

Scripts run as forked children (`execve`), max 16 concurrent, queue limit 256. Killed
after 60s. Exit code 1 or signal triggers retry (up to 10x, delay doubles: 30s, 60s,
2m...). Exit code 2+ means no retry. `deny-scripts-reconfig` (default yes) blocks
runtime path changes via `SENTINEL SET`.

## Key Timing Constants

All in milliseconds: `SENTINEL_PING_PERIOD` 1000 (base PING), `sentinel_info_period`
10000 (INFO poll, drops to 1000 during failover), `sentinel_publish_period` 2000
(hello), `sentinel_ask_period` 1000 (min IS-PRIMARY-DOWN-BY-ADDR interval),
`sentinel_default_down_after` 30000 (SDOWN threshold), `sentinel_election_timeout`
10000, `sentinel_default_failover_timeout` 180000, `sentinel_tilt_trigger` 2000,
`sentinel_tilt_period` 30000, `sentinel_replica_reconf_timeout` 10000,
`sentinel_min_link_reconnect_period` 15000, `sentinel_script_max_runtime` 60000,
`SENTINEL_MAX_DESYNC` 1000 (random jitter added to failover start).

The failover cooldown is `2 * failover_timeout` - no new attempt for the same primary
within this window.

---
