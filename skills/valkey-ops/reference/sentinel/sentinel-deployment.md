Use when deploying Sentinel for the first time - tested Docker example, step-by-step deployment on bare metal, and configuration directives.

# Sentinel Deployment

## Contents

- Tested Example: Minimal Sentinel Setup (Docker) (line 15)
- Step-by-Step Deployment (line 51)
- Sentinel Configuration Directives (line 161)
- See Also (line 199)

---

## Tested Example: Minimal Sentinel Setup (Docker)

One primary, two replicas, three Sentinels - all on localhost using host networking:

```bash
# Start data nodes
docker run -d --name vk-primary --net=host valkey/valkey:9 \
  valkey-server --port 6379 --requirepass secret --masterauth secret
docker run -d --name vk-replica1 --net=host valkey/valkey:9 \
  valkey-server --port 6380 --replicaof 127.0.0.1 6379 \
  --requirepass secret --masterauth secret
docker run -d --name vk-replica2 --net=host valkey/valkey:9 \
  valkey-server --port 6381 --replicaof 127.0.0.1 6379 \
  --requirepass secret --masterauth secret

# Start 3 Sentinels (each needs a writable config file)
for port in 26379 26380 26381; do
  cat > /tmp/sentinel-${port}.conf <<EOF
port ${port}
sentinel monitor mymaster 127.0.0.1 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel auth-pass mymaster secret
EOF
  docker run -d --name sentinel-${port} --net=host \
    -v /tmp/sentinel-${port}.conf:/etc/sentinel.conf \
    valkey/valkey:9 valkey-sentinel /etc/sentinel.conf
done

# Verify
valkey-cli -p 26379 SENTINEL ckquorum mymaster
# Expected: OK 3 usable Sentinels. Quorum and failover authorization is possible.
```

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
| `sentinel parallel-syncs <name> <n>` | 1 | Replicas reconfigured simultaneously during failover |
| `sentinel auth-pass <name> <password>` | (none) | Password to authenticate to monitored instances |
| `sentinel auth-user <name> <username>` | (none) | ACL username for authentication (used with auth-pass) |
| `sentinel notification-script <name> <path>` | (none) | Script called on WARNING-level events |
| `sentinel client-reconfig-script <name> <path>` | (none) | Script called during failover with role and address info |

Source: `sentinel.c` - `sentinelHandleConfiguration()`, verified defaults at lines 86-98

### Global Directives

| Directive | Default | Description |
|-----------|---------|-------------|
| `sentinel announce-ip <ip>` | (auto-detect) | Override the IP address Sentinel announces |
| `sentinel announce-port <port>` | (auto-detect) | Override the port Sentinel announces |
| `sentinel deny-scripts-reconfig yes` | yes | Block runtime path changes to scripts via SENTINEL SET |
| `sentinel resolve-hostnames no` | no | Enable DNS hostname resolution |
| `sentinel announce-hostnames no` | no | Announce hostnames instead of IPs |
| `sentinel sentinel-user <user>` | (none) | ACL user for inter-Sentinel authentication |
| `sentinel sentinel-pass <pass>` | (none) | Password for inter-Sentinel authentication |

---

## See Also

- [sentinel-advanced](sentinel-advanced.md) - Tuning, cross-DC placement, Docker/NAT, coordinated failover, systemd
- [architecture](architecture.md) - How Sentinel works
- [split-brain](split-brain.md) - Split-brain prevention
