# Sentinel Advanced

Use when tuning Sentinel timing, deploying across DCs, handling NAT, or using coordinated failover.

## Timing knobs

| Scenario | `down-after-milliseconds` | `failover-timeout` | Notes |
|----------|--------------------------|--------------------|-----|
| Low-latency apps | 5000 | 60000 | Faster detection; more false-positive risk |
| Stable networks (default) | 30000 | 180000 | Conservative |
| Cross-region | 30000-60000 | 300000 | Compensate for WAN RTT |
| Dev | 2000 | 10000 | Iteration speed, not for prod |

## Cross-DC Sentinel placement

### 2-2-1 across 3 DCs (quorum 3)

```
DC-A: primary + S1 + S2
DC-B: replica + S3 + S4
DC-C:                    S5 (tiebreaker)
```

DC-C's single Sentinel breaks ties - a DC-A outage still leaves 3 of 5 Sentinels (S3+S4+S5) to authorize failover.

### Sentinels on client boxes (quorum 3)

```
DC-A: primary + S1
DC-B: replica + S2
App hosts: S3, S4, S5 (collocated with clients)
```

Failover reflects client-side reachability - if most clients can still reach the primary, it stays primary.

## Docker / NAT

Port remapping breaks Sentinel's auto-discovery (INFO + hello messages carry container-internal addresses).

- **`--net=host`** is the simplest fix; container shares host netns.
- **Explicit announce-* values** if host networking isn't an option:

  ```
  # Sentinel
  sentinel announce-ip   203.0.113.10
  sentinel announce-port 26379
  # Data node
  replica-announce-ip   203.0.113.10
  replica-announce-port 6379
  ```
- **Kubernetes**: StatefulSet with stable pod DNS, either `announce-ip <pod-ip>` via init script, or `resolve-hostnames yes` + `announce-hostnames`.

## Coordinated failover (Valkey 9.0+)

New command: `SENTINEL FAILOVER <name> COORDINATED`. Instead of sending `REPLICAOF NO ONE` to the replica, Sentinel drives the swap through the **primary**:

```
MULTI
CLIENT PAUSE WRITE <ms>
FAILOVER TO <replica-host> <replica-port> TIMEOUT <ms>
EXEC
```

Primary pauses writes, waits for the replica to catch up, swaps atomically. Near-zero data-loss; preferred for planned maintenance.

| | Standard | Coordinated |
|---|---|---|
| Mechanism | `REPLICAOF NO ONE` to the replica | `FAILOVER TO <replica>` on the primary |
| Write safety | Replica may lag | Primary coordinates catch-up, no lag-at-promotion |
| When primary is | Unreachable or force-stopped | Running and responsive (required) |
| Use | Unplanned failures | Planned maintenance, upgrades |

Requires Valkey 9.0+ on both the Sentinel and the data nodes. Mixed-version falls back to standard. Track via `SUBSCRIBE +switch-master` on the Sentinel.

## Quick operational commands

```
valkey-cli -p 26379 SENTINEL ckquorum mymaster          # will a failover work?
valkey-cli -p 26379 SENTINEL masters
valkey-cli -p 26379 SENTINEL replicas mymaster
valkey-cli -p 26379 SENTINEL sentinels mymaster
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name mymaster
valkey-cli -p 26379 SENTINEL FAILOVER mymaster [COORDINATED]
```

## Systemd notes

`valkey-sentinel` is a symlink to `valkey-server` - your unit file should `ExecStart=/usr/bin/valkey-sentinel /etc/valkey/sentinel.conf --supervised systemd` and `ExecStop=/usr/bin/valkey-cli -p 26379 shutdown`. Generic `Type=notify` + `Restart=always` + `LimitNOFILE=65535`. Nothing Valkey-specific beyond the binary name.
