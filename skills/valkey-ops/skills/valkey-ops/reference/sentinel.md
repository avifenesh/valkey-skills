# Sentinel

Use when deploying or operating Sentinel for non-clustered Valkey HA - config, timing, cross-DC placement, NAT, coordinated failover, split-brain.

Standard Redis Sentinel model applies: SDOWN/ODOWN, quorum/majority, single-vote-per-epoch, TILT mode, replica selection. Below is the Valkey-specific layer.

## Valkey-specific names

- Binary: `valkey-sentinel` (symlink to `valkey-server`) or `valkey-server ... --sentinel`
- Config path: `/etc/valkey/sentinel.conf`
- Default port: `26379` (same as Redis)
- Replica parameter: `replica-priority` (not `slave-priority`). Set `replica-priority 0` to exclude a node from promotion.
- Sentinel sets `server.protected_mode = 0` on activation (`sentinel.c`).

## Deployment config

```
port 26379
sentinel monitor mymaster 192.168.1.10 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel auth-pass mymaster your-strong-password
sentinel auth-user mymaster sentinel-acl-user   # for ACL auth
```

Deploy at least 3 Sentinels on independent infrastructure. **Never 2** - cannot achieve majority after 1 failure.

## Timing knobs

| Scenario | `down-after-milliseconds` | `failover-timeout` | Notes |
|----------|--------------------------|--------------------|-----|
| Low-latency apps | 5000 | 60000 | Faster detection; more false-positive risk |
| Stable networks (default) | 30000 | 180000 | Conservative |
| Cross-region | 30000-60000 | 300000 | Compensate for WAN RTT |
| Dev | 2000 | 10000 | Iteration, not production |

Source defaults: `down-after-milliseconds=30000`, `failover-timeout=180000`, `parallel-syncs=1`.

## Cross-DC placement

### 2-2-1 across 3 DCs (quorum 3)

```
DC-A: primary + S1 + S2
DC-B: replica + S3 + S4
DC-C:                    S5 (tiebreaker)
```

A DC-A outage still leaves 3 of 5 Sentinels (S3+S4+S5) to authorize failover.

### Sentinels on client boxes (quorum 3)

```
DC-A: primary + S1
DC-B: replica + S2
App hosts: S3, S4, S5 (collocated with clients)
```

Failover reflects client-side reachability - if most clients can still reach the primary, it stays primary.

## Docker / NAT

Port remapping breaks Sentinel auto-discovery (INFO + hello messages carry container-internal addresses).

- `--net=host` is the simplest fix.
- Explicit announce values if host networking isn't an option:
  ```
  # Sentinel
  sentinel announce-ip   203.0.113.10
  sentinel announce-port 26379
  # Data node
  replica-announce-ip   203.0.113.10
  replica-announce-port 6379
  ```
- **Kubernetes**: StatefulSet with stable pod DNS. Either `announce-ip <pod-ip>` via init script, or `resolve-hostnames yes` + `announce-hostnames`.

## Coordinated failover (Valkey 9.0+)

`SENTINEL FAILOVER <name> COORDINATED` drives the swap through the **primary** instead of `REPLICAOF NO ONE` on the replica:

```
MULTI
CLIENT PAUSE WRITE <ms>
FAILOVER TO <replica-host> <replica-port> TIMEOUT <ms>
EXEC
```

Primary pauses writes, waits for replica catch-up, swaps atomically. Near-zero data-loss; preferred for planned maintenance.

| | Standard | Coordinated |
|---|---|---|
| Mechanism | `REPLICAOF NO ONE` to replica | `FAILOVER TO <replica>` on primary |
| Write safety | Replica may lag | Primary coordinates catch-up, no lag-at-promotion |
| When primary is | Unreachable or force-stopped | Running and responsive (required) |
| Use | Unplanned failures | Planned maintenance, upgrades |

Requires Valkey 9.0+ on Sentinel and data nodes. Mixed-version falls back to standard. Track via `SUBSCRIBE +switch-master` on Sentinel.

## Write safety

```
min-replicas-to-write 1
min-replicas-max-lag 10
```

Primary returns `-NOREPLICAS` when fewer than `min-replicas-to-write` replicas have acknowledged within `min-replicas-max-lag` seconds. Bounds the data-loss window.

For critical individual writes, use `WAIT <numreplicas> <timeout>` to block on replication acknowledgement per-command.

## Operational commands

```sh
valkey-cli -p 26379 SENTINEL ckquorum mymaster          # will a failover work?
valkey-cli -p 26379 SENTINEL primaries                   # renamed from "masters"
valkey-cli -p 26379 SENTINEL replicas mymaster
valkey-cli -p 26379 SENTINEL sentinels mymaster          # should show odd >= 3
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name mymaster
valkey-cli -p 26379 SENTINEL FAILOVER mymaster [COORDINATED]
valkey-cli INFO replication                              # check replica lag
```

`SENTINEL masters` / `get-master-addr-by-name` still work as aliases.

## Sentinel ACL user

`FAILOVER` and `CLUSTER FAILOVER` use the standard `@admin`/`@dangerous`/`@slow` categories - no special permission beyond what any admin command needs. See `security.md` for the minimal per-command grant list.

## Systemd

`valkey-sentinel` is a symlink to `valkey-server`:

```ini
ExecStart=/usr/bin/valkey-sentinel /etc/valkey/sentinel.conf --supervised systemd
ExecStop=/usr/bin/valkey-cli -p 26379 shutdown
```

Generic `Type=notify` + `Restart=always` + `LimitNOFILE=65535`. Nothing Valkey-specific beyond the binary name.

## Client integration

Use Sentinel-aware client libraries that `SUBSCRIBE +switch-master` for automatic failover-aware connection routing.
