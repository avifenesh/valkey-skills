Use when tuning Sentinel timing, deploying across datacenters, handling Docker/NAT environments, using coordinated failover (Valkey 9.0+), or setting up Sentinel as a systemd service.

# Sentinel Advanced Configuration

## Contents

- Tuning Recommendations (line 14)
- Cross-Datacenter Sentinel Placement (line 25)
- Docker and NAT Considerations (line 49)
- Coordinated Failover (Valkey 9.0+) (line 87)
- Systemd Service Files (line 136)
- See Also (line 157)

---

## Tuning Recommendations

| Scenario | `down-after-milliseconds` | `failover-timeout` | Notes |
|----------|--------------------------|--------------------|----|
| Low-latency apps | 5000 | 60000 | Faster detection, risk of false positives |
| Stable networks | 30000 (default) | 180000 (default) | Conservative, fewer false failovers |
| Cross-region | 30000-60000 | 300000 | Account for higher latency |
| Development | 2000 | 10000 | Quick iteration, not for production |

---

## Cross-Datacenter Sentinel Placement

### Pattern: 2-2-1 Across 3 DCs

```
DC-A: Primary + S1 + S2
DC-B: Replica + S3 + S4
DC-C: S5 (tiebreaker)
```

Quorum=3 ensures no single DC failure triggers unwanted failover. DC-C's sole Sentinel acts as the tiebreaker. If DC-A goes down, S3+S4+S5 (3 of 5) authorize failover to DC-B's replica.

### Pattern: Sentinels in Client Boxes

```
DC-A: Primary + S1
DC-B: Replica + S2
App-Servers: S3, S4, S5 (collocated with clients)
```

Quorum=3. This places Sentinels where clients are, so failover reflects client connectivity. If the primary is reachable by the majority of clients, it stays primary. Documented in the official docs as "Example 3: Sentinel in the client boxes."

---

## Docker and NAT Considerations

Port remapping and NAT break Sentinel auto-discovery because Sentinel learns addresses from INFO output and hello messages - these report the container-internal address, not the host-accessible one.

### Option 1: Host Networking (Recommended)

```bash
docker run -d --name sentinel --net=host \
  valkey/valkey:9 \
  valkey-sentinel /etc/sentinel.conf
```

This avoids all address translation issues. The container shares the host's network stack.

### Option 2: Explicit Address Announcement

If host networking is not possible, configure each Sentinel and Valkey instance to announce its externally-reachable address:

Sentinel config:

```
sentinel announce-ip 203.0.113.10
sentinel announce-port 26379
```

Valkey data node config:

```
replica-announce-ip 203.0.113.10
replica-announce-port 6379
```

### Option 3: Kubernetes

In Kubernetes, use a StatefulSet with stable network identities. Each pod gets a predictable DNS name (`sentinel-0.sentinel-svc.namespace.svc.cluster.local`). Configure `announce-ip` to the pod IP or use `resolve-hostnames` with `announce-hostnames`.

---

## Coordinated Failover (Valkey 9.0+)

For planned maintenance (server upgrades, host migrations), use coordinated failover instead of standard failover. This minimizes data loss by having the primary itself orchestrate the role swap.

```bash
SENTINEL FAILOVER mymaster COORDINATED
```

| Aspect | Standard Failover | Coordinated Failover |
|--------|------------------|---------------------|
| Trigger | `SENTINEL FAILOVER mymaster` | `SENTINEL FAILOVER mymaster COORDINATED` |
| Mechanism | Sends `REPLICAOF NO ONE` to replica | Sends `FAILOVER TO <replica>` to primary |
| Write safety | Replica may lag behind primary | Primary pauses writes, waits for replica to catch up |
| Data loss risk | Small window of unreplicated writes | Near-zero (primary coordinates the handover) |
| Primary state | Must be unreachable or is force-stopped | Must be running and responsive |
| Use case | Unplanned failures, emergencies | Planned maintenance, upgrades |

The primary must support the `FAILOVER` command (Valkey 9.0+).

Source: `sentinel.c` - `SRI_COORD_FAILOVER` flag (line 80), `sentinelFailoverSendFailover()` sends `FAILOVER TO <host> <port> TIMEOUT <ms>` wrapped in MULTI with CLIENT PAUSE WRITE

### Coordinated Failover Procedure

```bash
# 1. Verify Sentinel health
valkey-cli -p 26379 SENTINEL ckquorum mymaster

# 2. Verify primary supports coordinated failover
valkey-cli -p 6379 INFO server | grep valkey_version
# Must be 9.0+

# 3. Execute coordinated failover
valkey-cli -p 26379 SENTINEL FAILOVER mymaster COORDINATED

# 4. Monitor progress
valkey-cli -p 26379 SUBSCRIBE +switch-master

# 5. Verify new topology
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name mymaster
```

---

## Systemd Service Files

### Sentinel Service

Create `/etc/systemd/system/valkey-sentinel.service`:

```ini
[Unit]
Description=Valkey Sentinel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/bin/valkey-sentinel /etc/valkey/sentinel.conf --supervised systemd
ExecStop=/usr/bin/valkey-cli -p 26379 shutdown
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now valkey-sentinel
```

---

## See Also

- [sentinel-deployment](sentinel-deployment.md) - Step-by-step deployment, config directives
- [architecture](architecture.md) - How Sentinel works
- [split-brain](split-brain.md) - Split-brain prevention
