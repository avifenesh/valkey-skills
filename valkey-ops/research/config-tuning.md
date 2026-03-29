# Valkey Configuration Tuning for Production Workloads

Research compiled from Valkey official documentation, valkey.conf reference (unstable branch), and
production tuning guides. Intended to enrich existing reference docs with actionable tuning recipes.

Sources:
- valkey.io/topics/memory-optimization
- valkey.io/topics/lru-cache
- valkey.io/topics/latency
- valkey.io/topics/clients
- valkey.io/topics/admin
- valkey.io/topics/pubsub
- github.com/valkey-io/valkey/blob/unstable/valkey.conf

---

## 1. Memory Management

### 1.1 maxmemory

**Default**: Unset (no limit on 64-bit; implicit 3 GB on 32-bit)

**Production rule**: Always set `maxmemory` explicitly. Without it, Valkey will consume all available
RAM and eventually trigger the kernel OOM killer.

**Sizing formula**:

```
maxmemory = available_ram - os_overhead - replication_buffers - fragmentation_headroom
```

Practical example on a 32 GB dedicated host:

```
# Reserve ~20% for OS, buffers, and fragmentation
maxmemory 25gb
```

With replication enabled, set maxmemory lower than for a standalone instance. Replica output buffers,
AOF rewrite buffers, and replication backlog are subtracted from `used_memory` before comparing to
`maxmemory`, but you still need free RAM for these buffers to exist.

**Anti-pattern**: Setting `maxmemory` to the full physical RAM and wondering why the OOM killer fires
during BGSAVE (fork doubles page table memory usage).

**Interaction effects**:
- With replication: output buffers for replicas are NOT counted toward eviction threshold, so eviction
  may not fire soon enough if maxmemory equals total available RAM.
- With persistence: BGSAVE/BGREWRITEAOF fork causes copy-on-write; a write-heavy workload can double
  memory usage during the save. Size accordingly.

### 1.2 maxmemory-policy (Eviction Policies)

**Default**: `noeviction`

Available policies:

| Policy | Scope | Algorithm | Best For |
|--------|-------|-----------|----------|
| `noeviction` | - | Return errors on writes | Databases, queues (data must not be lost) |
| `allkeys-lru` | All keys | Approximated LRU | General-purpose cache with power-law access |
| `allkeys-lfu` | All keys | Approximated LFU | Caches with stable hot-set and frequency skew |
| `volatile-lru` | Keys with TTL | Approximated LRU | Mixed persistent + cache keys |
| `volatile-lfu` | Keys with TTL | Approximated LFU | Mixed workload with frequency-based eviction |
| `allkeys-random` | All keys | Random | Cyclic/uniform access patterns |
| `volatile-random` | Keys with TTL | Random | Uniform access on TTL-bearing keys |
| `volatile-ttl` | Keys with TTL | Shortest TTL first | Explicit TTL-based priority eviction |

**Workload-specific recommendations**:

- **Cache (general)**: `allkeys-lru` - the safest default for caches. Works well when you expect
  power-law distribution in popularity (a subset of keys accessed far more than the rest).
- **Cache (frequency-sensitive)**: `allkeys-lfu` - better hit ratio when popular items are accessed
  repeatedly over time. Adapts to shifting access patterns via decay.
- **Session store**: `volatile-lru` or `volatile-ttl` - sessions already have TTLs; `volatile-ttl`
  evicts sessions closest to expiry first.
- **Queue / database**: `noeviction` - data loss is unacceptable; the application should handle
  OOM errors.
- **Mixed (cache + persistent keys)**: `volatile-lru` - only keys with TTLs are eviction candidates,
  so persistent keys are safe. However, `allkeys-lru` is more memory-efficient since TTLs cost memory.

**Anti-pattern**: Using `volatile-*` policies when no keys have TTLs set - the policy degrades to
`noeviction` behavior silently.

### 1.3 maxmemory-samples

**Default**: 5

Controls the precision of the approximated LRU/LFU algorithm. Valkey samples this many keys and
evicts the best candidate among them.

| Value | Behavior |
|-------|----------|
| 3 | Fastest, least accurate |
| 5 | Good balance (default) |
| 10 | Very close to true LRU, higher CPU |
| 64 | Maximum - diminishing returns beyond 10 |

**Production guidance**: Leave at 5 unless you observe poor cache hit ratios. Raise to 10 only if
monitoring confirms a benefit. The CPU cost of 10 vs 5 is measurable under high load.

### 1.4 maxmemory-eviction-tenacity

**Default**: 10

Controls how aggressively eviction runs under memory pressure. Range 0-100.

| Value | Behavior |
|-------|----------|
| 0 | Minimum latency impact, eviction may fall behind on write-heavy loads |
| 10 | Default balance |
| 100 | Process eviction without regard to latency - use for extreme write bursts |

**When to tune**: Only increase if monitoring shows `used_memory` consistently exceeding `maxmemory`
under write-heavy traffic. Decrease if eviction latency spikes are unacceptable.

### 1.5 active-expire-effort

**Default**: 1

Controls how aggressively the background expiry cycle runs. Range 1-10.

| Value | Behavior |
|-------|----------|
| 1 | Default - aims for <10% expired keys in memory, <25% CPU for expiry |
| 5 | Moderate - more CPU, faster reclamation |
| 10 | Maximum - use if memory from expired keys is not reclaimed fast enough |

**Anti-pattern**: Setting to 10 on an instance with millions of keys with similar TTLs - the expiry
cycle will consume significant CPU and introduce latency spikes.

---

## 2. Eviction Policy Deep Dive: LRU vs LFU

### 2.1 Approximated LRU

Valkey does NOT implement true LRU. It samples `maxmemory-samples` keys and evicts the one with the
oldest access time. With the default sample size of 5, the approximation is good enough for most
workloads. At 10 samples, it is virtually indistinguishable from true LRU.

**Key insight from Valkey benchmarks**: With a power-law access pattern, the difference between true
LRU and Valkey's approximation is minimal or non-existent. The approximation only diverges with
perfectly uniform access patterns, where LRU itself is not optimal anyway.

### 2.2 LFU Mode

LFU tracks access frequency using a probabilistic Morris counter (8 bits per key, max value 255).
It uses logarithmic increment and time-based decay.

**Tuning parameters**:

#### lfu-log-factor

**Default**: 10

Controls how many accesses are needed to saturate the 8-bit counter (max 255):

| factor | 100 hits | 1,000 hits | 100K hits | 1M hits | 10M hits |
|--------|----------|------------|-----------|---------|----------|
| 0 | 104 | 255 | 255 | 255 | 255 |
| 1 | 18 | 49 | 255 | 255 | 255 |
| 10 | 10 | 18 | 142 | 255 | 255 |
| 100 | 8 | 11 | 49 | 143 | 255 |

**Tuning guidance**:
- `factor=0`: Maximum resolution for rarely-accessed keys. Good for distinguishing between
  "accessed once" vs "accessed 100 times".
- `factor=10` (default): Good for most workloads. Distinguishes well up to 100K accesses.
- `factor=100`: Best for extremely high-traffic keys where you need to distinguish between
  100K and 10M accesses.

**Counter initial value**: 5 - new keys start with frequency 5 to prevent immediate eviction.

#### lfu-decay-time

**Default**: 1 (minute)

How often the counter is decremented. When a key is sampled and found to have a counter older than
`lfu-decay-time` minutes, the counter is halved.

| Value | Behavior |
|-------|----------|
| 0 | Never decay - keys that were popular once stay popular forever |
| 1 | Decay every minute (default) - adapts to shifting access patterns |
| 10+ | Slow decay - "memory" of past popularity lasts longer |

**Tuning guidance**:
- For caches with stable hot-sets: `lfu-decay-time 5` to 10 - slow decay prevents thrashing
- For caches with rapidly shifting popularity: `lfu-decay-time 1` (default)
- For session stores: `lfu-decay-time 0` is rarely correct - sessions that were hot 30 min ago
  may be expired now

### 2.3 When LFU Outperforms LRU

LFU generally provides better hit ratios than LRU when:
- The access pattern has strong frequency skew (some keys accessed 1000x more than others)
- The hot-set is relatively stable over time
- Scan-like operations exist that would "pollute" LRU cache (one-time full scans)

LRU is better when:
- Access patterns shift rapidly (today's hot keys are tomorrow's cold keys)
- Recency is more important than frequency
- The workload is mostly power-law distributed (LRU already handles this well)

**Monitoring**: Use `OBJECT FREQ <key>` to inspect LFU counters. Use `INFO stats` to monitor
`keyspace_hits` and `keyspace_misses` to compute hit ratio before/after policy changes.

---

## 3. Encoding Threshold Tuning

Small aggregate data types use memory-efficient compact encodings (listpack, intset) that use
up to 10x less memory (5x average) compared to full data structures. When a threshold is exceeded,
Valkey automatically converts to the full encoding.

### 3.1 Default Thresholds

```
hash-max-listpack-entries   512
hash-max-listpack-value     64

zset-max-listpack-entries   128
zset-max-listpack-value     64

set-max-intset-entries      512
set-max-listpack-entries    128
set-max-listpack-value      64

list-max-listpack-size      -2    # 8 KB per node
list-compress-depth         0     # no compression

hll-sparse-max-bytes        3000

stream-node-max-bytes       4096
stream-node-max-entries     100
```

### 3.2 Workload-Specific Tuning

#### Cache workload (many small hashes)

The classic optimization: split flat key-value data into hash buckets of ~100 fields each.
For example, `object:1234` becomes `HSET object:12 34 value`. Each hash stays under the listpack
threshold and uses dramatically less memory.

```
# For the hash-bucketing pattern: keep entries at 128 max
hash-max-listpack-entries 128
hash-max-listpack-value   64
```

**Memory savings**: A hash with 100 fields uses roughly the same memory as 2-3 standalone keys,
versus 100 standalone keys consuming 50-100x more overhead.

#### Session store (hashes with 10-30 fields, values <100 bytes)

```
# Sessions fit comfortably in listpack
hash-max-listpack-entries 128
hash-max-listpack-value   128    # Raise if session fields contain JSON blobs
```

#### Queue workload (lists with rapid push/pop)

```
# -2 means 8 KB max per quicklist node - best throughput
list-max-listpack-size -2

# Compress inner nodes if lists grow long (reduces memory, costs CPU)
list-compress-depth 1
```

| list-compress-depth | Behavior |
|---------------------|----------|
| 0 | No compression (fastest) |
| 1 | Compress all except head and tail nodes |
| 2 | Exclude 2 nodes from each end |
| 3 | Exclude 3 nodes from each end |

#### Sorted set leaderboards (small per-user leaderboards)

```
# If leaderboards have <200 entries, raise threshold for memory savings
zset-max-listpack-entries 256
zset-max-listpack-value   64
```

#### Sets of integer IDs

```
# Intset is extremely compact for integer-only sets
# Raise if your ID sets commonly exceed 512 but stay under 1000
set-max-intset-entries 1024
```

### 3.3 Conversion Cost Warning

Raising thresholds saves memory but increases conversion time when a key exceeds the threshold.
The conversion from listpack to dict/hashtable is O(N) where N is the number of entries.
For small values this is sub-millisecond, but for thresholds raised to thousands of entries,
benchmark the conversion time before deploying.

**Anti-pattern**: Setting `hash-max-listpack-entries 10000` - the listpack is O(N) for lookups,
so HGET becomes noticeably slower for large hashes. The sweet spot is typically 128-512 entries.

---

## 4. Client Output Buffer Limits

### 4.1 Defaults

```
client-output-buffer-limit normal  0      0     0
client-output-buffer-limit replica 256mb  64mb  60
client-output-buffer-limit pubsub  32mb   8mb   60
```

Format: `client-output-buffer-limit <class> <hard-limit> <soft-limit> <soft-seconds>`

- **Hard limit**: Immediate disconnect when reached
- **Soft limit**: Disconnect if sustained for `soft-seconds` continuously

### 4.2 Client Classes

**Normal clients**: No limit by default. Normal clients use request-response (pull), so buffers
don't normally accumulate. Exception: MONITOR command clients or clients issuing massive KEYS/SMEMBERS
responses.

**Replica clients**: Default 256 MB hard, 64 MB soft for 60s. Must be >= `repl-backlog-size` (Valkey
ignores configurations below that). During slot migration with atomic migration, ensure these limits
accommodate accumulated mutations during snapshotting.

**Pub/Sub clients**: Default 32 MB hard, 8 MB soft for 60s. This is the most commonly tuned class.

### 4.3 Tuning for High-Throughput Pub/Sub

Slow subscribers cause message backlog in the output buffer. When the buffer exceeds limits, the
subscriber is disconnected - and messages are lost (Pub/Sub is at-most-once delivery).

**High-throughput Pub/Sub recipe**:

```
# Raise limits for environments where subscribers may lag
client-output-buffer-limit pubsub 64mb 16mb 120

# If subscribers are known to be fast, tighten limits to protect memory
client-output-buffer-limit pubsub 16mb 4mb 30
```

**Anti-pattern**: Setting pubsub hard limit to 0 (unlimited) - a single slow subscriber can consume
all available memory.

**Interaction with maxmemory-clients**: When `maxmemory-clients` is set (e.g., 5% of maxmemory),
client eviction kicks in before output buffer limits. Client eviction disconnects the client using
the most memory first, regardless of class.

### 4.4 Tuning for Replication

During full resync, the primary must buffer all writes while the RDB transfer is in progress.
If the write rate is high and the RDB transfer is slow, the replica output buffer can exceed limits
and break replication.

```
# For write-heavy primaries with large datasets (long RDB transfer time)
client-output-buffer-limit replica 512mb 128mb 120

# Ensure repl-backlog-size is proportional
repl-backlog-size 256mb
```

### 4.5 Client Query Buffer

```
# Default 1 GB hard limit per client - not configurable to be higher
# Reduce if clients should never send huge payloads
client-query-buffer-limit 256mb
```

---

## 5. Connection Management at Scale

### 5.1 maxclients

**Default**: 10,000

Valkey reserves 32 file descriptors for internal use. The effective limit is
`min(maxclients, ulimit_soft - 32)`.

**OS prerequisites**:

```bash
# Set per-process file descriptor limit
ulimit -Sn 100000

# Set system-wide limit
sysctl -w fs.file-max=100000

# Persist in /etc/sysctl.conf
echo "fs.file-max=100000" >> /etc/sysctl.conf
```

**Cluster mode warning**: Each cluster node uses 2 connections per peer (incoming + outgoing).
A 100-node cluster consumes ~200 file descriptors just for cluster bus. Size maxclients accordingly.

### 5.2 Connection Pooling Guidance

Valkey supports persistent connection pools on the client side. Benefits:
- Eliminates connection setup overhead (TCP handshake, AUTH, SELECT)
- Reduces file descriptor churn
- Improves throughput under high concurrency

**Pool sizing formula**:

```
pool_size = (num_application_instances * connections_per_instance)
# Must be < maxclients with headroom for replicas, sentinels, admin tools

# Example: 20 app servers, 50 connections each = 1000 connections
# Set maxclients to at least 1200 (20% headroom)
```

**Anti-pattern**: Opening a new connection per request without pooling. Each connection costs ~10 KB
of memory for buffers. 10,000 connections = ~100 MB just for connection overhead.

### 5.3 maxmemory-clients (Client Eviction)

**Default**: 0 (disabled)

Caps the aggregate memory used by all client connections. When exceeded, Valkey disconnects the
clients using the most memory first.

```
# Recommended for production: 5% of maxmemory
maxmemory-clients 5%

# Or an absolute value
maxmemory-clients 1gb
```

**Key behavior**:
- Replica and primary connections are exempt from client eviction
- Use `CLIENT NO-EVICT on` for critical control-plane connections (monitoring, alerting)
- Small performance impact under high load - disabled by default

### 5.4 timeout and tcp-keepalive

```
# Client idle timeout - default 0 (disabled)
# Set for environments where clients may leak connections
timeout 300

# TCP keepalive - default 300 seconds
# Detects dead peers and keeps NAT/firewall connections alive
tcp-keepalive 300
```

**Note**: `timeout` does NOT apply to Pub/Sub clients (idle is normal for subscribers).

### 5.5 tcp-backlog

**Default**: 511

The TCP listen backlog for new connections. In high connection-rate environments, raise this value.
The kernel silently caps it to `somaxconn`.

```bash
# Raise kernel limit first
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
```

```
# Then raise Valkey's backlog
tcp-backlog 65535
```

---

## 6. Threading and I/O

### 6.1 io-threads

**Default**: 1 (disabled - main thread only)

Enables multi-threaded I/O for socket reads, writes, and protocol parsing. The command execution
itself remains single-threaded.

**Sizing guidance**:

| CPU Cores | Recommended io-threads |
|-----------|----------------------|
| 1-2 | 1 (disabled) |
| 4 | 2-3 |
| 8 | 4-6 |
| 16+ | 6-8 (diminishing returns beyond 8) |

**When to enable**:
- Only if you have performance problems AND the instance is CPU-bound
- Only on machines with 3+ cores (leave at least 1 spare core)
- Benchmarks show up to 2x throughput improvement for I/O-bound workloads

**Benchmarking note**: When testing with `valkey-benchmark`, use `--threads` matching the server's
`io-threads` value. Otherwise the benchmark is client-bottlenecked and you won't see improvement.

**Deprecated**: `io-threads-do-reads` has no effect in current Valkey. Reads are always threaded
when `io-threads > 1`.

### 6.2 hz and dynamic-hz

```
# Background task frequency - default 10
hz 10

# Auto-adjust hz based on connected clients - default yes in recent versions
dynamic-hz yes
```

`hz` controls how often Valkey runs background tasks: active key expiry, client timeout checks,
active rehashing, active defragmentation, replication cron.

| hz | Background cycle | Use Case |
|----|-----------------|----------|
| 10 | Every 100ms (default) | General purpose |
| 50 | Every 20ms | Low-latency requirements, many expiring keys |
| 100 | Every 10ms | Ultra-low latency, high expiry churn |

**Anti-pattern**: Setting `hz 500` (max) - burns CPU on background tasks with negligible benefit.
Most users should not exceed 100.

**Interaction**: `dynamic-hz` multiplies the base `hz` by a factor proportional to connected clients.
Enabled by default. Leave it on unless you need deterministic background task scheduling.

---

## 7. Lazy Freeing

Starting from Valkey 8.0, lazy freeing is enabled by default for all operations.

### 7.1 Configuration Directives

```
lazyfree-lazy-eviction   yes    # Eviction frees memory in background thread
lazyfree-lazy-expire     yes    # Expired key cleanup in background
lazyfree-lazy-server-del yes    # Implicit deletes (RENAME, SET overwrite) in background
lazyfree-lazy-user-del   yes    # DEL command uses lazy freeing (like UNLINK)
lazyfree-lazy-user-flush yes    # FLUSHDB/FLUSHALL without flags use async
replica-lazy-flush       yes    # Replica flush during full resync is async
```

### 7.2 When to Disable Lazy Freeing

Almost never. The only scenario is when you need deterministic memory reclamation timing and can
tolerate the main-thread blocking. Example: hard real-time systems where background thread scheduling
is unpredictable.

**Performance impact of lazy freeing**:
- Deleting a key with 1M elements: blocking DEL takes hundreds of milliseconds; lazy freeing takes
  microseconds in the main thread + background cleanup
- Memory is reclaimed slightly later with lazy freeing, but the latency improvement is dramatic

---

## 8. Active Defragmentation

### 8.1 Overview

Active defragmentation compacts memory in-place at runtime, reducing fragmentation without restart.
Only works with Jemalloc (the default allocator on Linux).

### 8.2 Configuration

```
# Disabled by default - enable when fragmentation is observed
activedefrag no

# Start defrag when fragmentation waste exceeds this absolute amount
active-defrag-ignore-bytes 100mb

# Start defrag when fragmentation ratio exceeds this percentage
active-defrag-threshold-lower 10

# Use maximum effort when fragmentation exceeds this percentage
active-defrag-threshold-upper 100

# CPU percentage for defrag at lower threshold
active-defrag-cycle-min 1

# CPU percentage for defrag at upper threshold
active-defrag-cycle-max 25

# Max fields scanned per main dictionary scan step
active-defrag-max-scan-fields 1000

# Microseconds per defrag cycle - controls latency impact
active-defrag-cycle-us 500
```

### 8.3 Production Tuning

**Monitoring**: Check `mem_fragmentation_ratio` in `INFO memory`. Values above 1.5 indicate
significant fragmentation. Values below 1.0 indicate swap or measurement issues.

**Conservative production settings**:

```
activedefrag yes
active-defrag-ignore-bytes 200mb
active-defrag-threshold-lower 15
active-defrag-threshold-upper 100
active-defrag-cycle-min 1
active-defrag-cycle-max 15
active-defrag-cycle-us 300
```

**Aggressive settings (off-peak maintenance window)**:

```
# Apply temporarily via CONFIG SET, revert after fragmentation drops
activedefrag yes
active-defrag-cycle-min 10
active-defrag-cycle-max 50
active-defrag-cycle-us 1000
```

**Anti-pattern**: Enabling active defrag on instances compiled without Jemalloc - it simply won't
work and the configuration is silently ignored.

**Interaction**: `active-defrag-cycle-us` controls per-iteration latency. Lower values (100-300)
minimize latency spikes but slow down defrag progress. Higher values (500-1000) defrag faster but
may cause brief stalls.

---

## 9. Pub/Sub Configuration for High Throughput

### 9.1 Core Architecture

Valkey Pub/Sub is at-most-once delivery. Messages are not persisted. If a subscriber is disconnected
or slow, messages are lost. For guaranteed delivery, use Streams instead.

### 9.2 Configuration Knobs

**Client output buffers** (most critical):

```
# Default
client-output-buffer-limit pubsub 32mb 8mb 60

# High-throughput with tolerant subscribers
client-output-buffer-limit pubsub 128mb 32mb 120

# Low-latency with fast subscribers (tight limits to catch slow consumers early)
client-output-buffer-limit pubsub 16mb 4mb 30
```

**Sharded Pub/Sub** (Valkey 7.0+):

Sharded Pub/Sub (`SSUBSCRIBE`, `SPUBLISH`) restricts message propagation to the shard owning the
channel's hash slot. This dramatically reduces cluster bus traffic compared to global Pub/Sub.

```
# No special config needed - uses cluster's existing slot assignment
# Clients connect to the node owning the slot (or its replicas)
```

**Keyspace notifications**:

```
# Disabled by default - each enabled class adds overhead
notify-keyspace-events ""

# Enable only what you need
notify-keyspace-events "Kx"  # Keyspace events for expiry only
```

**Anti-pattern**: Enabling `notify-keyspace-events "AKE"` (all events) on a high-write instance -
generates a Pub/Sub message for every write operation, consuming significant CPU and memory.

### 9.3 Scaling Pub/Sub

- **Horizontal scaling**: Use sharded Pub/Sub in cluster mode to distribute load
- **Vertical scaling**: Raise `client-output-buffer-limit pubsub` and ensure `maxmemory-clients`
  accommodates subscriber buffers
- **Subscriber health**: Monitor `omem` (output buffer memory) in `CLIENT LIST` output to identify
  slow subscribers before they hit buffer limits

---

## 10. Persistence Tuning for Latency

### 10.1 AOF fsync Policies

```
appendfsync always     # Fsync after every write - safest, slowest
appendfsync everysec   # Fsync once per second - good compromise (default)
appendfsync no         # Let OS decide - fastest, risk of data loss
```

**Latency-sensitive recipe**:

```
appendfsync everysec
no-appendfsync-on-rewrite yes   # Skip fsync during AOF rewrite to reduce disk pressure
aof-rewrite-incremental-fsync yes  # Fsync every 4 MB during rewrite
rdb-save-incremental-fsync yes     # Fsync every 4 MB during RDB save
```

### 10.2 RDB Save Points

```
# Default: 3600/1, 300/100, 60/10000
# For pure cache (no persistence needed):
save ""

# For reduced persistence overhead:
save 3600 1
```

### 10.3 Fork Latency

BGSAVE and BGREWRITEAOF fork the process. Fork time is proportional to the page table size:

```
page_table_size = dataset_size / 4KB * 8 bytes
# Example: 24 GB dataset = 48 MB page table to copy
```

**Mitigation**:
- Disable Transparent Huge Pages: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`
- Use HVM instances on cloud (not PV)
- Monitor fork time: `INFO` field `latest_fork_usec`
- Enable `disable-thp yes` in valkey.conf (default)

---

## 11. OS-Level Tuning

### 11.1 Required Kernel Settings

```bash
# Overcommit memory - required for fork() to succeed
sysctl -w vm.overcommit_memory=1

# Disable Transparent Huge Pages
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# File descriptor limits
sysctl -w fs.file-max=100000
ulimit -Sn 100000

# TCP backlog
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
```

### 11.2 Swap Configuration

Always enable swap (equal to RAM size). Valkey should never actually swap, but if it does:
- The latency spike is detectable and actionable
- Without swap, the OOM killer terminates the process immediately with no warning

Monitor swapped pages: `cat /proc/<valkey_pid>/smaps | grep Swap`

### 11.3 OOM Score Tuning

```
oom-score-adj yes
oom-score-adj-values 0 200 800
# primary=0, replica=200, background child=800
# Background children (BGSAVE) are killed first
```

---

## 12. Workload-Specific Tuning Recipes

### 12.1 High-Throughput Cache

```
# Memory
maxmemory 25gb
maxmemory-policy allkeys-lfu
maxmemory-samples 10
maxmemory-eviction-tenacity 10
maxmemory-clients 5%

# LFU tuning
lfu-log-factor 10
lfu-decay-time 1

# Threading
io-threads 4

# Lazy freeing (all enabled by default in Valkey 8+)
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes

# No persistence
save ""
appendonly no

# Network
tcp-backlog 65535
maxclients 20000
timeout 60
tcp-keepalive 60

# Encoding - optimize for small objects
hash-max-listpack-entries 128
hash-max-listpack-value 64

# Background tasks
hz 10
dynamic-hz yes

# Defrag
activedefrag yes
active-defrag-ignore-bytes 200mb
active-defrag-threshold-lower 15
active-defrag-cycle-max 15
```

### 12.2 Session Store

```
# Memory
maxmemory 8gb
maxmemory-policy volatile-ttl
maxmemory-samples 5

# Persistence (sessions should survive restart)
appendonly yes
appendfsync everysec
no-appendfsync-on-rewrite yes
save 900 1

# Encoding - sessions are small hashes
hash-max-listpack-entries 128
hash-max-listpack-value 128

# Connections
maxclients 10000
timeout 0
tcp-keepalive 300

# Background
hz 10
active-expire-effort 3    # Sessions expire frequently, be moderately aggressive
```

### 12.3 Message Queue (Streams/Lists)

```
# Memory
maxmemory 16gb
maxmemory-policy noeviction    # Never lose queue data

# Persistence (critical for queues)
appendonly yes
appendfsync everysec
save 300 100 60 10000

# Stream encoding
stream-node-max-bytes 4096
stream-node-max-entries 100

# List encoding
list-max-listpack-size -2
list-compress-depth 0    # No compression - queues are LIFO/FIFO, all nodes accessed

# Connections
maxclients 5000
timeout 0

# Lazy freeing
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes

# Replication (queues need HA)
repl-backlog-size 256mb
client-output-buffer-limit replica 512mb 128mb 120
```

### 12.4 High-Throughput Pub/Sub Hub

```
# Memory
maxmemory 16gb
maxmemory-policy allkeys-lru
maxmemory-clients 10%

# Pub/Sub buffers - generous for high-throughput
client-output-buffer-limit pubsub 128mb 32mb 120
client-output-buffer-limit normal 0 0 0

# Threading
io-threads 4

# Network
maxclients 50000
tcp-backlog 65535
tcp-keepalive 60

# No persistence (Pub/Sub messages are ephemeral)
save ""
appendonly no

# Keyspace notifications - disable unless needed
notify-keyspace-events ""
```

---

## 13. Monitoring and Diagnostics

### 13.1 Key INFO Fields to Monitor

```
# Memory
used_memory / used_memory_rss / mem_fragmentation_ratio
used_memory_peak / maxmemory
mem_not_counted_for_evict
lazyfree_pending_objects / lazyfreed_objects

# Eviction
evicted_keys / total_eviction_exceeded_time
keyspace_hits / keyspace_misses    # Hit ratio = hits / (hits + misses)

# Clients
connected_clients / blocked_clients
client_recent_max_input_buffer / client_recent_max_output_buffer

# Persistence
rdb_last_bgsave_time_sec / latest_fork_usec
aof_last_rewrite_time_sec

# CPU
used_cpu_sys / used_cpu_user

# Defrag
active_defrag_running / active_defrag_hits / active_defrag_misses
```

### 13.2 Command Log (Slow Log)

```
# Log commands taking longer than 10ms (10000 microseconds)
commandlog-execution-slower-than 10000
commandlog-slow-execution-max-len 128

# Log large requests (>1 MB)
commandlog-request-larger-than 1048576
commandlog-large-request-max-len 128

# Log large replies (>1 MB) - has performance impact with io-threads
commandlog-reply-larger-than 1048576
commandlog-large-reply-max-len 128
```

### 13.3 Latency Monitoring

```
# Enable latency monitor when investigating issues
latency-monitor-threshold 10    # Log events taking >10ms

# Extended per-command latency tracking (enabled by default)
latency-tracking yes
latency-tracking-info-percentiles 50 99 99.9
```

### 13.4 Intrinsic Latency Baseline

Before tuning Valkey, measure the environment's baseline latency:

```bash
valkey-cli --intrinsic-latency 100
# Run on the SERVER, not the client
# Expected: <1ms on bare metal, <10ms on VMs
# If >10ms: noisy neighbors, hypervisor issues, or overloaded host
```

---

## 14. Common Anti-Patterns and Misconfigurations

| Anti-Pattern | Symptom | Fix |
|-------------|---------|-----|
| No `maxmemory` set | OOM killer terminates Valkey | Always set explicit `maxmemory` |
| `maxmemory` = total RAM | OOM during BGSAVE fork | Reserve 20-40% for OS, fork COW, buffers |
| `volatile-*` policy with no TTLs | Writes fail with OOM errors | Use `allkeys-*` or ensure all cache keys have TTLs |
| `KEYS *` in production | Server blocks for seconds | Use `SCAN` with `COUNT` hint |
| Transparent Huge Pages enabled | Latency spikes after fork | `echo never > /sys/.../transparent_hugepage/enabled` |
| Pub/Sub buffer limit = 0 | Slow subscriber consumes all RAM | Always set hard limits for pubsub |
| `io-threads` on 2-core machine | Higher latency, not lower | Only enable with 3+ cores |
| `hz 500` | Wastes CPU on background tasks | Use 10-100 max |
| `maxmemory-samples 64` | High CPU, no measurable hit ratio improvement over 10 | Use 5 (default) or 10 |
| `active-expire-effort 10` + millions of TTL keys | CPU spikes from expiry cycle | Start at 1, increase incrementally |
| `hash-max-listpack-entries 10000` | Slow HGET/HSET due to O(N) linear scan | Keep threshold at 128-512 |
| No `maxmemory-clients` | Client buffers evict data | Set to 5% for production |
| `lfu-decay-time 0` | Old popular keys never become eviction candidates | Use 1 (default) unless you have a specific reason |
| Not disabling `MONITOR` in production | Each MONITOR client receives all commands, huge buffer growth | Restrict via ACL |

---

## 15. Config Interaction Matrix

Key interactions between related configurations:

| Config A | Config B | Interaction |
|----------|----------|-------------|
| `maxmemory` | `maxmemory-policy` | Policy is only active when maxmemory is set |
| `maxmemory` | `maxmemory-clients` | Client eviction threshold is percentage of maxmemory |
| `maxmemory` | replication buffers | Buffers are excluded from eviction calculation |
| `maxmemory-policy` | TTL on keys | `volatile-*` policies only consider keys with TTL |
| `maxmemory-samples` | CPU usage | Higher samples = more CPU per eviction |
| `io-threads` | `commandlog-reply-larger-than` | Large reply logging adds overhead when io-threads enabled |
| `hz` | `active-expire-effort` | Higher hz = more frequent expiry cycles at given effort |
| `hz` | `activedefrag` | Defrag runs as part of the hz background cycle |
| `client-output-buffer-limit replica` | `repl-backlog-size` | Replica buffer limit must be >= backlog size |
| `lazyfree-lazy-*` | Memory reclamation | Lazy = less latency but delayed memory return |
| `active-defrag-cycle-us` | Latency | Higher value = more defrag progress but longer per-cycle stalls |
| `lfu-log-factor` | `lfu-decay-time` | Together control LFU counter sensitivity and adaptation speed |
| `appendfsync` | `no-appendfsync-on-rewrite` | Skip fsync during rewrite reduces disk pressure |
| `save` | `stop-writes-on-bgsave-error` | Failed BGSAVE blocks writes unless disabled |
