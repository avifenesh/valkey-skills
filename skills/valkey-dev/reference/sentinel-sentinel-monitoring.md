# Sentinel Monitoring and Failure Detection

Use when understanding how Sentinel activates, discovers instances, monitors
health via PING/INFO/hello messages, and detects failures (SDOWN/ODOWN/TILT).

Source: `src/sentinel.c` (5,441 lines)

## Contents

- Activation (line 20)
- Core Data Structures (line 43)
- Main Timer Loop (line 75)
- Monitoring (line 111)
- Failure Detection (line 145)
- TILT Mode (line 186)

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

## TILT Mode

If the time delta between two timer invocations is negative or exceeds 2 seconds
(`SENTINEL_TILT_TRIGGER`), Sentinel enters TILT mode. This handles clock jumps or
process freezes. During TILT (lasting `SENTINEL_TILT_PERIOD` = 30s):

- Monitoring continues (data collection, reconnection)
- Acting is suspended (no SDOWN/ODOWN transitions, no failovers)

Events: `+tilt` on entry, `-tilt` on exit.

---

## See Also

- [sentinel-failover](sentinel-failover.md) - leader election, failover state machine, commands, configuration
