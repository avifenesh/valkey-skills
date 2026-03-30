# Sentinel Deployment Runbook

Use when deploying Sentinel for the first time, configuring Sentinel directives, or planning deployments in Docker/NAT environments.

---

## Step-by-Step Deployment

### Prerequisites

- At least 3 independent hosts (different VMs, ideally different availability zones)
- Valkey installed on all hosts
- Network connectivity on ports 6379 (data) and 26379 (Sentinel) between all nodes
- Writable config file for each Sentinel (Sentinel rewrites its own config to persist state)

### Step 1: Configure and Start the Primary

On the primary host, create `/etc/valkey/valkey.conf`:

```
bind 0.0.0.0
port 6379
requirepass "your-strong-password"
masterauth "your-strong-password"
```

The `masterauth` is needed so that after a failover, the demoted primary can authenticate to the new primary as a replica.

```bash
valkey-server /etc/valkey/valkey.conf
```

### Step 2: Configure and Start Replicas

On each replica host, create `/etc/valkey/valkey.conf`:

```
bind 0.0.0.0
port 6379
requirepass "your-strong-password"
masterauth "your-strong-password"
replicaof 192.168.1.10 6379
```

```bash
valkey-server /etc/valkey/valkey.conf
```

Verify replication:

```bash
valkey-cli -a "your-strong-password" INFO replication
# Should show role:slave, master_link_status:up
```

### Step 3: Configure and Start Sentinels

On each Sentinel host, create `/etc/valkey/sentinel.conf`:

```
port 26379
sentinel monitor mymaster 192.168.1.10 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel auth-pass mymaster your-strong-password
```

Start each Sentinel:

```bash
valkey-sentinel /etc/valkey/sentinel.conf
# or equivalently:
valkey-server /etc/valkey/sentinel.conf --sentinel
```

Important: the config file must be writable. Sentinel persists runtime state (discovered replicas, other Sentinels, current epoch, voted leaders) by rewriting its config file.

### Step 4: Verify the Deployment

```bash
# List monitored primaries
valkey-cli -p 26379 SENTINEL primaries

# List replicas for a primary
valkey-cli -p 26379 SENTINEL replicas mymaster

# List other Sentinels
valkey-cli -p 26379 SENTINEL sentinels mymaster

# Check quorum health
valkey-cli -p 26379 SENTINEL ckquorum mymaster

# Get current primary address (for client configuration)
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name mymaster
```

### Step 5: Test Failover

```bash
# Trigger manual failover
valkey-cli -p 26379 SENTINEL failover mymaster

# Watch for +switch-master event
valkey-cli -p 26379 SUBSCRIBE +switch-master
```

After failover, verify the new topology:

```bash
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name mymaster
valkey-cli -p 26379 SENTINEL replicas mymaster
```

---

## Sentinel Configuration Directives

### Per-Primary Directives

| Directive | Default | Description |
|-----------|---------|-------------|
| `sentinel monitor <name> <ip> <port> <quorum>` | (required) | Monitor a primary; quorum is the number of Sentinels that must agree on failure |
| `sentinel down-after-milliseconds <name> <ms>` | 30000 | Time before marking an instance as SDOWN |
| `sentinel failover-timeout <name> <ms>` | 180000 | Max failover duration; also governs retry interval (2x this value) |
| `sentinel parallel-syncs <name> <n>` | 1 | Replicas reconfigured simultaneously during failover; higher values mean faster reconfiguration but more replication load |
| `sentinel auth-pass <name> <password>` | (none) | Password to authenticate to monitored instances |
| `sentinel auth-user <name> <username>` | (none) | ACL username for authentication (used with auth-pass) |
| `sentinel notification-script <name> <path>` | (none) | Script called on WARNING-level events |
| `sentinel client-reconfig-script <name> <path>` | (none) | Script called during failover with role and address info |

Source: `sentinel.c` - `sentinelHandleConfiguration()`, verified defaults at lines 86-98

### Global Directives

| Directive | Default | Description |
|-----------|---------|-------------|
| `sentinel announce-ip <ip>` | (auto-detect) | Override the IP address Sentinel announces to other Sentinels |
| `sentinel announce-port <port>` | (auto-detect) | Override the port Sentinel announces |
| `sentinel deny-scripts-reconfig yes` | yes | Block runtime path changes to scripts via SENTINEL SET |
| `sentinel resolve-hostnames no` | no | Enable DNS hostname resolution |
| `sentinel announce-hostnames no` | no | Announce hostnames instead of IPs |
| `sentinel sentinel-user <user>` | (none) | ACL user for inter-Sentinel authentication |
| `sentinel sentinel-pass <pass>` | (none) | Password for inter-Sentinel authentication |

### Tuning Recommendations

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

Port remapping and NAT break Sentinel auto-discovery because Sentinel learns addresses from INFO output and hello messages - these report the container-internal address, not the host-accessible one. Each Sentinel announces its own IP:port via hello messages; with NAT/Docker port mapping, announced addresses are wrong.

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

How it differs from standard failover:

| Aspect | Standard Failover | Coordinated Failover |
|--------|------------------|---------------------|
| Trigger | `SENTINEL FAILOVER mymaster` | `SENTINEL FAILOVER mymaster COORDINATED` |
| Mechanism | Sends `REPLICAOF NO ONE` to replica | Sends `FAILOVER TO <replica>` to primary |
| Write safety | Replica may lag behind primary | Primary pauses writes, waits for replica to catch up |
| Data loss risk | Small window of unreplicated writes | Near-zero (primary coordinates the handover) |
| Primary state | Must be unreachable or is force-stopped | Must be running and responsive |
| Use case | Unplanned failures, emergencies | Planned maintenance, upgrades |

The primary must support the `FAILOVER` command (checked via `master_failover_state` in INFO output). This requires Valkey 9.0+ on the primary.

**Client library warning**: Client libraries must fully implement the Sentinel client protocol (not just pub/sub) to handle the fast role change. Clients relying only on pub/sub messages may reconnect to the old (now-demoted) primary and get READONLY errors.

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

- [Sentinel Architecture](architecture.md) - failure detection, quorum, election protocol
- [Split-Brain Prevention](split-brain.md) - network partition strategies
- [Replication Setup](../replication/setup.md) - primary-replica configuration
- [Replication Tuning](../replication/tuning.md) - backlog sizing and Docker/NAT networking for replicas
