# Valkey Operations Guide for Self-Hosted Deployments

> Operational runbook for deploying, managing, and troubleshooting self-hosted Valkey.
> Covers versions 8.x and 9.x. Last updated: 2026-03-29.

---

## Table of Contents

1. [Installation and Deployment](#1-installation-and-deployment)
2. [Configuration Deep Dive](#2-configuration-deep-dive)
3. [High Availability with Sentinel](#3-high-availability-with-sentinel)
4. [Cluster Mode](#4-cluster-mode)
5. [Persistence](#5-persistence)
6. [Replication](#6-replication)
7. [Security](#7-security)
8. [Monitoring](#8-monitoring)
9. [Performance Tuning](#9-performance-tuning)
10. [Troubleshooting](#10-troubleshooting)
11. [Upgrades and Maintenance](#11-upgrades-and-maintenance)
12. [Kubernetes Deployment](#12-kubernetes-deployment)

---

## 1. Installation and Deployment

### 1.1 Package Managers

| OS | Command |
|----|---------|
| Debian/Ubuntu | `sudo apt install valkey` |
| RHEL/CentOS | `sudo yum install valkey` |
| Fedora | `sudo dnf install valkey` |
| Arch Linux | `sudo pacman -Sy valkey` |
| Alpine | `sudo apk add valkey` |
| macOS (Homebrew) | `brew install valkey` |
| macOS (MacPorts) | `sudo port install valkey` |
| FreeBSD | `sudo pkg install valkey` |
| openSUSE | `sudo zypper install valkey` |

Valkey is NOT officially supported on Windows. Use WSL for development only.

### 1.2 Building from Source

```bash
# Download from https://github.com/valkey-io/valkey/releases
tar xzf valkey-<version>.tar.gz
cd valkey-<version>
make
make test    # optional but recommended
sudo make install
```

To build with TLS support:

```bash
make BUILD_TLS=yes
```

### 1.3 Docker

```bash
# Official image
docker run -d --name valkey \
  -p 6379:6379 \
  -v /data/valkey:/data \
  valkey/valkey:9 \
  valkey-server --appendonly yes --requirepass "YOUR_PASSWORD"

# With custom config
docker run -d --name valkey \
  -v /myvalkey/conf:/usr/local/etc/valkey \
  -v /myvalkey/data:/data \
  valkey/valkey:9 \
  valkey-server /usr/local/etc/valkey/valkey.conf
```

Bitnami image (includes AOF persistence by default):

```bash
docker run -d --name valkey \
  -e VALKEY_PASSWORD=secretpassword \
  -v valkey_data:/bitnami/valkey/data \
  bitnami/valkey:9
```

### 1.4 Bare Metal Production Setup

#### Create Valkey user and directories

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin valkey
sudo mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey /var/run/valkey
sudo chown valkey:valkey /var/lib/valkey /var/log/valkey /var/run/valkey
sudo cp valkey.conf /etc/valkey/valkey.conf
sudo chown valkey:valkey /etc/valkey/valkey.conf
```

#### Systemd service file

Create `/etc/systemd/system/valkey.service`:

```ini
[Unit]
Description=Valkey In-Memory Data Store
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/bin/valkey-server /etc/valkey/valkey.conf --supervised systemd
ExecStop=/usr/bin/valkey-cli -a $PASSWORD shutdown
Restart=always
RestartSec=3
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=full
ReadWriteDirectories=/var/lib/valkey /var/log/valkey /var/run/valkey

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now valkey
```

#### Kernel tuning (required)

Add to `/etc/sysctl.d/99-valkey.conf`:

```
vm.overcommit_memory = 1
net.core.somaxconn = 65535
```

Apply and disable transparent huge pages:

```bash
sudo sysctl --system
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

Make THP disabling persistent via a systemd unit or `/etc/rc.local`.

---

## 2. Configuration Deep Dive

Valkey reads configuration from `valkey.conf`. Most parameters can be changed at runtime via `CONFIG SET` and queried via `CONFIG GET`. To persist runtime changes: `CONFIG REWRITE`.

### 2.1 Essential Parameters

```
# Network
bind 127.0.0.1 -::1        # bind to specific interfaces
port 6379                   # client port (0 to disable non-TLS)
protected-mode yes          # reject external connections without auth
tcp-backlog 511             # TCP listen backlog
tcp-keepalive 300           # seconds between keepalive probes
timeout 0                   # idle client timeout (0 = disabled)
maxclients 10000            # max simultaneous connections

# Memory
maxmemory 2gb                      # hard memory limit
maxmemory-policy allkeys-lru       # eviction policy
maxmemory-clients 5%               # max aggregate client memory
maxmemory-samples 5                # LRU/LFU precision (higher = more accurate)

# Persistence - RDB
save 3600 1                 # snapshot every 3600s if >= 1 write
save 300 100                # snapshot every 300s if >= 100 writes
save 60 10000               # snapshot every 60s if >= 10000 writes
dbfilename dump.rdb
dir /var/lib/valkey

# Persistence - AOF
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec         # always | everysec | no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-use-rdb-preamble yes    # hybrid persistence

# I/O Threads (Valkey 8+)
io-threads 4                # total threads including main (2-8 typical)
io-threads-do-reads yes     # offload reads to I/O threads

# Logging
loglevel notice
logfile /var/log/valkey/valkey.log

# Slow log
slowlog-log-slower-than 10000    # microseconds (10ms)
slowlog-max-len 128              # entries to keep

# Latency monitor
latency-monitor-threshold 100    # milliseconds (0 = disabled)
```

### 2.2 Eviction Policies

| Policy | Scope | Algorithm | Best For |
|--------|-------|-----------|----------|
| `noeviction` | - | Rejects writes | Primary data store |
| `allkeys-lru` | All keys | Least recently used | General-purpose cache |
| `allkeys-lfu` | All keys | Least frequently used | Popular-item caching |
| `volatile-lru` | Keys with TTL | Least recently used | Mixed cache + persistent |
| `volatile-lfu` | Keys with TTL | Least frequently used | Mixed with frequency bias |
| `allkeys-random` | All keys | Random | Uniform access patterns |
| `volatile-random` | Keys with TTL | Random | Simple TTL-based cache |
| `volatile-ttl` | Keys with TTL | Shortest TTL first | Explicit TTL priorities |

Default recommendation: `allkeys-lru` unless you have specific requirements.

LFU tuning parameters:
- `lfu-log-factor 10` - controls saturation rate of the frequency counter
- `lfu-decay-time 1` - minutes between frequency counter halving

### 2.3 Memory Encoding Thresholds

Small collections use compact encodings (listpack) consuming up to 10x less memory. Conversion to standard encoding happens when thresholds are exceeded:

```
hash-max-listpack-entries 512
hash-max-listpack-value 64
zset-max-listpack-entries 128
zset-max-listpack-value 64
set-max-intset-entries 512
set-max-listpack-entries 128
set-max-listpack-value 64
list-max-listpack-size -2      # -2 = 8KB per node
```

### 2.4 Configuration by Workload Type

**Cache-only (volatile data)**:
```
maxmemory 80%_of_RAM
maxmemory-policy allkeys-lru
save ""                          # disable RDB
appendonly no                    # disable AOF
```

**Primary data store (durability required)**:
```
maxmemory-policy noeviction
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
save 3600 1 300 100 60 10000
```

**Session store**:
```
maxmemory-policy volatile-ttl
appendonly yes
appendfsync everysec
```

---

## 3. High Availability with Sentinel

Sentinel provides monitoring, automatic failover, and service discovery for non-clustered Valkey deployments.

### 3.1 Architecture

Minimum deployment: 3 Sentinel instances on independent infrastructure (different VMs, different availability zones). Sentinels communicate on TCP port 26379.

```
+----------+     +----------+     +----------+
| Sentinel |     | Sentinel |     | Sentinel |
|    (S1)  |     |    (S2)  |     |    (S3)  |
+----------+     +----------+     +----------+
      |                |                |
      v                v                v
+----------+     +----------+     +----------+
|  Primary |---->| Replica  |     | Replica  |
|  (6379)  |     |  (6380)  |     |  (6381)  |
+----------+     +----------+     +----------+
```

### 3.2 Sentinel Configuration

File: `sentinel.conf`

```
port 26379
sentinel monitor mymaster 192.168.1.10 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel auth-user mymaster sentinel_user
sentinel auth-pass mymaster sentinel_password
```

Key parameters:

| Parameter | Description |
|-----------|-------------|
| `sentinel monitor <name> <ip> <port> <quorum>` | Monitor a primary; quorum = Sentinels needed to agree on failure |
| `down-after-milliseconds` | Time before marking instance as subjectively down |
| `failover-timeout` | Max time for failover; also governs retry interval |
| `parallel-syncs` | Replicas reconfigured simultaneously during failover |

### 3.3 Quorum and Majority

Two authorization levels govern failover:

1. **Quorum** - Number of Sentinels that must agree a primary is down (triggers ODOWN)
2. **Majority** - More than half of all Sentinels must authorize the actual failover

Example with 5 Sentinels, quorum=2: Two Sentinels detect failure (ODOWN), but 3 Sentinels must authorize failover.

### 3.4 Failure Detection

- **SDOWN (Subjectively Down)**: A single Sentinel detects no valid PING response within `down-after-milliseconds`. Valid responses are `+PONG`, `-LOADING`, or `-MASTERDOWN`.
- **ODOWN (Objectively Down)**: `quorum` Sentinels report SDOWN within a 2x timeout window.

### 3.5 Replica Selection During Failover

Sentinels rank replicas by this priority:

1. Skip replicas disconnected longer than 10x `down-after-milliseconds`
2. Lower `replica-priority` value preferred (0 = never promote)
3. Higher replication offset (most data synced)
4. Lexicographically smaller run ID (tiebreaker)

### 3.6 Split-Brain Prevention

- Sentinel only triggers failover from the majority partition
- No failover occurs in the minority partition
- Configure `min-replicas-to-write 1` and `min-replicas-max-lag 10` on the primary to stop accepting writes when isolated from replicas

### 3.7 Docker and NAT Considerations

Port remapping breaks Sentinel auto-discovery. Solutions:

- Use `--net=host` networking mode
- Set explicit announcement: `sentinel announce-ip <ip>` and `sentinel announce-port <port>`

### 3.8 Coordinated Failover (Valkey 9.0+)

For planned maintenance:

```
SENTINEL FAILOVER mymaster COORDINATED
```

This performs a supervised handover with minimal disruption, coordinating between primary and replica.

### 3.9 Runbook: Sentinel Deployment

```bash
# 1. Start primary
valkey-server /etc/valkey/valkey.conf

# 2. Start replicas (on each replica host)
valkey-server /etc/valkey/valkey.conf --replicaof 192.168.1.10 6379

# 3. Start Sentinels (on each sentinel host)
valkey-sentinel /etc/valkey/sentinel.conf

# 4. Verify
valkey-cli -p 26379 SENTINEL masters
valkey-cli -p 26379 SENTINEL replicas mymaster
valkey-cli -p 26379 SENTINEL sentinels mymaster

# 5. Test failover
valkey-cli -p 26379 SENTINEL FAILOVER mymaster
```

---

## 4. Cluster Mode

Valkey Cluster provides automatic sharding across multiple nodes with 16,384 hash slots distributed via CRC16.

### 4.1 Network Requirements

Each cluster node requires two TCP ports:

- **Client port** (default 6379) - client connections and key migrations
- **Cluster bus port** (client port + 10000, or custom `cluster-port`) - node-to-node binary protocol

Both ports must be reachable between all cluster nodes.

### 4.2 Cluster Configuration

```
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-require-full-coverage yes
cluster-allow-reads-when-down no
cluster-migration-barrier 1
cluster-replica-validity-factor 10
```

| Parameter | Description |
|-----------|-------------|
| `cluster-node-timeout` | ms before node is considered failed |
| `cluster-require-full-coverage` | reject writes if not all 16384 slots are covered |
| `cluster-allow-reads-when-down` | serve reads even when cluster is down |
| `cluster-migration-barrier` | min replicas per primary before migration |
| `cluster-replica-validity-factor` | multiplier for replica eligibility window |

### 4.3 Creating a Cluster

Minimum: 3 primaries. Recommended: 6 nodes (3 primaries + 3 replicas).

```bash
# Start 6 nodes on ports 7000-7005, each with cluster-enabled yes
# Then create the cluster:
valkey-cli --cluster create \
  127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 \
  127.0.0.1:7003 127.0.0.1:7004 127.0.0.1:7005 \
  --cluster-replicas 1

# Connect with cluster mode enabled (-c flag)
valkey-cli -c -p 7000
```

### 4.4 Hash Slots and Hash Tags

Keys are assigned to slots via `CRC16(key) % 16384`. Multi-key commands require all keys in the same slot.

Force co-location with hash tags:

```
SET user:{123}:profile "..."
SET user:{123}:session "..."
# Both land in the same slot because {123} is the hash tag
```

### 4.5 Resharding

#### Interactive

```bash
valkey-cli --cluster reshard 127.0.0.1:7000
# Prompts: how many slots, destination node, source nodes
```

#### Automated

```bash
valkey-cli --cluster reshard 127.0.0.1:7000 \
  --cluster-from <source-node-id> \
  --cluster-to <target-node-id> \
  --cluster-slots 1000 \
  --cluster-yes
```

#### Atomic Slot Migration (Valkey 9.0+)

Valkey 9.0 replaces key-by-key migration with snapshot-based atomic migration:

```bash
# On source node:
CLUSTER MIGRATESLOTS SLOTSRANGE 0 5460 NODE <target-node-id>

# Monitor progress:
CLUSTER GETSLOTMIGRATIONS

# Cancel if needed:
CLUSTER CANCELSLOTMIGRATIONS
```

Performance comparison vs legacy migration:
- No load (3 to 4 shards): 1m42s legacy vs 10.7s atomic (9.5x faster)
- Heavy load (4 to 3 shards): 2m5s legacy vs 27.1s atomic (4.6x faster)

No `-ASK` redirections or multi-key operation failures during atomic migration.

### 4.6 Adding and Removing Nodes

```bash
# Add as primary (starts empty, needs resharding)
valkey-cli --cluster add-node 127.0.0.1:7006 127.0.0.1:7000

# Add as replica of specific primary
valkey-cli --cluster add-node 127.0.0.1:7006 127.0.0.1:7000 \
  --cluster-replica --cluster-master-id <primary-node-id>

# Remove replica
valkey-cli --cluster del-node 127.0.0.1:7000 <node-id>

# Remove primary (reshard slots first, then delete)
valkey-cli --cluster reshard 127.0.0.1:7000 \
  --cluster-from <node-id> --cluster-to <other-node-id> \
  --cluster-slots <all-slots> --cluster-yes
valkey-cli --cluster del-node 127.0.0.1:7000 <node-id>
```

### 4.7 Manual Failover

Execute on a replica to promote it safely (no data loss):

```bash
# Connect to the replica you want to promote
valkey-cli -p 7003 CLUSTER FAILOVER
```

The command blocks writes on the current primary, waits for replication offset sync, then completes the switch.

### 4.8 Cluster Health Checks

```bash
# Check slot coverage and node connectivity
valkey-cli --cluster check 127.0.0.1:7000

# View all nodes and their states
valkey-cli -p 7000 CLUSTER NODES

# Cluster state summary
valkey-cli -p 7000 CLUSTER INFO

# Fix broken clusters (reassign orphaned slots)
valkey-cli --cluster fix 127.0.0.1:7000
```

### 4.9 Consistency and Write Safety

Valkey Cluster uses asynchronous replication - the primary acknowledges writes before replication to replicas. This means:

- Writes can be lost if the primary crashes before replication completes
- During a network partition, minority-side clients can write to an isolated primary; those writes are lost when a replica in the majority becomes the new primary
- Use `WAIT <numreplicas> <timeout>` for synchronous replication on critical writes (reduces but does not eliminate risk)

### 4.10 Cluster Scalability

Valkey 9.0 supports clusters up to 2,000 nodes, capable of over 1 billion requests per second.

---

## 5. Persistence

### 5.1 RDB (Snapshotting)

Creates point-in-time binary snapshots.

**Strengths**: Compact file, fast restarts, efficient for backups, minimal runtime overhead (fork-based).

**Weaknesses**: Data loss between snapshots, fork can stall with large datasets.

```
save 3600 1 300 100 60 10000
dbfilename dump.rdb
dir /var/lib/valkey
rdbcompression yes
rdbchecksum yes
```

Commands:
- `BGSAVE` - background snapshot (recommended)
- `SAVE` - synchronous snapshot (blocks all clients)
- `LASTSAVE` - timestamp of last successful save

### 5.2 AOF (Append Only File)

Logs every write operation.

**Strengths**: Higher durability, configurable fsync, append-only prevents corruption, recoverable from accidental `FLUSHALL`.

**Weaknesses**: Larger files, potentially slower depending on fsync policy.

```
appendonly yes
appendfilename "appendonly.aof"
appenddirname "appendonlydir"
```

Fsync policies:

| Policy | Behavior | Durability | Performance |
|--------|----------|------------|-------------|
| `appendfsync always` | fsync after every command | Maximum | Slowest |
| `appendfsync everysec` | fsync every second (default) | High | Good |
| `appendfsync no` | OS controls flushing | Lower | Fastest |

AOF rewriting:

```
auto-aof-rewrite-percentage 100    # trigger when AOF is 100% larger than after last rewrite
auto-aof-rewrite-min-size 64mb     # minimum size before rewrite
no-appendfsync-on-rewrite no       # allow fsync during rewrite
```

Modern Valkey uses multi-part AOF:
- **Base file** - initial snapshot (RDB or AOF format)
- **Incremental files** - changes since base file
- **Manifest file** - tracks all components

### 5.3 Hybrid Persistence (Recommended for Production)

Enable both for defense in depth:

```
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes    # AOF base file uses RDB format (faster loads)
save 3600 1 300 100 60 10000
```

On startup, Valkey loads AOF (more complete) when both are present.

### 5.4 Backup Strategy

**Runbook: Automated Backups**

```bash
#!/bin/bash
# RDB backups - safe to copy while server runs
BACKUP_DIR=/backups/valkey
DATE=$(date +%Y%m%d_%H%M%S)

# Trigger fresh snapshot
valkey-cli -a "$PASSWORD" BGSAVE
sleep 5  # wait for completion, or poll INFO persistence

# Copy RDB
cp /var/lib/valkey/dump.rdb "$BACKUP_DIR/dump_${DATE}.rdb"

# AOF backup (disable rewriting first)
valkey-cli -a "$PASSWORD" CONFIG SET auto-aof-rewrite-percentage 0
cp -r /var/lib/valkey/appendonlydir "$BACKUP_DIR/aof_${DATE}"
valkey-cli -a "$PASSWORD" CONFIG SET auto-aof-rewrite-percentage 100

# Retention: keep 24 hourly, 30 daily
find "$BACKUP_DIR" -name "dump_*.rdb" -mtime +30 -delete

# Ship to off-site storage
aws s3 cp "$BACKUP_DIR/dump_${DATE}.rdb" s3://valkey-backups/ --sse
```

**Verify backups**: Check file sizes and SHA256 digests. Test restores regularly.

### 5.5 Disaster Recovery

1. Copy RDB to target host
2. Place in `dir` directory with correct `dbfilename`
3. Start Valkey - it loads the snapshot automatically
4. For AOF: place the entire `appendonlydir` directory

For geographic redundancy, replicate RDB snapshots to a different region (S3, GCS, or remote SCP).

---

## 6. Replication

### 6.1 Primary-Replica Setup

On the replica:

```
# In valkey.conf
replicaof 192.168.1.10 6379
primaryauth YOUR_PASSWORD

# Or at runtime
REPLICAOF 192.168.1.10 6379
```

To promote a replica to primary:

```
REPLICAOF NO ONE
```

### 6.2 Synchronization Mechanisms

**Full synchronization**: Primary forks, creates RDB snapshot, sends to replica, then streams buffered writes.

**Partial synchronization (PSYNC)**: When a replica reconnects, it sends its replication ID and offset. If the primary's backlog contains the needed data, only the delta is transferred.

### 6.3 Replication Backlog

The backlog enables partial resync and must be sized appropriately:

```
repl-backlog-size 256mb           # default 1mb - increase proportionally to memory
repl-backlog-ttl 3600             # seconds to retain backlog after last replica disconnects
```

**Sizing rule**: Set to a value that covers the expected disconnection window. If your replica can be offline for 60 seconds and the write rate is 2MB/s, set to at least 120MB.

If the backlog is insufficient, a full resync occurs - expensive with large datasets.

### 6.4 Diskless Replication

Skip writing RDB to disk during sync - stream directly to replicas:

```
repl-diskless-sync yes
repl-diskless-sync-delay 5        # seconds to wait for more replicas before starting
repl-diskless-sync-period 0       # min seconds between diskless syncs (0 = no limit)
repl-diskless-load disabled       # on-disk-load | swapdb | disabled
```

Use when disk I/O is slow but network is fast.

### 6.5 Dual-Channel Replication (Valkey 8+)

Transfers RDB and backlog simultaneously, accelerating full sync. Being made default in Valkey 9.

### 6.6 Safety Settings

```
replica-read-only yes             # prevent writes on replicas
min-replicas-to-write 1           # refuse writes if fewer connected replicas
min-replicas-max-lag 10           # max replication lag (seconds) for replica to count
```

These settings limit the write window during network partitions.

### 6.7 Replication in Docker/NAT

```
replica-announce-ip 5.5.5.5
replica-announce-port 1234
```

### 6.8 Critical Warnings

- **Always enable persistence on primaries** - if a primary without persistence auto-restarts, it starts empty and all replicas wipe their data
- **Disable auto-restart on primaries without persistence** - prevent cascading data loss
- **Writable replicas cause inconsistency** - the `replica-read-only yes` default is correct

---

## 7. Security

### 7.1 Defense in Depth Layers

1. **Network boundaries** - VPC, firewall, never expose to the internet
2. **Authentication** - ACLs or requirepass
3. **Authorization** - fine-grained command/key restrictions
4. **Encryption** - TLS in transit
5. **Operational security** - monitoring, logging, least privilege

### 7.2 Protected Mode

When Valkey binds to all interfaces (default) and has no password, it enters protected mode - only accepts localhost connections. Set a password or bind to specific interfaces to operate normally.

### 7.3 ACL Configuration

#### Create users

```
# Application user - all data commands, no dangerous operations
ACL SETUSER application on >strongpassword +@all -@dangerous -@scripting ~*

# Read-only monitoring user
ACL SETUSER monitor on >monitorpass +get +mget +info +ping ~*

# Cache writer with key restrictions
ACL SETUSER cache_writer on >cachepass ~cached:* +get +set +del +expire

# Admin
ACL SETUSER admin on >verystrongpassword ~* &* +@all

# Sentinel user (minimal permissions)
ACL SETUSER sentinel on >sentinelpass +multi +slaveof +ping +subscribe +config|rewrite +role +publish +info

# Replica user (on primary)
ACL SETUSER replica on >replicapass +psync +replconf +ping
```

#### Permission categories

Key categories: `@read`, `@write`, `@admin`, `@dangerous`, `@fast`, `@slow`, `@pubsub`, `@scripting`, `@connection`.

View categories: `ACL CAT`
View commands in category: `ACL CAT dangerous`

#### Key pattern permissions

- `~*` - all keys
- `~app:*` - keys matching prefix
- `%R~readonly:*` - read-only access to matching keys
- `%W~writeonly:*` - write-only access to matching keys

#### Selectors (multiple permission sets)

```
ACL SETUSER myuser on >pass +GET ~data:* (+SET ~cache:*)
# Can GET from data:* OR SET on cache:*
```

#### Manage ACLs

```bash
# List all users
ACL LIST

# Get user details
ACL GETUSER application

# Load from file
ACL LOAD

# Save to file
ACL SAVE

# Generate strong password
ACL GENPASS

# View access denials
ACL LOG
ACL LOG RESET
```

Store ACL definitions in an external file:

```
# valkey.conf
aclfile /etc/valkey/users.acl
```

### 7.4 TLS Configuration

```
# Server
tls-port 6379
port 0                          # disable non-TLS
tls-cert-file /path/to/server.crt
tls-key-file /path/to/server.key
tls-ca-cert-file /path/to/ca.crt

# Require client certificates (mTLS)
tls-auth-clients yes            # yes | no | optional

# Auto-reload certificates
tls-auto-reload-interval 3600   # seconds (0 = disabled)

# Replication over TLS
tls-replication yes

# Cluster bus over TLS
tls-cluster yes
```

Connect with TLS:

```bash
valkey-cli --tls --cert /path/to/client.crt --key /path/to/client.key --cacert /path/to/ca.crt
```

### 7.5 Dangerous Commands

The `@dangerous` category includes: `FLUSHDB`, `FLUSHALL`, `KEYS`, `DEBUG`, `CONFIG`, `SHUTDOWN`, `REPLICAOF`, `CLUSTER`, `ACL`, `BGREWRITEAOF`, `MONITOR`, `SLOWLOG`, `CLIENT`, `INFO`, `ROLE`.

Block for application users: `ACL SETUSER app on >pass +@all -@dangerous -@scripting`

### 7.6 Security Checklist

- [ ] Valkey bound to specific interfaces, not 0.0.0.0
- [ ] Firewall restricts port 6379 to trusted IPs only
- [ ] Authentication enabled (ACLs preferred over requirepass)
- [ ] Default user restricted or disabled
- [ ] Application users have minimal required permissions
- [ ] TLS enabled for all connections
- [ ] Valkey runs as unprivileged user
- [ ] `KEYS` command disabled in production (use `SCAN` instead)
- [ ] Monitoring for unauthorized connection attempts
- [ ] Credentials not committed to version control

---

## 8. Monitoring

### 8.1 INFO Command

```bash
# All sections
valkey-cli INFO

# Specific section
valkey-cli INFO memory
valkey-cli INFO stats
valkey-cli INFO replication
valkey-cli INFO clients
valkey-cli INFO keyspace
```

### 8.2 Critical Metrics to Monitor

#### Memory

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| `used_memory` | INFO memory | > 80% of maxmemory |
| `used_memory_rss` | INFO memory | RSS >> used_memory = fragmentation |
| `mem_fragmentation_ratio` | INFO memory | > 1.5 or < 1.0 (swapping) |
| `used_memory_peak` | INFO memory | Capacity planning |
| `evicted_keys` | INFO stats | > 0 when unexpected |

#### Connections

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| `connected_clients` | INFO clients | Near maxclients |
| `blocked_clients` | INFO clients | Growing trend |
| `rejected_connections` | INFO stats | > 0 |

#### Performance

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| `instantaneous_ops_per_sec` | INFO stats | Sudden drops |
| `keyspace_hits` / `keyspace_misses` | INFO stats | Hit rate < 90% |
| `latest_fork_usec` | INFO persistence | > 500ms |

#### Replication

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| `master_link_status` | INFO replication | != "up" |
| `master_last_io_seconds_ago` | INFO replication | > 10 |
| `master_sync_in_progress` | INFO replication | Stuck at 1 |

#### Persistence

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| `rdb_last_bgsave_status` | INFO persistence | != "ok" |
| `aof_last_bgrewrite_status` | INFO persistence | != "ok" |
| `rdb_last_bgsave_time_sec` | INFO persistence | Growing trend |

### 8.3 Prometheus Exporter

The `oliver006/redis_exporter` supports Valkey 8.x and 9.x.

```bash
# Docker
docker run -d --name valkey-exporter \
  -p 9121:9121 \
  -e REDIS_ADDR=valkey://valkey-host:6379 \
  -e REDIS_PASSWORD=secret \
  oliver006/redis_exporter

# Binary
./redis_exporter \
  --redis.addr=valkey://localhost:6379 \
  --redis.password=secret \
  --web.listen-address=0.0.0.0:9121
```

Key exporter flags:

| Flag | Env Var | Description |
|------|---------|-------------|
| `redis.addr` | `REDIS_ADDR` | Instance address (default: redis://localhost:6379) |
| `redis.user` | `REDIS_USER` | ACL username |
| `redis.password` | `REDIS_PASSWORD` | Authentication password |
| `web.listen-address` | `REDIS_EXPORTER_WEB_LISTEN_ADDRESS` | Exporter bind (default: 0.0.0.0:9121) |
| `namespace` | `REDIS_EXPORTER_NAMESPACE` | Metric prefix (default: redis) |
| `--is-cluster` | - | Enable cluster node discovery |

Prometheus configuration:

```yaml
scrape_configs:
  - job_name: valkey
    static_configs:
      - targets:
        - valkey-host-1:9121
        - valkey-host-2:9121
```

### 8.4 Grafana Dashboards

| Dashboard ID | Description |
|--------------|-------------|
| 763 | Redis Dashboard for Prometheus Redis Exporter 1.x |
| 14091 | Redis Exporter mixin-generated dashboard |
| 11835 | Redis HA (Helm stable/redis-ha) |
| 20154 | Redis Prometheus Exporter |

Import via Grafana: Dashboards -> Import -> Enter Dashboard ID.

### 8.5 Alerting Rules (Prometheus)

The redis_exporter provides a mixin with pre-built alerting rules. Key alerts to configure:

```yaml
groups:
  - name: valkey
    rules:
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical

      - alert: ValkeyMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels:
          severity: warning

      - alert: ValkeyReplicationBroken
        expr: redis_connected_slaves < 1
        for: 2m
        labels:
          severity: critical

      - alert: ValkeyRejectedConnections
        expr: increase(redis_rejected_connections_total[5m]) > 0
        for: 1m
        labels:
          severity: warning

      - alert: ValkeyHighLatency
        expr: redis_commands_duration_seconds_total / redis_commands_processed_total > 0.01
        for: 5m
        labels:
          severity: warning
```

### 8.6 Operational Commands

```bash
# Real-time command stream (use sparingly - adds overhead)
valkey-cli MONITOR

# Client connections
valkey-cli CLIENT LIST
valkey-cli CLIENT INFO

# Memory analysis
valkey-cli MEMORY USAGE <key>
valkey-cli MEMORY DOCTOR
valkey-cli MEMORY STATS

# Slow commands
valkey-cli SLOWLOG GET 10
valkey-cli SLOWLOG LEN
valkey-cli SLOWLOG RESET

# Latency
valkey-cli LATENCY LATEST
valkey-cli LATENCY HISTORY <event>
valkey-cli LATENCY DOCTOR
valkey-cli LATENCY GRAPH <event>
valkey-cli LATENCY RESET
```

---

## 9. Performance Tuning

### 9.1 I/O Threads

Valkey's main thread handles command execution. I/O threads offload read/write operations.

```
io-threads 4                # total thread count including main thread
io-threads-do-reads yes     # offload reads (default no in some versions)
```

Recommendations:
- 2-4 threads for most workloads
- Match to available CPU cores (do not exceed physical cores)
- Benchmark: Valkey achieved 1.19M RPS on a 16-core ARM instance with 9 I/O threads
- Valkey 8.1+ offloads more operations to I/O threads than earlier versions

### 9.2 TCP Backlog

```
tcp-backlog 511             # should match or exceed net.core.somaxconn
```

Ensure the kernel value is at least as large:

```bash
sysctl -w net.core.somaxconn=65535
```

### 9.3 Client Connection Tuning

```
maxclients 10000
timeout 300                          # close idle clients after 5 minutes
tcp-keepalive 300                    # detect dead connections
maxmemory-clients 5%                 # cap aggregate client memory
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
```

Client-side best practices:
- Use connection pooling (1 connection per node as starting point)
- Set client connection timeout to 5 seconds
- Set request timeout to 10 seconds
- Implement exponential backoff with jitter on reconnection
- Pipeline commands to reduce round-trips

### 9.4 Memory Optimization

1. **Use compact encodings** - keep collections under listpack thresholds
2. **Hash-based storage** - consolidate related fields into hashes instead of separate keys
3. **Bit operations** - use `SETBIT`/`GETBIT` for boolean flags (100M users = 12MB)
4. **Avoid `KEYS` command** - use `SCAN`, `SSCAN`, `HSCAN`, `ZSCAN`
5. **Set TTLs** - expire data you do not need indefinitely
6. **Monitor fragmentation** - if `mem_fragmentation_ratio` > 1.5, consider `MEMORY PURGE` or restart

### 9.5 Latency Diagnosis

#### Enable latency monitor

```
CONFIG SET latency-monitor-threshold 100    # log events >= 100ms
```

#### Measure intrinsic latency

```bash
valkey-cli --intrinsic-latency 100    # run on the server itself for 100 seconds
```

This measures the baseline latency floor of the OS/hypervisor.

#### Measure client-server latency

```bash
valkey-cli --latency -h <host> -p <port>
```

#### Use LATENCY DOCTOR

```
> LATENCY DOCTOR
Dave, I have observed latency spikes in this Valkey instance...
1. command: 5 latency spikes (average 300ms, mean deviation 120ms, period 73.40 sec).
   Worst all time event 500ms.
```

#### Software watchdog (emergency debugging)

```
CONFIG SET watchdog-period 500    # ms threshold, generates stack traces
# DISABLE WHEN DONE:
CONFIG SET watchdog-period 0
```

### 9.6 Slowlog Analysis

```
slowlog-log-slower-than 10000    # microseconds (10ms)
slowlog-max-len 128

# View slow commands
SLOWLOG GET 10
# Each entry: id, timestamp, duration(us), command, client-ip, client-name
```

### 9.7 Durability vs Performance Spectrum

From safest to fastest:

1. AOF + `appendfsync always`
2. AOF + `appendfsync everysec`
3. AOF + `appendfsync everysec` + `no-appendfsync-on-rewrite yes`
4. AOF + `appendfsync no`
5. RDB only with tuned save intervals
6. No persistence

### 9.8 Valkey 9.0 Performance Features

- **Memory prefetching for pipelines** - up to 40% higher throughput
- **Zero-copy responses** - up to 20% improvement for large payloads
- **SIMD optimizations** - 200% faster BITCOUNT and HyperLogLog
- **Multipath TCP** - up to 25% latency reduction
- **Atomic slot migration** - 4.6-9.5x faster resharding

---

## 10. Troubleshooting

### 10.1 Out of Memory (OOM)

**Symptoms**: Write errors (`OOM command not allowed when used memory > 'maxmemory'`), Linux OOM killer terminates Valkey.

**Diagnosis**:
```bash
valkey-cli INFO memory | grep -E "used_memory|maxmemory|mem_fragmentation"
valkey-cli MEMORY DOCTOR
```

**Resolution**:
1. Set explicit `maxmemory` - do not let Valkey grow unbounded
2. Choose an appropriate eviction policy
3. Enable swap on the host (safety net, not a solution)
4. Set `vm.overcommit_memory = 1` to prevent fork failures during BGSAVE
5. Check `mem_fragmentation_ratio` - if high, `MEMORY PURGE` or restart
6. Set `maxmemory-clients 5%` to prevent client buffers from consuming all memory

### 10.2 Replication Lag

**Symptoms**: `master_last_io_seconds_ago` increasing, `INFO replication` shows growing offset delta.

**Diagnosis**:
```bash
valkey-cli INFO replication
# Check: master_link_status, master_last_io_seconds_ago, slave_repl_offset vs master_repl_offset
```

**Resolution**:
1. Increase `repl-backlog-size` proportional to write rate and expected disconnection time
2. Check network bandwidth between primary and replica
3. Check disk I/O on replica (or enable `repl-diskless-sync yes`)
4. Check if replica is running expensive commands (KEYS, SORT on large datasets)
5. Verify `client-output-buffer-limit replica` is sufficient

### 10.3 Slow Commands

**Symptoms**: High latency, clients timing out.

**Diagnosis**:
```bash
valkey-cli SLOWLOG GET 25
valkey-cli LATENCY LATEST
valkey-cli LATENCY DOCTOR
```

**Common culprits**:
- `KEYS *` in production - replace with `SCAN`
- `SORT` on large lists
- `SMEMBERS` / `HGETALL` on huge collections
- `LREM` / `LPOS` on long lists
- Lua scripts running too long
- Large key deletion (use `UNLINK` instead of `DEL`)

### 10.4 Cluster Partition Issues

**Symptoms**: `CLUSTER INFO` shows `cluster_state:fail`, nodes marked as `fail` or `pfail`.

**Diagnosis**:
```bash
valkey-cli CLUSTER NODES    # check flags column
valkey-cli CLUSTER INFO     # cluster_state, cluster_slots_assigned
```

**Resolution**:
1. Check network connectivity between all nodes (both client and cluster bus ports)
2. Verify firewall rules allow port and port+10000
3. If a primary is permanently lost, `CLUSTER FAILOVER` on a replica
4. Fix slot coverage: `valkey-cli --cluster fix <host>:<port>`
5. Forgotten nodes: `CLUSTER FORGET <node-id>` on all remaining nodes

### 10.5 Fork Latency

**Symptoms**: `latest_fork_usec` in INFO shows high values, clients experience periodic freezes.

**Diagnosis**:
```bash
valkey-cli INFO persistence | grep fork
# latest_fork_usec: microseconds of the last fork
```

**Resolution**:
1. Disable transparent huge pages: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`
2. Use diskless replication to avoid fork on replicas
3. Consider using replicas for BGSAVE instead of the primary
4. On VMs, fork is slower - use bare metal for large datasets (24GB+)

### 10.6 Memory Testing

If experiencing unexplained crashes:

```bash
# Valkey built-in memory test
valkey-server --test-memory 4096    # test 4096 MB

# Or reboot and run memtest86 for thorough testing
```

### 10.7 Diagnostic Commands Reference

| Command | Purpose |
|---------|---------|
| `INFO [section]` | Server statistics |
| `MEMORY DOCTOR` | Memory issue analysis |
| `MEMORY USAGE <key>` | Per-key memory estimate |
| `MEMORY STATS` | Detailed memory breakdown |
| `LATENCY DOCTOR` | Latency analysis and advice |
| `LATENCY LATEST` | Recent latency spikes |
| `LATENCY HISTORY <event>` | Time series for event |
| `LATENCY GRAPH <event>` | ASCII latency visualization |
| `SLOWLOG GET [count]` | Slow command log |
| `CLIENT LIST` | All connected clients |
| `CLIENT INFO` | Current connection info |
| `CLUSTER NODES` | Cluster topology |
| `CLUSTER INFO` | Cluster state |
| `DEBUG SLEEP <seconds>` | Simulate delay (testing only) |
| `OBJECT ENCODING <key>` | Internal encoding of a key |
| `OBJECT FREQ <key>` | LFU frequency counter |

---

## 11. Upgrades and Maintenance

### 11.1 Version Compatibility

Valkey uses semantic versioning (`major.minor.patch`):

- **Patch** - bug fixes only, safe to mix in clusters, upgrade anytime
- **Minor** - backward-compatible features, avoid mixing in clusters, safe upgrade path
- **Major** - may break compatibility, review release notes carefully

Support policy:
- **Maintenance**: 3 years from first minor release (bug + security fixes)
- **Extended security**: 5 years for latest minor of each major

### 11.2 Redis to Valkey Migration

Valkey is compatible with Redis OSS 7.2 and all earlier versions. Redis CE 7.4+ is NOT compatible.

**Method 1: Binary replacement (downtime)**
```bash
systemctl stop redis
cp /var/lib/redis/dump.rdb /var/lib/valkey/dump.rdb
systemctl start valkey
```

**Method 2: Replication-based (minimal downtime)**
```bash
# Configure Valkey as replica of Redis
valkey-cli REPLICAOF redis-host 6379
# Wait for sync
valkey-cli INFO replication   # master_link_status:up, offset matches
# Switch clients to Valkey
# Promote Valkey
valkey-cli REPLICAOF NO ONE
```

**Method 3: Cluster migration**
1. Add Valkey nodes as replicas to Redis primaries
2. Wait for replication to sync
3. `CLUSTER FAILOVER` on each Valkey replica to promote
4. Remove Redis nodes: `valkey-cli --cluster del-node`

### 11.3 Rolling Upgrade (Standalone with Sentinel)

```bash
# 1. Upgrade replicas first (one at a time)
#    On each replica host:
systemctl stop valkey
# Install new version
systemctl start valkey
# Verify replication:
valkey-cli INFO replication

# 2. Trigger failover to promote upgraded replica
valkey-cli -p 26379 SENTINEL FAILOVER mymaster

# 3. Upgrade the old primary (now a replica)
systemctl stop valkey
# Install new version
systemctl start valkey

# 4. Verify
valkey-cli -p 26379 SENTINEL masters
```

### 11.4 Rolling Upgrade (Cluster)

For each shard:

```bash
# 1. Identify the shard (primary + replicas)
valkey-cli -p 7000 CLUSTER NODES

# 2. Upgrade replicas first
#    Stop replica, install new version, restart
systemctl stop valkey
# Install new version
systemctl start valkey

# 3. Verify replica rejoined and synced
valkey-cli -p 7003 INFO replication
valkey-cli -p 7000 CLUSTER NODES

# 4. Failover: promote upgraded replica
valkey-cli -p 7003 CLUSTER FAILOVER

# 5. Verify the failover
valkey-cli -p 7003 ROLE    # should show "master"

# 6. Upgrade old primary (now replica)
systemctl stop valkey
# Install new version
systemctl start valkey

# 7. Repeat for each shard
```

**Rules**:
- Always upgrade replicas before primaries
- Replica RDB version must be >= primary RDB version
- Do not run mixed minor versions in production clusters long-term

### 11.5 Configuration Changes Without Restart

```bash
# Change at runtime
valkey-cli CONFIG SET maxmemory 4gb

# Persist to config file
valkey-cli CONFIG REWRITE
```

Most parameters support runtime changes. Exceptions include `bind`, `port`, `cluster-enabled`, and other startup-only settings.

### 11.6 Zero-Downtime Primary Swap

```bash
# 1. Start new instance as replica
valkey-server --replicaof old-primary 6379

# 2. Wait for sync completion
valkey-cli -p 6380 INFO replication
# Confirm: master_link_status:up

# 3. Switch clients to new instance
# 4. Promote new instance
valkey-cli -p 6380 REPLICAOF NO ONE
```

---

## 12. Kubernetes Deployment

### 12.1 Deployment Options

| Option | Best For |
|--------|----------|
| Official Valkey Helm Chart | Standalone, replication |
| Bitnami Helm Chart | Standalone, replication, cluster |
| Hyperspike Operator | Cluster, sentinel, standalone (CRD-based) |
| SAP Operator | Sentinel, replication (CRD-based) |
| Raw StatefulSets | Full control, custom requirements |

### 12.2 Official Valkey Helm Chart

```bash
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update

# Standalone
helm install my-valkey valkey/valkey -f values.yaml

# Replication
helm install my-valkey valkey/valkey \
  --set architecture=replication \
  --set replica.replicas=3 \
  --set auth.enabled=true \
  --set auth.password=secretpassword
```

Key values.yaml settings:

```yaml
architecture: replication    # standalone | replication

auth:
  enabled: true
  password: ""               # or use existingSecret
  aclUsers: []

replica:
  enabled: true
  replicas: 3
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""

tls:
  enabled: false
  certFile: ""
  keyFile: ""
  caFile: ""

metrics:
  enabled: true              # deploys redis_exporter sidecar

valkeyConfig: |
  maxmemory 2gb
  maxmemory-policy allkeys-lru
```

### 12.3 Bitnami Helm Chart

```bash
helm install my-valkey oci://registry-1.docker.io/bitnamicharts/valkey

# Cluster mode
helm install my-valkey oci://registry-1.docker.io/bitnamicharts/valkey-cluster
```

### 12.4 Kubernetes Operators

#### Hyperspike Valkey Operator

```bash
# Install operator
helm install valkey-operator oci://ghcr.io/hyperspike/valkey-operator

# Or vanilla Kubernetes
kubectl apply -f https://github.com/hyperspike/valkey-operator/releases/latest/download/install.yaml
```

Supports cluster, sentinel, and standalone modes via CRDs. Includes TLS support and Prometheus ServiceMonitor integration.

#### SAP Valkey Operator

Uses Bitnami chart under the hood. Supports two topologies:

- **Static primary** with optional read replicas
- **Sentinel** with dynamic primary election

```yaml
apiVersion: cache.cs.sap.com/v1alpha1
kind: Valkey
metadata:
  name: my-valkey
spec:
  replicas: 3
  sentinel:
    enabled: true
  tls:
    enabled: true
  persistence:
    storageClass: standard
    size: 10Gi
```

Sentinel is exposed on port 26379, Valkey on port 6379. Note: `spec.sentinel.enabled` is immutable after creation.

### 12.5 StatefulSet Patterns

Key considerations for raw StatefulSet deployments:

#### Persistent Volumes

```yaml
volumeClaimTemplates:
  - metadata:
      name: valkey-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 10Gi
```

PVCs created by StatefulSets are NOT deleted when uninstalling - you must clean them up manually.

#### Pod Anti-Affinity

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["valkey"]
          topologyKey: kubernetes.io/hostname
```

Use `requiredDuringSchedulingIgnoredDuringExecution` for strict placement across nodes.

#### Health Probes

```yaml
livenessProbe:
  exec:
    command: ["valkey-cli", "-a", "$PASSWORD", "ping"]
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  exec:
    command: ["valkey-cli", "-a", "$PASSWORD", "ping"]
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
```

#### Resource Requests and Limits

```yaml
resources:
  requests:
    memory: 2Gi
    cpu: 500m
  limits:
    memory: 4Gi
    # Avoid CPU limits for latency-sensitive workloads
```

### 12.6 Pod Disruption Budget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: valkey
```

Never set `maxUnavailable: 0` - this blocks node drains entirely.

### 12.7 Kernel Tuning in Kubernetes

```yaml
securityContext:
  sysctls:
    - name: net.core.somaxconn
      value: "65535"
```

For transparent huge pages, use an init container:

```yaml
initContainers:
  - name: disable-thp
    image: busybox
    command: ["sh", "-c", "echo never > /sys/kernel/mm/transparent_hugepage/enabled"]
    securityContext:
      privileged: true
    volumeMounts:
      - name: sys
        mountPath: /sys
```

Or handle at the node level via a DaemonSet.

### 12.8 Docker and NAT Limitations

Valkey Cluster does NOT support NATted environments or port remapping. In Kubernetes:

- Use `hostNetwork: true` for cluster mode (not ideal)
- Or use a Kubernetes operator that handles cluster bus port routing
- Sentinel mode is simpler in Kubernetes than cluster mode

### 12.9 Monitoring in Kubernetes

Deploy redis_exporter as a sidecar:

```yaml
containers:
  - name: valkey
    image: valkey/valkey:9
    ports:
      - containerPort: 6379
  - name: exporter
    image: oliver006/redis_exporter:latest
    ports:
      - containerPort: 9121
    env:
      - name: REDIS_ADDR
        value: "redis://localhost:6379"
      - name: REDIS_PASSWORD
        valueFrom:
          secretKeyRef:
            name: valkey-secret
            key: password
```

Create a ServiceMonitor for Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: valkey
spec:
  selector:
    matchLabels:
      app: valkey
  endpoints:
    - port: metrics
      interval: 15s
```

---

## Quick Reference: Production Checklist

### System

- [ ] `vm.overcommit_memory = 1`
- [ ] `net.core.somaxconn >= 65535`
- [ ] Transparent huge pages disabled
- [ ] Swap enabled (safety net)
- [ ] File descriptor limit >= maxclients + 32
- [ ] Valkey runs as unprivileged user

### Configuration

- [ ] `maxmemory` set explicitly (not unlimited)
- [ ] Eviction policy chosen for workload
- [ ] `maxmemory-clients 5%` set
- [ ] `tcp-keepalive 300`
- [ ] Persistence strategy configured and tested
- [ ] `latency-monitor-threshold` enabled (50-100ms)

### Security

- [ ] ACLs configured per service
- [ ] TLS enabled
- [ ] Bound to specific interfaces
- [ ] Firewall rules in place
- [ ] Default user restricted

### Monitoring

- [ ] Prometheus exporter running
- [ ] Grafana dashboards imported
- [ ] Alerts configured (down, memory, replication, latency)
- [ ] Slow log reviewed periodically

### Backup

- [ ] RDB snapshots shipped off-host
- [ ] Backup retention policy (24h hourly, 30d daily)
- [ ] Restore procedure tested

### High Availability

- [ ] Sentinel (3+ instances) or Cluster (3+ primaries) deployed
- [ ] `min-replicas-to-write` configured
- [ ] Failover tested in staging
- [ ] Replication backlog sized appropriately
