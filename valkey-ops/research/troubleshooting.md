# Valkey/Redis Troubleshooting Patterns and Production Incidents

Research compiled from Valkey official documentation, AWS ElastiCache best practices,
Instagram Engineering, and production operator experience. Intended to enrich
valkey-ops reference docs with real-world diagnostic sequences, threshold values,
and recovery procedures.

---

## 1. OOM Diagnosis and Prevention

### Root Causes

1. **No maxmemory set** - 64-bit instances default to no memory limit, gradually
   consuming all free memory until the OOM killer fires.
2. **Replication buffer overhead** - Replication and AOF buffers are NOT counted
   against maxmemory for eviction purposes. Formula:
   `used_memory - mem_not_counted_for_evict > maxmemory` triggers eviction.
   Operators must set maxmemory lower than physical RAM to account for this.
3. **Copy-on-write during fork** - BGSAVE/BGREWRITEAOF can use up to 2x memory
   due to COW. Write-heavy workloads touch many pages during the fork, each
   requiring a copy.
4. **Client output buffer bloat** - Pub/Sub subscribers that cannot keep up, or
   replicas with slow links, accumulate output buffers that bypass maxmemory
   accounting.
5. **Large key accumulation** - A single hash, set, or sorted set growing
   unbounded, consuming disproportionate memory.

### Diagnostic Command Sequence

```bash
# Step 1: Get memory overview
valkey-cli INFO memory
# Key fields:
#   used_memory              - Total bytes allocated by Valkey
#   used_memory_rss          - RSS from OS (what actually matters for OOM)
#   used_memory_peak         - Historical peak
#   mem_fragmentation_ratio  - RSS / used_memory (see fragmentation section)
#   mem_not_counted_for_evict - Replication + AOF buffer overhead
#   used_memory_overhead     - Non-dataset memory (buffers, metadata)
#   used_memory_dataset      - Actual data

# Step 2: Detailed memory breakdown
valkey-cli MEMORY STATS
# Reports: peak.allocated, total.allocated, startup.allocated,
#   replication.backlog, clients.slaves, clients.normal, cluster.links,
#   aof.buffer, keys.count, keys.bytes-per-key, dataset.bytes,
#   dataset.percentage, fragmentation, fragmentation.bytes,
#   allocator-fragmentation.ratio, allocator-fragmentation.bytes

# Step 3: Automated diagnosis
valkey-cli MEMORY DOCTOR
# Returns human-readable report on memory issues and remedies

# Step 4: Check for large keys (sample top offenders)
valkey-cli --memkeys          # Scans entire keyspace, reports top keys by memory
valkey-cli --memkeys-samples 100  # Limit sampling
valkey-cli --bigkeys          # Reports largest key per data type

# Step 5: Check specific key memory usage
valkey-cli MEMORY USAGE <key> SAMPLES 0   # Exact (slower)
valkey-cli MEMORY USAGE <key> SAMPLES 5   # Sampled (faster, default)

# Step 6: Check client buffer usage
valkey-cli CLIENT LIST
# Look at: omem (output buffer memory), tot-mem (total per-client memory)
# Sort by tot-mem to find buffer hogs

# Step 7: Check eviction activity
valkey-cli INFO stats | grep evicted_keys
valkey-cli INFO stats | grep total_eviction_exceeded_time
```

### Threshold Values from Production

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| `used_memory / maxmemory` | < 75% | 75-90% | > 90% |
| `evicted_keys` (rate) | 0 | > 0 (if unexpected) | sustained high rate |
| `mem_not_counted_for_evict` | < 5% of maxmemory | 5-15% | > 15% |
| Client `tot-mem` (single) | < 10MB | 10-100MB | > 100MB |

**Source**: AWS ElastiCache best practices recommend setting CloudWatch alarms at
`DatabaseMemoryUsagePercentage` thresholds: 65% WARN, 80% HIGH, 90% CRITICAL.

### Prevention Configuration

```
# valkey.conf - OOM prevention
maxmemory <80% of available RAM>
maxmemory-policy allkeys-lru          # or allkeys-lfu for frequency-based
maxmemory-clients 5%                  # Aggregate client memory cap (Valkey 7.0+)

# Output buffer limits (prevent buffer bloat)
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60

# Swap prevention - critical for latency
# OS level: vm.overcommit_memory = 1
```

### Common Misconfiguration: maxmemory with Replication

When replication is configured, maxmemory must account for replication buffer
overhead. The `mem_not_counted_for_evict` metric shows how much memory is used by
these buffers. If a replica disconnects and needs full resync, the primary
allocates a large output buffer for the RDB transfer. Recommendation: set
maxmemory 10-20% lower than available RAM when using replication.

**Instagram Engineering case study**: Storing 300M key-value pairs. Naive
`SET media:<id> <user_id>` consumed ~70MB per 1M keys (21GB total). Switching to
hash bucketing (`HSET mediabucket:<id/1000> <id> <user_id>`) reduced memory to
16MB per 1M keys (5GB total) - a 4x reduction. This works because small hashes
use ziplist/listpack encoding that is 5-10x more memory efficient.

---

## 2. Memory Fragmentation

### How Fragmentation Happens

Fragmentation occurs when the allocator (jemalloc by default) cannot efficiently
reuse freed memory. The `mem_fragmentation_ratio` is `used_memory_rss / used_memory`.

- **Ratio > 1.5**: Significant fragmentation. RSS is much larger than logical
  usage. The allocator holds freed memory in internal pools that the OS sees as
  still allocated.
- **Ratio < 1.0**: Valkey has more logical memory than physical RSS, meaning
  memory is being swapped to disk. This is extremely dangerous for latency.
- **Ratio 1.0-1.5**: Normal operating range.

### Real-World Causes

1. **Delete-heavy workloads** - Filling 5GB, deleting 2GB leaves RSS at ~5GB
   while `used_memory` shows ~3GB. The allocator keeps freed pages for future
   reuse but the OS sees them as allocated.
2. **Variable-size key churn** - Repeatedly creating and deleting keys of
   different sizes fragments the allocator's size classes.
3. **Large key deletion** - Deleting a 1GB sorted set returns memory to the
   allocator in small chunks, creating fragmentation.
4. **Listpack-to-hashtable conversions** - When small collections exceed
   `*-max-listpack-entries`, the compact encoding converts to a full hash table,
   fragmenting the original memory.

### Diagnostic Sequence

```bash
# Step 1: Check overall fragmentation
valkey-cli INFO memory | grep -E 'mem_fragmentation|allocator_frag'
# mem_fragmentation_ratio    - RSS / used_memory
# mem_fragmentation_bytes    - Absolute difference
# allocator_frag_ratio       - Allocator-level fragmentation
# allocator_frag_bytes       - Allocator fragmentation bytes
# allocator_rss_ratio        - RSS overhead from allocator

# Step 2: Detailed allocator stats (jemalloc only)
valkey-cli MEMORY MALLOC-STATS
# Shows jemalloc internal arena stats, dirty/muzzy pages, bin utilization

# Step 3: Check MEMORY STATS for breakdown
valkey-cli MEMORY STATS
# Look at: allocator.allocated, allocator.active, allocator.resident,
#   allocator.muzzy, allocator-fragmentation.ratio,
#   overhead.db.hashtable.rehashing (temporary rehashing overhead)

# Step 4: Check for active defragmentation status
valkey-cli INFO stats | grep active_defrag
# active_defrag_running, active_defrag_hits, active_defrag_misses,
# active_defrag_key_hits, active_defrag_key_misses
```

### Active Defragmentation (Valkey 4.0+)

```bash
# Enable active defragmentation at runtime
valkey-cli CONFIG SET activedefrag yes

# Tuning parameters
CONFIG SET active-defrag-enabled yes
CONFIG SET active-defrag-threshold-lower 10    # Start when frag > 10%
CONFIG SET active-defrag-threshold-upper 100   # Max effort at 100%
CONFIG SET active-defrag-cycle-min 1           # Min CPU% for defrag
CONFIG SET active-defrag-cycle-max 25          # Max CPU% for defrag
CONFIG SET active-defrag-max-scan-fields 1000  # Max fields scanned per key
```

The active defragmentation cycle is tracked by the latency monitor under the
`active-defrag-cycle` event.

### Recovery Procedure

If fragmentation ratio exceeds 1.5 and active defrag is insufficient:
1. Enable active defrag with aggressive settings (cycle-max 25-50).
2. If ratio exceeds 2.0, consider a rolling restart: failover to replica,
   restart the old primary (fresh memory layout), then failover back.
3. For persistent fragmentation, review workload patterns - high delete rates
   with variable sizes are the primary cause.

---

## 3. Replication Lag Root Causes

### How Replication Works

Valkey uses asynchronous primary-replica replication. Each primary has a
replication ID and offset. Replicas use PSYNC to request incremental updates.
When the backlog is insufficient or the replication ID is unknown, a full
resynchronization occurs (BGSAVE + bulk transfer + buffered commands).

### Root Causes of Lag

1. **Replication backlog too small** - If the replica disconnects and the
   backlog cannot hold all writes during the disconnection, a full resync is
   triggered. Full resyncs are catastrophically expensive.
2. **Network bandwidth saturation** - High write throughput exceeds the
   network link capacity between primary and replica.
3. **Slow replica disk I/O** - If the replica has persistence enabled (RDB/AOF),
   disk I/O can slow down command processing.
4. **Large key writes** - A single large MSET or RESTORE can block replication
   processing on the replica.
5. **Replica output buffer overflow** - Default hard limit is 256MB. If the
   replica falls behind far enough, the primary disconnects it (triggering
   full resync).
6. **Fork latency on primary** - During BGSAVE for full resync, the primary
   buffers all new writes. Long fork times delay replication stream resumption.

### Diagnostic Sequence

```bash
# Step 1: Check replication status
valkey-cli INFO replication
# Key fields:
#   role                     - master or slave
#   connected_slaves         - Number of connected replicas
#   master_repl_offset       - Primary's current offset
#   slave0:...,offset=X,lag=Y  - Per-replica offset and lag (seconds)
#   repl_backlog_active      - Is backlog active?
#   repl_backlog_size        - Configured backlog size
#   repl_backlog_first_byte_offset - Oldest offset in backlog
#   second_repl_offset       - Secondary replication ID offset

# Step 2: On the replica
valkey-cli INFO replication
#   master_link_status       - up or down
#   master_last_io_seconds_ago - Seconds since last data from primary
#   master_sync_in_progress  - Is full sync happening?
#   master_sync_left_bytes   - Bytes remaining in bulk transfer
#   slave_repl_offset        - Replica's current offset

# Step 3: Calculate lag
# lag_bytes = master_repl_offset - slave_repl_offset
# lag_seconds = from the slave0 info line

# Step 4: Check for full resyncs
valkey-cli INFO stats | grep sync_full
# sync_full: count of full resyncs performed
# sync_partial_ok: successful partial resyncs
# sync_partial_err: failed partial resyncs (triggered full)

# Step 5: Check replica output buffer
valkey-cli CLIENT LIST TYPE replica
# Look at omem (output buffer memory) and oll (output list length)
```

### Production Thresholds

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| `slave_lag` (seconds) | 0-1 | 1-10 | > 10 |
| `master_link_status` | up | - | down |
| `sync_full` (rate) | 0 | any increase | repeated |
| Replica `omem` | < 64MB | 64-200MB | > 200MB |

### Prevention

```
# Size backlog to hold at least 60s of writes
# Estimate: check master_repl_offset growth over 60s
repl-backlog-size 512mb    # Default is only 1mb - almost always too small

# Increase backlog TTL to avoid premature release
repl-backlog-ttl 3600

# Use diskless replication for faster full syncs
repl-diskless-sync yes
repl-diskless-sync-delay 5

# Prevent replica output buffer overflow
client-output-buffer-limit replica 512mb 128mb 60
```

### Common Misconfiguration: Persistence Disabled on Primary

If persistence is off on the primary and the primary restarts (empty dataset),
all replicas will sync with the empty primary and lose their data. If using
Sentinel, the primary may restart fast enough that Sentinel does not detect the
failure. Always either enable persistence on the primary or disable auto-restart.

---

## 4. Cluster Partition Recovery

### Failure Detection Mechanism

Valkey Cluster uses a two-stage failure detection:

1. **PFAIL (Possible Failure)** - A node flags another as PFAIL when it has not
   responded to pings for longer than `cluster-node-timeout`. This is local only.
2. **FAIL** - PFAIL escalates to FAIL when a majority of primary nodes report
   PFAIL/FAIL for the same node within `NODE_TIMEOUT * 2`. A FAIL message is
   broadcast to all reachable nodes.

### Automatic Failover Process

When a primary enters FAIL state:
1. Eligible replicas wait: `DELAY = 500ms + random(0-500ms) + REPLICA_RANK * 1000ms`
   - REPLICA_RANK 0 = most up-to-date replica (tries first)
2. Replica increments `currentEpoch` and broadcasts `FAILOVER_AUTH_REQUEST`
3. Primaries vote (one vote per `NODE_TIMEOUT * 2` period per failed primary)
4. If majority of primaries vote yes, replica wins election
5. Replica obtains new `configEpoch`, promotes itself, broadcasts new config
6. If election fails, retry after `NODE_TIMEOUT * 4` (minimum 4 seconds)

### Diagnostic Sequence

```bash
# Step 1: Check cluster state
valkey-cli CLUSTER INFO
# cluster_state:ok|fail
# cluster_slots_assigned:16384 (must be 16384)
# cluster_slots_ok, cluster_slots_pfail, cluster_slots_fail
# cluster_known_nodes, cluster_size

# Step 2: Check node status
valkey-cli CLUSTER NODES
# Each line shows: <id> <ip:port> <flags> <master-id> <ping-sent> <pong-recv>
#   <config-epoch> <link-state> <slots>
# Look for: fail, pfail, noaddr flags

# Step 3: Check for slot coverage gaps
valkey-cli CLUSTER SLOTS
# Verify all 16384 slots are covered

# Step 4: Check cluster link health
valkey-cli CLUSTER LINKS
```

### Manual Failover Procedure

```bash
# Safe manual failover (no data loss, requires primary reachable)
# Run on the REPLICA you want to promote:
valkey-cli -h <replica-ip> -p <replica-port> CLUSTER FAILOVER

# Process:
# 1. Replica tells primary to stop accepting writes
# 2. Primary replies with current replication offset
# 3. Replica waits until it catches up to that offset
# 4. Replica starts election, wins, becomes primary
# 5. Old primary redirects clients to new primary

# Forced failover (primary unreachable, majority of primaries still up)
valkey-cli -h <replica-ip> -p <replica-port> CLUSTER FAILOVER FORCE

# Emergency failover (no cluster consensus needed, e.g., DC switchover)
valkey-cli -h <replica-ip> -p <replica-port> CLUSTER FAILOVER TAKEOVER
# WARNING: TAKEOVER violates last-failover-wins. Use only in emergencies.
```

### Recovery After Split-Brain / Partition

```bash
# Step 1: Identify the situation
valkey-cli -h <node> CLUSTER NODES | grep -E 'fail|pfail'

# Step 2: If nodes have stale failure flags, clear them
# Usually nodes clear FAIL flags automatically after NODE_TIMEOUT
# has passed and the node is reachable again.

# Step 3: If slots are uncovered
# Check which slots are unassigned:
valkey-cli --cluster check <any-node-ip>:<port>

# Step 4: Fix slot coverage
valkey-cli --cluster fix <any-node-ip>:<port>

# Step 5: Rebalance if needed
valkey-cli --cluster rebalance <any-node-ip>:<port>

# Step 6: Nuclear option - reset a node
# CAUTION: Flushes data, forgets all other nodes
valkey-cli -h <node> FLUSHALL
valkey-cli -h <node> CLUSTER RESET HARD
```

### Key Configuration for Partition Tolerance

```
cluster-node-timeout 15000          # 15s default, lower = faster detection
cluster-require-full-coverage yes   # Cluster goes down if any slot uncovered
                                    # Set to 'no' for partial availability
cluster-allow-reads-when-down no    # Set to 'yes' for read availability during failure
cluster-allow-pubsubshard-when-down yes
```

---

## 5. Slow Command Diagnosis

### Slow Log Configuration and Usage

The slow log records commands that exceed an execution time threshold. Execution
time excludes I/O (client communication) - it measures only the time the single
thread is blocked executing the command.

```bash
# Configure slow log
CONFIG SET slowlog-log-slower-than 10000   # 10ms in microseconds (default)
CONFIG SET slowlog-max-len 128             # Max entries retained (default)
# Valkey 9.0+ alternative name: COMMANDLOG

# Production recommendation: lower threshold for latency-sensitive workloads
CONFIG SET slowlog-log-slower-than 1000    # 1ms threshold

# Read slow log
valkey-cli SLOWLOG GET 25     # Last 25 entries
# Each entry:
#   1) Unique ID (never resets until server restart)
#   2) Unix timestamp
#   3) Execution time in microseconds
#   4) Command + arguments array
#   5) Client IP:port
#   6) Client name (from CLIENT SETNAME)

valkey-cli SLOWLOG LEN        # Number of entries in log
valkey-cli SLOWLOG RESET      # Clear the slow log
```

### Common Slow Command Patterns

| Command Pattern | Why It's Slow | Fix |
|----------------|---------------|-----|
| `KEYS *` | O(N) scan of entire keyspace | Use `SCAN` with cursor |
| `SMEMBERS` on large set | O(N) where N = cardinality | Use `SSCAN` |
| `HGETALL` on large hash | O(N) fields | Use `HSCAN` or `HMGET` specific fields |
| `SORT` on large list/set | O(N+M*log(M)) | Pre-sort in application or use sorted sets |
| `DEL` on large collection | O(N) for collections | Use `UNLINK` (async delete) |
| `LRANGE 0 -1` on large list | O(N) | Paginate with smaller ranges |
| `FLUSHDB` / `FLUSHALL` | O(N) keys | Use `FLUSHDB ASYNC` / `FLUSHALL ASYNC` |
| `SUBSCRIBE` (pattern) | Per-message CPU for pattern matching | Use exact channel names |
| Lua script > 5s | Blocks all clients | Break into smaller scripts, use `FUNCTION` |
| `SAVE` (foreground) | Blocks entire server for full dump | Use `BGSAVE` always |

### Diagnostic Workflow

```bash
# Step 1: Check if slow commands are currently happening
valkey-cli SLOWLOG GET 10

# Step 2: Check commandstats for O(N) command usage
valkey-cli INFO commandstats
# Look for high call counts on: keys, smembers, hgetall, sort, lrange,
# sunion, sdiff, sinter, zrangebyscore (with large ranges)

# Step 3: Monitor real-time (use briefly, adds overhead)
valkey-cli MONITOR
# WARNING: MONITOR itself adds overhead. Use only for brief debugging.
# In production, prefer SLOWLOG.

# Step 4: Check latency spikes correlated with commands
valkey-cli LATENCY LATEST
valkey-cli LATENCY HISTORY command
valkey-cli LATENCY HISTORY fast-command

# Step 5: Analyze with LATENCY DOCTOR
valkey-cli LATENCY DOCTOR
# Example output:
# "1. command: 5 latency spikes (average 300ms, mean deviation 120ms,
#    period 73.40 sec). Worst all time event 500ms."
# Includes advice like adjusting slowlog threshold, checking for large
# object operations.
```

### AWS Best Practice (from ElastiCache monitoring guide)

- `EngineCPUUtilization` above 90% indicates command processing saturation.
- Set CloudWatch alarms at 65% WARN, 90% HIGH for `EngineCPUUtilization`.
- High CPU is often caused by O(N) commands on large collections or non-optimal
  data models (e.g., large cardinality sets with `SMEMBERS`).
- Use read replicas for expensive read operations to offload the primary.
- Running snapshots on the primary adds CPU load; prefer snapshotting from a
  replica.

---

## 6. Fork Latency Mitigation

### Why Fork Is Expensive

Both BGSAVE and BGREWRITEAOF use `fork(2)` to create a child process. Fork must
copy the page table of the parent process:

**Formula**: Page table size = `(dataset_size / page_size) * pointer_size`
- Example: 24GB dataset / 4KB pages * 8 bytes = 48MB page table to copy
- On modern hardware: typically 10-20ms per GB of dataset
- On older virtualized environments without hardware-assisted virtualization:
  can be 100ms+ per GB

### Compounding Factor: Transparent Huge Pages (THP)

When THP is enabled, after fork, the COW (copy-on-write) unit is 2MB instead of
4KB. A single write to any byte in a 2MB huge page forces the entire 2MB to be
copied. In a busy instance, a few event loops touch thousands of pages, causing
near-complete COW of the entire process memory.

**This is the single most common Linux misconfiguration for Valkey/Redis.**

### Diagnostic Sequence

```bash
# Step 1: Check fork time
valkey-cli INFO stats | grep latest_fork_usec
# latest_fork_usec: last fork time in microseconds
# Healthy: < 10ms per GB of dataset
# Problematic: > 25ms per GB

# Step 2: Check THP status
cat /sys/kernel/mm/transparent_hugepage/enabled
# If output contains [always] or [madvise], THP is enabled

# Step 3: Check latency events related to fork
valkey-cli LATENCY HISTORY fork
# Returns timestamp-latency pairs for fork events

# Step 4: Check COW memory during background save
valkey-cli INFO persistence
# Look at: rdb_last_cow_size, aof_last_cow_size
# If COW size is close to used_memory, THP is likely the cause

# Step 5: Check intrinsic latency of the environment
valkey-cli --intrinsic-latency 100
# Run on the SERVER, not client
# Healthy bare metal: < 0.5ms
# Healthy VM: < 2ms
# Problematic: > 10ms (noisy neighbor, overcommitted host)
```

### Mitigation Steps

```bash
# 1. Disable THP (most important single action)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
# Make persistent across reboots:
# Add to /etc/rc.local or systemd unit

# 2. For very large datasets, use diskless replication
CONFIG SET repl-diskless-sync yes
# Avoids fork for RDB-to-disk, streams directly to replica

# 3. Tune save intervals to reduce fork frequency
# Default: save 3600 1 300 100 60 10000
# For large datasets, reduce frequency:
CONFIG SET save "3600 1"   # Save only if 1+ changes in 1 hour

# 4. Use AOF instead of RDB for persistence
# AOF rewrite still forks, but less frequently than RDB saves
CONFIG SET appendonly yes
CONFIG SET no-appendfsync-on-rewrite yes  # Reduce disk pressure during rewrite

# 5. Process placement (advanced)
# Ensure BGSAVE child runs on different CPU core than main process
# Use numactl to keep process on single NUMA node
numactl --cpunodebind=0 --membind=0 valkey-server /etc/valkey.conf
```

### Latency Events Tracked by the Monitor

The latency monitoring framework tracks these fork-related events:
- `fork` - The `fork(2)` system call itself
- `rdb-unlink-temp-file` - Unlinking temp RDB file
- `aof-rewrite-diff-write` - Writing accumulated diffs during BGREWRITEAOF
- `aof-fsync-always` - fsync when `appendfsync always` is set
- `aof-write` - General AOF write catchall
- `aof-write-pending-fsync` - Write while fsync is pending
- `aof-write-active-child` - Write while child process is active

---

## 7. Connection Storm Handling

### What Causes Connection Storms

1. **Application restart/deploy** - All instances reconnect simultaneously
2. **Failover event** - Clients reconnect to new primary
3. **Network partition recovery** - Buffered connections flood in
4. **Connection pool misconfiguration** - Pool max too high per instance,
   multiplied across many application servers
5. **Missing connection reuse** - Web applications creating new connections
   per request

### Diagnostic Sequence

```bash
# Step 1: Check current connection count
valkey-cli INFO clients
# connected_clients      - Current count
# maxclients             - Configured limit (default 10000)
# blocked_clients        - Clients in blocking operations
# tracking_clients       - Clients using client-side caching
# clients_in_timeout_table - Clients in timeout state

# Step 2: Check connection rate
valkey-cli INFO stats | grep -E 'total_connections|rejected_connections'
# total_connections_received - Lifetime total
# rejected_connections       - Connections rejected (maxclients reached)

# Step 3: Analyze connected clients
valkey-cli CLIENT LIST
# Key fields for storm diagnosis:
#   age   - Connection age in seconds (many age=0 = storm)
#   idle  - Idle time (many idle=0 + age=0 = storm)
#   flags - Check for 'N' (normal), 'S' (replica), 'P' (pub/sub)

# Quickly count connections by IP:
valkey-cli CLIENT LIST | grep -oP 'addr=\K[^:]+' | sort | uniq -c | sort -rn | head

# Step 4: Check file descriptor usage
valkey-cli CONFIG GET maxclients
# Also check OS: ulimit -n (should be >> maxclients)
```

### Mitigation and Prevention

```bash
# 1. Set appropriate maxclients
CONFIG SET maxclients 10000

# 2. Ensure OS file descriptor limits are adequate
# /etc/security/limits.conf:
# valkey  soft  nofile  65536
# valkey  hard  nofile  65536
# Or: ulimit -Sn 100000

# 3. Configure client eviction to prevent memory exhaustion
CONFIG SET maxmemory-clients 5%
# Evicts clients consuming the most memory first

# 4. Protect critical connections from eviction
# On monitoring/admin connections:
valkey-cli CLIENT NO-EVICT ON

# 5. TCP backlog for burst absorption
CONFIG SET tcp-backlog 511    # Default; increase for high-burst scenarios
# Also set OS: sysctl -w net.core.somaxconn=65535

# 6. Timeout idle connections
CONFIG SET timeout 300        # Close connections idle for 5 minutes
CONFIG SET tcp-keepalive 300  # Send TCP keepalives every 5 minutes
```

### Client-Side Best Practices

- Use connection pools with bounded size (e.g., 10-50 per app instance)
- Implement exponential backoff on reconnection
- Use persistent connections (never connect/disconnect per request)
- For same-host deployments, use Unix domain sockets (30us vs 200us latency)
- Pipeline commands to reduce round trips
- Use `CLIENT SETNAME` for easier debugging

### Output Buffer Limits (Prevent Buffer Storms)

```
# Default limits:
client-output-buffer-limit normal 0 0 0         # No limit for normal clients
client-output-buffer-limit replica 256mb 64mb 60 # Hard 256MB, soft 64MB/60s
client-output-buffer-limit pubsub 32mb 8mb 60    # Hard 32MB, soft 8MB/60s

# The query buffer has a non-configurable hard limit of 1 GB per client.
```

---

## 8. Hot Key Detection and Key Pattern Analysis

### Why Hot Keys Matter

A hot key is a single key receiving a disproportionate number of operations.
In cluster mode, a hot key means a single shard handles disproportionate load
while others are idle. In standalone mode, it monopolizes CPU time.

### Detection Methods

```bash
# Method 1: valkey-cli hot keys mode (requires LFU eviction policy)
CONFIG SET maxmemory-policy allkeys-lfu
valkey-cli --hotkeys
# Reports keys ranked by access frequency using OBJECT FREQ internally

# Method 2: Check individual key frequency (LFU mode required)
valkey-cli OBJECT FREQ <key>
# Returns logarithmic access frequency counter

# Method 3: MONITOR sampling (brief use only)
# Capture 10 seconds of traffic, analyze key frequency
timeout 10 valkey-cli MONITOR > /tmp/monitor.log
# Parse most accessed keys:
grep -oP '"[A-Z]+".*' /tmp/monitor.log | awk '{print $2}' | \
  tr -d '"' | sort | uniq -c | sort -rn | head -20

# Method 4: SCAN + OBJECT IDLETIME for cold key detection
# Useful for finding keys that are never accessed (waste of memory)
# OBJECT IDLETIME returns seconds since last access (requires LRU policy)
valkey-cli OBJECT IDLETIME <key>

# Method 5: Big key analysis
valkey-cli --bigkeys
# Scans entire keyspace using SCAN, reports largest key per type
# Output includes: biggest string, biggest list, biggest set, etc.
# Also reports key count distribution per type

valkey-cli --memkeys
# Like --bigkeys but ranks by actual memory usage (MEMORY USAGE)
```

### Key Pattern Analysis

```bash
# Analyze key namespace distribution using SCAN
valkey-cli SCAN 0 COUNT 1000 MATCH "user:*"    # Count user keys
valkey-cli DBSIZE                                # Total keys in current DB

# For cluster: check per-slot key distribution
valkey-cli CLUSTER COUNTKEYSINSLOT <slot>

# Check key types and encoding
valkey-cli TYPE <key>
valkey-cli OBJECT ENCODING <key>
# Efficient encodings: ziplist, listpack, intset, embstr
# Memory-heavy encodings: hashtable, skiplist, linkedlist, raw
```

### Hot Key Mitigation Strategies

1. **Read replicas** - Route reads to replicas to distribute hot key load
2. **Local caching** - Use client-side caching with server-assisted invalidation
   (`CLIENT TRACKING` in Valkey 6.0+)
3. **Key sharding** - Split hot key across multiple sub-keys
   (e.g., `counter:{N}` where N = random(0, num_shards))
4. **Cluster rebalancing** - Move the slot containing the hot key to a
   less-loaded shard

---

## 9. Latency Doctor and Memory Doctor Usage

### LATENCY DOCTOR

The `LATENCY DOCTOR` command provides a human-readable analysis of latency
events. It is the most powerful tool in the latency monitoring framework.

**Prerequisites**: Enable latency monitoring first:
```bash
CONFIG SET latency-monitor-threshold 100   # Log events > 100ms
# Set to 0 to disable (default). Set according to your SLA.
# If your SLA is 10ms, set threshold to 5-10ms.
```

**Example output**:
```
127.0.0.1:6379> LATENCY DOCTOR
Dave, I have observed latency spikes in this Valkey instance.
You don't mind talking about it, do you Dave?

1. command: 5 latency spikes (average 300ms, mean deviation 120ms,
   period 73.40 sec). Worst all time event 500ms.

I have a few advices for you:

- Your current Slow Log configuration only logs events that are slower
  than your configured latency monitor threshold. Please use
  'CONFIG SET slowlog-log-slower-than 1000'.
- Check your Slow Log to understand what are the commands you are running
  which are too slow to execute. Please check SLOWLOG for more information.
- Deleting, expiring or evicting (because of maxmemory policy) large objects
  is a blocking operation. If you have very large objects that are often
  deleted, expired, or evicted, try to fragment those objects into multiple
  smaller objects.
```

**What it reports**:
- Per-event statistics: spike count, average latency, mean deviation, period
- Worst all-time event duration
- Contextual advice based on the specific events detected
- For `fork` events: reports fork rate and correlates with BGSAVE/AOF rewrite
- For `command` events: suggests reviewing SLOWLOG
- For `expire-cycle` events: suggests checking for mass-expiration patterns

### Related Latency Commands

```bash
# Latest spikes across all events
valkey-cli LATENCY LATEST
# Returns: event name, timestamp of latest spike, latest spike ms, all-time max ms

# Time series for specific event (up to 160 entries)
valkey-cli LATENCY HISTORY command
valkey-cli LATENCY HISTORY fork
valkey-cli LATENCY HISTORY expire-cycle
valkey-cli LATENCY HISTORY active-defrag-cycle
# Returns: array of [timestamp, latency_ms] pairs

# ASCII graph of event history
valkey-cli LATENCY GRAPH command

# Reset latency data
valkey-cli LATENCY RESET          # All events
valkey-cli LATENCY RESET command   # Specific event
```

### Tracked Latency Events Reference

| Event | What It Measures |
|-------|-----------------|
| `command` | Regular command execution |
| `fast-command` | O(1) and O(log N) commands |
| `fork` | fork(2) system call |
| `rdb-unlink-temp-file` | unlink(2) of temp RDB file |
| `aof-fsync-always` | fsync(2) with appendfsync always |
| `aof-write` | Catchall for AOF write(2) calls |
| `aof-write-pending-fsync` | write(2) when fsync is pending |
| `aof-write-active-child` | write(2) when child process is active |
| `aof-write-alone` | write(2) with no pending fsync, no child |
| `aof-fstat` | fstat(2) on AOF file |
| `aof-rename` | rename(2) after BGREWRITEAOF completes |
| `aof-rewrite-diff-write` | Writing diffs during BGREWRITEAOF |
| `active-defrag-cycle` | Active defragmentation cycle |
| `expire-cycle` | Key expiration cycle |
| `eviction-cycle` | Key eviction cycle |
| `eviction-del` | Deletes during eviction |

### MEMORY DOCTOR

The `MEMORY DOCTOR` command reports memory-related issues. It checks for:
- High fragmentation ratio
- High allocator fragmentation
- High RSS overhead
- Whether the dataset is too small relative to overhead
- Unusual memory allocation patterns

```bash
valkey-cli MEMORY DOCTOR
# Returns: "Sam, I have no memory problems" if healthy
# Or: detailed report of detected issues with remediation advice
```

### Complete Troubleshooting Diagnostic Runbook

When investigating a production issue, run this sequence:

```bash
# Phase 1: Quick assessment (< 30 seconds)
valkey-cli PING                          # Is it responsive?
valkey-cli INFO server | head -20        # Version, uptime, mode
valkey-cli LATENCY LATEST                # Any recent spikes?
valkey-cli SLOWLOG GET 5                 # Recent slow commands?

# Phase 2: Memory health (< 1 minute)
valkey-cli INFO memory                   # Full memory picture
valkey-cli MEMORY DOCTOR                 # Automated memory diagnosis

# Phase 3: Latency analysis (< 1 minute)
valkey-cli LATENCY DOCTOR                # Automated latency diagnosis
valkey-cli --intrinsic-latency 10        # 10s baseline test (run on server)

# Phase 4: Replication health (if applicable)
valkey-cli INFO replication              # Lag, link status, backlog

# Phase 5: Client analysis (< 1 minute)
valkey-cli INFO clients                  # Connection counts
valkey-cli CLIENT LIST                   # Per-client details

# Phase 6: Cluster health (if applicable)
valkey-cli CLUSTER INFO                  # Cluster state
valkey-cli CLUSTER NODES                 # Node health
valkey-cli --cluster check <ip>:<port>   # Slot coverage

# Phase 7: Persistence health
valkey-cli INFO persistence              # RDB/AOF status, COW size, fork time
valkey-cli INFO stats | grep -E 'fork|sync|evict|expired'
```

---

## 10. Real-World Incident Patterns

### Incident: Mass Key Expiration Spike

**Symptoms**: Periodic latency spikes every N seconds, `expire-cycle` events in
latency monitor.

**Root cause**: Application sets thousands of keys with `EXPIREAT` using the same
timestamp (e.g., cache TTL aligned to clock boundaries). When the expiration
second arrives, the active expiry cycle finds > 25% of sampled keys expired and
loops aggressively, blocking the main thread.

**Resolution**:
- Add jitter to TTLs: `EXPIRE key (base_ttl + random(0, jitter_seconds))`
- Monitor with `LATENCY HISTORY expire-cycle`
- The active expiry algorithm samples `ACTIVE_EXPIRE_CYCLE_LOOKUPS_PER_LOOP`
  keys (default 20) ten times per second. It loops if > 25% are expired.

### Incident: Replica Cascade Full Resync

**Symptoms**: Repeated full resyncs (`sync_full` counter incrementing),
spike in primary memory usage, high I/O during BGSAVE.

**Root cause**: Replication backlog too small (default 1MB). Any brief
network glitch exceeds the backlog, forcing full resync. Full resync causes
BGSAVE fork, which causes latency spike, which can cause other replicas to
also lose sync, creating a cascade.

**Resolution**:
- Increase `repl-backlog-size` to at least 512MB (calculate: write throughput *
  max expected disconnection time)
- Enable `repl-diskless-sync yes` for faster full resyncs
- Monitor `sync_partial_err` - any non-zero value means partial resync failures

### Incident: THP-Induced Latency After BGSAVE

**Symptoms**: Periodic 500ms-2s latency spikes correlated with BGSAVE schedule.
`latest_fork_usec` shows 50ms, but `rdb_last_cow_size` is nearly equal to
`used_memory` (near-complete COW).

**Root cause**: THP enabled on Linux. After fork, every page touched by the main
process triggers a 2MB COW copy instead of 4KB.

**Resolution**: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`

### Incident: Pub/Sub Subscriber OOM

**Symptoms**: Memory usage growing unboundedly, eventually OOM kill.
`CLIENT LIST` shows pub/sub clients with `omem` in the hundreds of MB.

**Root cause**: Slow subscriber cannot consume messages fast enough. Output
buffer grows without bound because default pub/sub hard limit (32MB) was
increased or because many subscribers each accumulate moderate buffers.

**Resolution**:
- Set strict output buffer limits:
  `CONFIG SET client-output-buffer-limit pubsub 32mb 8mb 60`
- Implement application-level backpressure
- Use `maxmemory-clients` to cap aggregate client memory

### Incident: Large Key Migration Blocked (Cluster)

**Symptoms**: Cluster slot migration hangs, `CLUSTER NODES` shows slot in
`migrating`/`importing` state indefinitely. Multi-key commands on affected
slot fail.

**Root cause**: A very large key (e.g., sorted set with millions of members)
exceeds the target node's input buffer limit during migration.

**Resolution (pre-Valkey 9.0)**:
- Increase `proto-max-bulk-len` on target node
- Or delete the large key and re-create
- Or use `CLUSTER SETSLOT <slot> NODE <node-id>` to force slot assignment
  (data loss for keys in that slot)

**Valkey 9.0 fix**: Slot-level migration replaces key-by-key migration,
handling large keys atomically.

### Incident: Swap-Induced Latency

**Symptoms**: Sporadic latency spikes of 100ms+, unrelated to commands.
`valkey-cli --intrinsic-latency` shows normal baseline.

**Root cause**: Some Valkey memory pages swapped to disk. Accessing a swapped
page triggers a page fault with disk I/O latency.

**Diagnosis**:
```bash
# Check swap usage for the Valkey process
REDIS_PID=$(valkey-cli INFO server | grep process_id | cut -d: -f2 | tr -d '\r')
cat /proc/$REDIS_PID/smaps | grep '^Swap:' | grep -v '0 kB'
# Any non-trivial swap entries indicate the problem
```

**Resolution**:
- Ensure `maxmemory` is set well below available RAM
- Increase available RAM or reduce dataset size
- If swap is needed as safety net, monitor but ensure Valkey pages stay resident

---

## Sources

- Valkey official documentation: valkey.io/topics/latency, /topics/latency-monitor,
  /topics/memory-optimization, /topics/replication, /topics/cluster-spec,
  /topics/sentinel, /topics/lru-cache, /topics/admin, /topics/clients
- Valkey command reference: MEMORY DOCTOR, MEMORY STATS, MEMORY USAGE,
  MEMORY MALLOC-STATS, LATENCY DOCTOR, LATENCY LATEST, LATENCY HISTORY,
  SLOWLOG GET, CLIENT LIST, CLUSTER INFO, CLUSTER FAILOVER, CLUSTER RESET,
  OBJECT FREQ, CLIENT NO-EVICT, CONFIG SET
- AWS Database Blog: "Monitoring best practices with Amazon ElastiCache for Redis
  using Amazon CloudWatch" (Yann Richard, Oct 2020, updated Jul 2023)
- Instagram Engineering: "Storing hundreds of millions of simple key-value pairs
  in Redis" (Mike Krieger, Nov 2011)
- Valkey Blog: "Introducing Valkey 9.0" (slot-level migration, memory prefetch,
  1B req/s clusters)
