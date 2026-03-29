# Cluster Setup

Use when deploying a new Valkey Cluster, configuring cluster parameters, or understanding hash slot mechanics.

---

## Network Requirements

Each cluster node requires two TCP ports, both reachable between all cluster nodes:

| Port | Default | Purpose |
|------|---------|---------|
| Client port | 6379 | Client connections, key migrations (MIGRATE command) |
| Cluster bus port | Client port + 10000 | Node-to-node binary gossip protocol |

The cluster bus port offset is configurable via `cluster-port` (overrides the +10000 default).

Source: `cluster_legacy.h` - `CLUSTER_PORT_INCR = 10000`, `cluster_legacy.c` - `clusterInitLast()` opens listener on `server.cluster_port ? server.cluster_port : port + CLUSTER_PORT_INCR`

### Firewall Rules

All cluster nodes must be able to reach every other node on both ports. The cluster bus uses a full-mesh topology - every node connects to every other node. For N nodes, there are N*(N-1) connections.

```bash
# Example: allow cluster traffic between nodes 192.168.1.10-15
iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 6379 -j ACCEPT
iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 16379 -j ACCEPT
```

---

## Cluster Configuration

### Essential Parameters

```
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 15000
cluster-require-full-coverage yes
cluster-allow-reads-when-down no
cluster-migration-barrier 1
cluster-replica-validity-factor 10
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `cluster-enabled` | no | Enable cluster mode |
| `cluster-config-file` | nodes.conf | Auto-managed file where nodes persist cluster state; do not edit manually |
| `cluster-node-timeout` | 15000 (15s) | Milliseconds before a node is considered PFAIL; also affects PING frequency and failover timing |
| `cluster-require-full-coverage` | yes | Reject writes if any of the 16384 slots are unassigned or served by a FAIL node |
| `cluster-allow-reads-when-down` | no | Serve read commands even when the cluster state is FAIL |
| `cluster-migration-barrier` | 1 | Minimum replicas that must remain with a primary before automatic replica migration |
| `cluster-replica-validity-factor` | 10 | Multiplier for replica eligibility: `node-timeout * factor` is the max data age for failover eligibility; 0 means always eligible |
| `cluster-replica-no-failover` | no | Prevent this replica from participating in automatic failover |
| `cluster-port` | 0 (auto) | Override the cluster bus port; 0 means client port + 10000 |

Source: `config.c` - verified defaults: `cluster_node_timeout` = 15000 (line 3430), `cluster_require_full_coverage` = 1 (line 3264), `cluster_allow_reads_when_down` = 0 (line 3279), `cluster_migration_barrier` = 1 (line 3369), `cluster_replica_validity_factor` = 10 (line 3366)

### Per-Node Configuration

Each node needs its own `valkey.conf`. Only the data-plane settings differ (port, bind address). Cluster settings should be consistent across all nodes.

```
# Node-specific
port 7000
bind 192.168.1.10
dir /var/lib/valkey/7000

# Cluster (same on all nodes)
cluster-enabled yes
cluster-config-file nodes-7000.conf
cluster-node-timeout 15000

# Auth (same on all nodes)
requirepass "cluster-password"
masterauth "cluster-password"
```

The `masterauth` is required so replicas can authenticate to primaries during replication and after failover.

---

## Creating a Cluster

### Minimum Topology

- **Minimum**: 3 primary nodes (one per shard)
- **Recommended**: 6 nodes (3 primaries + 3 replicas) for HA
- **Production**: 6+ nodes across availability zones

### Step 1: Start Nodes

Start each node with cluster mode enabled. Each node needs its own port and working directory:

```bash
# On each host (or different ports on same host for testing)
valkey-server --port 7000 --cluster-enabled yes \
  --cluster-config-file nodes-7000.conf \
  --appendonly yes --dir /var/lib/valkey/7000

valkey-server --port 7001 --cluster-enabled yes \
  --cluster-config-file nodes-7001.conf \
  --appendonly yes --dir /var/lib/valkey/7001

# Repeat for ports 7002-7005
```

At this point, each node is an independent cluster of one. They know nothing about each other.

### Step 2: Create the Cluster

```bash
valkey-cli --cluster create \
  192.168.1.10:7000 192.168.1.11:7001 192.168.1.12:7002 \
  192.168.1.10:7003 192.168.1.11:7004 192.168.1.12:7005 \
  --cluster-replicas 1 \
  -a "cluster-password"
```

The `--cluster-replicas 1` flag tells the tool to assign one replica per primary. The tool will:

1. Send `CLUSTER MEET` to connect all nodes
2. Distribute 16384 slots evenly across the 3 primaries
3. Assign replicas to primaries (balancing across hosts when possible)
4. Wait for the cluster to reach a consistent state

### Step 3: Verify

```bash
# Connect with cluster mode (-c for automatic redirect following)
valkey-cli -c -p 7000 -a "cluster-password"

# Check cluster state
valkey-cli -p 7000 -a "cluster-password" CLUSTER INFO

# View all nodes
valkey-cli -p 7000 -a "cluster-password" CLUSTER NODES

# Automated health check
valkey-cli --cluster check 192.168.1.10:7000 -a "cluster-password"
```

Expected output from `CLUSTER INFO`:

```
cluster_enabled:1
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6
cluster_size:3
```

---

## Hash Slots and Hash Tags

### Slot Assignment

The 16384-slot keyspace is divided among primaries. The slot for a key is:

```
CRC16(key) mod 16384
```

Source: `cluster.c` - `keyHashSlot()` computes `crc16(key, keylen) & 0x3FFF` (0x3FFF = 16383)

With 3 primaries, the default distribution is:

| Primary | Slots | Range |
|---------|-------|-------|
| Node A | 5461 | 0-5460 |
| Node B | 5462 | 5461-10922 |
| Node C | 5461 | 10923-16383 |

### Hash Tags

Multi-key commands (MGET, MSET, transactions, Lua scripts) require all keys to reside in the same slot. Hash tags force co-location by hashing only the content between `{` and `}`:

```
SET user:{123}:profile "Alice"
SET user:{123}:session "abc123"
SET user:{123}:prefs  "dark-mode"
# All three keys hash to the same slot because {123} is the hash tag
```

Rules:

- Only the content between the first `{` and its matching `}` is hashed
- Empty tags `{}` are ignored - the whole key is hashed
- If there is no `}` after `{`, the whole key is hashed

### Client Routing

When a client sends a command to the wrong node, the node responds with a redirect:

| Response | Meaning | Client Action |
|----------|---------|---------------|
| `-MOVED <slot> <ip>:<port>` | Slot permanently owned by another node | Update routing table, retry on target |
| `-ASK <slot> <ip>:<port>` | Slot is being migrated to another node | Send `ASKING` to target, then retry (do NOT update routing table) |
| `-TRYAGAIN` | Multi-key command has keys split across source and target during migration | Retry later |

Use the `-c` flag with `valkey-cli` to enable automatic redirect following.

Source: `cluster.c` - `getNodeByQuery()`, `clusterRedirectClient()`

---

## See Also

- [Cluster Resharding](resharding.md) - moving slots between nodes
- [Cluster Operations](operations.md) - failover, health checks, scalability
- [Cluster Consistency](consistency.md) - write safety and partition behavior
- [Configuration Essentials](../configuration/essentials.md) - cluster config defaults
- [Security TLS](../security/tls.md) - TLS for cluster bus
- [See valkey-dev: cluster/overview](../valkey-dev/reference/cluster/overview.md) - gossip protocol, cluster bus, message types
