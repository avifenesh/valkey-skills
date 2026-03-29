# Valkey Performance Tuning and Benchmarking - Research Reference

> Research compiled from official Valkey documentation, blog posts, and community guides.
> Sources fetched: 2026-03-29. Covers Valkey 7.2 through 9.0.

---

## Table of Contents

1. [Version Performance Summary](#version-performance-summary)
2. [I/O Threading Architecture and Tuning](#io-threading-architecture-and-tuning)
3. [Memory Prefetch / Memory Access Amortization](#memory-prefetch--memory-access-amortization)
4. [Benchmarking Tools and Methodology](#benchmarking-tools-and-methodology)
5. [Memory Optimization](#memory-optimization)
6. [Active Defragmentation Tuning](#active-defragmentation-tuning)
7. [Latency Investigation and Monitoring](#latency-investigation-and-monitoring)
8. [Client-Side Caching (CLIENT TRACKING)](#client-side-caching-client-tracking)
9. [Eviction Policy Tuning](#eviction-policy-tuning)
10. [RDMA (Experimental)](#rdma-experimental)
11. [Valkey 9.0 Performance Features](#valkey-90-performance-features)
12. [Large Cluster Scaling (1 Billion RPS)](#large-cluster-scaling-1-billion-rps)
13. [System-Level Tuning](#system-level-tuning)
14. [Configuration Recipes](#configuration-recipes)

---

## Version Performance Summary

| Version | Key Performance Gains | Source |
|---------|----------------------|--------|
| **8.0** | 3x throughput (360K -> 1.19M RPS single shard), ~20% memory reduction in cluster mode, dual-channel replication, RDMA experimental | [Unlock 1M RPS](https://valkey.io/blog/unlock-one-million-rps/), [Memory Efficiency](https://valkey.io/blog/valkey-memory-efficiency-8-0/) |
| **8.1** | Multiple-primary failover fix (ranked election), reconnection storm throttling, optimized failure report tracking | [1 Billion RPS](https://valkey.io/blog/1-billion-rps/) |
| **9.0** | 1B+ RPS cluster (2000 nodes), pipeline memory prefetch (+40%), zero-copy responses (+20%), MPTCP (-25% latency), SIMD for BITCOUNT/HyperLogLog (+200%), atomic slot migrations | [Valkey 9.0 Announcement](https://valkey.io/blog/introducing-valkey-9/) |

---

## I/O Threading Architecture and Tuning

### How It Works (Valkey 8.0+)

I/O threads are worker threads that receive jobs from the main thread. Jobs include:
- Reading and parsing commands from clients
- Writing responses back to clients
- Polling for I/O events on TCP connections (`epoll_wait`)
- Deallocating memory

The main thread orchestrates all jobs, ensuring no race conditions. Command execution remains single-threaded. The number of active I/O threads adjusts dynamically based on load.

Key architectural detail: `epoll_wait` consumes >20% of main thread time when single-threaded. I/O threads offload `epoll_wait` - at most one thread executes it at any time. Thread affinity is maintained so the same I/O thread handles I/O for the same client when possible.

Source: [Unlock 1M RPS](https://valkey.io/blog/unlock-one-million-rps/)

### Configuration

```
# io-threads N
# N includes only I/O threads (main thread is separate in the count for --io-threads CLI flag)
# NOTE: In valkey.conf, io-threads count does NOT include main thread
# But in --io-threads CLI flag, count INCLUDES the main thread
# Example: --io-threads 9 means 8 I/O threads + 1 main thread

io-threads 4    # Default (disabled by default in config, set to 1)

# The deprecated io-threads-do-reads config has no effect in Valkey 8+
# Reads are always threaded when io-threads > 1
```

### Thread Count Recommendations by Core Count

| Available Cores | Recommended io-threads | Notes |
|-----------------|----------------------|-------|
| 4 | 2 | Leave cores for main thread + OS. Over-subscribing hurts performance. |
| 8 | 5-6 | Reserve 2 cores for IRQ affinity, main thread gets 1, rest for I/O |
| 16 | 8-9 | Best tested config: 8 I/O threads + main thread on c7g.4xlarge (16 cores) |
| 64 (c7g.16xlarge) | 6 (cluster 1B RPS setup) | 2 cores for IRQ, 6 for valkey-server (io-threads 6 includes main thread in their config) |

**Critical rule**: Never set io-threads >= number of available cores. Over-subscribing CPU causes performance degradation.

Source: [Testing the Limits](https://valkey.io/blog/testing-the-limits/) - a 4-core Raspberry Pi CM4 saw performance DROP from 416K to 336K RPS when io-threads was set to 5 (exceeding core count), but recovered to 565K RPS with io-threads=2.

### Benchmark Numbers: I/O Threading Impact

**AWS EC2 c7g.4xlarge (16 cores ARM/aarch64)** - Single shard SET benchmark:

| Configuration | Throughput (SET RPS) | Avg Latency | p50 Latency |
|--------------|---------------------|-------------|-------------|
| Valkey 7.2 (baseline) | 360,000 | 1.792 ms | - |
| Valkey 8.0 (8 I/O threads + prefetch) | 1,190,000 | 0.542 ms | - |
| **Improvement** | **+230%** | **-69.8%** | - |

Test conditions: 8 I/O threads, 3M keys, 512-byte values, 650 clients, sequential SET commands.

**Raspberry Pi CM4 (4 cores ARM, overclocked 2.2GHz)** - Pipeline=16 benchmark:

| Configuration | SET RPS | GET RPS | Combined Avg |
|--------------|---------|---------|--------------|
| Single-thread (1.5GHz) | 173,040 | 307,031 | 240,000 |
| Single-thread (2.2GHz OC) | 394,368 | 438,058 | 416,000 |
| io-threads=5 (OVER-SUBSCRIBED) | 345,494 | 327,858 | 336,000 |
| io-threads=2 | 609,050 | 521,186 | 565,000 |
| io-threads=2 + prefetch | 632,791 | 888,573 | 760,000 |

Source: [Testing the Limits](https://valkey.io/blog/testing-the-limits/)

---

## Memory Prefetch / Memory Access Amortization

### The Problem

When profiling the main thread after I/O threading optimization, >40% of time was spent in `lookupKey` - the dictionary lookup function. On large key sets, almost every memory address accessed during dictionary traversal is a cache miss, requiring expensive external memory access (~50x slower than L1 cache). Despite showing 100% CPU utilization, the main thread was mostly "waiting" for memory.

### The Solution

Before executing a batch of commands from I/O threads, the main thread prefetches memory addresses needed for future `lookupKey` invocations. This is achieved by `dictPrefetch` which interleaves the `table->dictEntry->...dictEntry->robj` search sequences for all keys in the batch.

- Reduces time in `lookupKey` by >80%
- Overall impact on throughput: ~50% improvement
- Throughput went from 780K RPS (I/O threads only) to 1.19M RPS (I/O threads + prefetch)

Implementation: `memory_prefetch.c` in the Valkey source.

### Valkey 9.0: Pipeline Memory Prefetch

Valkey 9.0 extends the prefetch technique to pipelined commands, yielding up to 40% higher throughput for pipelined workloads.

Source: [Unlock 1M RPS Part 2](https://valkey.io/blog/unlock-one-million-rps-part2/), [Valkey 9.0](https://valkey.io/blog/introducing-valkey-9/)

---

## Benchmarking Tools and Methodology

### valkey-benchmark

Built-in benchmarking tool. Functionally equivalent to redis-benchmark.

```bash
# Basic throughput test
valkey-benchmark -t set,get -n 1000000 -d 512 -c 50

# With pipelining (16 commands per request)
valkey-benchmark -t set,get -n 1000000 -P 16 -q

# Multi-threaded benchmark (MUST match server io-threads)
valkey-benchmark -t set -d 512 -r 3000000 -c 650 --threads 50 \
  -h "host-name" -n 100000000000

# Cluster benchmark
valkey-benchmark -n 10000000 -t set,get -P 16 -q --cluster \
  --threads 5 -a <password> -h <host>

# With authentication
valkey-benchmark -n 1000000 -t set,get -P 16 -q \
  -a <password> --threads 5 -h <host>

# Memory efficiency test (small values, many keys)
valkey-benchmark -t set -n 10000000 -r 10000000 -d 16
```

Key flags:
- `-n`: Total number of requests
- `-t`: Tests to run (set, get, incr, lpush, rpush, lpop, rpop, sadd, hset, etc.)
- `-P`: Pipeline N commands per request
- `-c`: Number of concurrent connections
- `-d`: Data size in bytes for SET/GET values
- `-r`: Use random keys from keyspace of this size
- `--threads`: Client-side threads for generating load
- `--cluster`: Enable cluster mode routing
- `-q`: Quiet mode (summary only)

### memtier_benchmark

Community tool from Redis Ltd, also works with Valkey. Provides more detailed latency histograms.

```bash
# Basic test
memtier_benchmark -s <host> -p 6379 --threads=4 --clients=50 \
  --requests=100000 --data-size=512

# With key pattern and ratio
memtier_benchmark -s <host> -p 6379 --threads=4 --clients=50 \
  --ratio=1:10 --key-pattern=G:G --key-minimum=1 --key-maximum=1000000

# Latency-focused test
memtier_benchmark -s <host> -p 6379 --threads=2 --clients=100 \
  --test-time=60 --ratio=1:1 --data-size=256 --print-percentiles
```

### Benchmark Best Practices

1. **Run benchmark from a separate machine** - never on the same host as the server
2. **Warm up the database first** - let the benchmark run long enough for performance to stabilize (several seconds minimum)
3. **Match client threads to server io-threads** for optimal load generation
4. **Use pipeline mode** (`-P 16` or higher) to saturate the server
5. **Test with realistic data sizes** - 512 bytes is a common reference point
6. **Monitor server-side** during benchmarks: `INFO stats`, `INFO memory`, CPU utilization
7. **Pin the main thread** to a specific CPU core for reproducible results

### Reproducing 1.19M RPS (Official Method)

Hardware: AWS EC2 c7g.4xlarge (16 cores ARM/aarch64)

```bash
# 1. Set IRQ affinity (2 cores for network interrupts)
# Find IRQs for eth0
grep eth0 /proc/interrupts | awk '{print $1}' | cut -d: -f1
# Pin IRQs 48-51 to core 12, IRQs 52-55 to core 13
for i in {48..51}; do echo 1000 > /proc/irq/$i/smp_affinity; done
for i in {52..55}; do echo 2000 > /proc/irq/$i/smp_affinity; done

# 2. Start server with 9 threads (8 I/O + 1 main)
./valkey-server --io-threads 9 --save "" --protected-mode no

# 3. Pin main thread to core 3 (avoid IRQ cores)
sudo taskset -cp 3 $(pidof valkey-server)

# 4. Run benchmark from separate instance
./valkey-benchmark -t set -d 512 -r 3000000 -c 650 \
  --threads 50 -h "host-name" -n 100000000000
```

Source: [Unlock 1M RPS Part 2](https://valkey.io/blog/unlock-one-million-rps-part2/)

---

## Memory Optimization

### Valkey 8.0 Cluster Mode Memory Improvements

Two optimizations that require NO configuration changes:

**Optimization 1 - Dictionary Per Slot**

Valkey 7.2 used a single global dictionary with slot-prev/slot-next pointers (16 bytes per entry) for slot-to-key mapping. Valkey 8.0 uses 16,384 per-slot dictionaries instead.

- Saves 16 bytes per key
- ~1 MB overhead for the slot index (Fenwick tree)
- Rehashing impact is localized to individual slot dictionaries

**Optimization 2 - Key Embedding into Dictionary Entry**

Keys are now embedded directly into dictionary entries instead of using a separate SDS pointer.

- Saves 8 bytes per key
- Eliminates one random pointer dereference per lookup (better cache locality)

**Measured Savings (6.3M keys, 16-byte values):**

| Version | Memory Used | Savings |
|---------|------------|---------|
| Valkey 7.2 | 693.64 MB | baseline |
| + Dict per slot | 598.77 MB | -13.68% |
| + Key embedding (Valkey 8.0) | 550.56 MB | -20.63% total |

Source: [Memory Efficiency in Valkey 8](https://valkey.io/blog/valkey-memory-efficiency-8-0/)

### Listpack Encoding Thresholds

Small aggregate types use compact encoding (up to 10x less memory, 5x average). Configure thresholds:

```
# Hash - default 512 entries, 64 byte max value
hash-max-listpack-entries 512
hash-max-listpack-value 64

# Sorted Set - default 128 entries, 64 byte max value
zset-max-listpack-entries 128
zset-max-listpack-value 64

# Set - integer sets up to 512, listpack up to 128
set-max-intset-entries 512
set-max-listpack-entries 128
set-max-listpack-value 64
```

Exceeding these thresholds causes automatic conversion to normal encoding. Raising thresholds increases memory efficiency but increases CPU for operations. Benchmark before increasing significantly.

### Hash-Based Key Sharding Pattern

Instead of storing millions of top-level keys, group related keys into hashes:

```
# Instead of: SET object:1234 value
# Use: HSET object:12 34 value

# Each hash holds ~100 fields
# Hashes below the listpack threshold use compact encoding
# Much more memory-efficient than individual keys
```

This pattern can use 10x less memory than individual keys for small values.

### Memory Allocation Behavior

- Valkey does NOT always return freed memory to the OS (normal malloc behavior)
- After filling 5GB and deleting 2GB, RSS may still show ~5GB
- Provision based on **peak memory usage**, not average
- The allocator reuses freed chunks when new data is added
- Fragmentation ratio (RSS / used_memory) is unreliable after significant key deletion
- Always set `maxmemory` - without it, Valkey will consume all available memory

### maxmemory with Replication

When replication is configured, set maxmemory 10-20% lower than total available:
- Replication and AOF buffers are NOT counted against maxmemory
- Monitor `mem_not_counted_for_evict` in `INFO memory`
- Rule of thumb: if you have 10 GB free, set maxmemory to 8-9 GB

Source: [Memory Optimization](https://valkey.io/topics/memory-optimization/), [LRU Cache](https://valkey.io/topics/lru-cache/)

---

## Active Defragmentation Tuning

### Configuration Parameters

```
# Enable active defragmentation (disabled by default)
activedefrag no

# Minimum absolute fragmentation waste to trigger defrag
active-defrag-ignore-bytes 100mb

# Minimum fragmentation percentage to start defrag
active-defrag-threshold-lower 10

# Fragmentation percentage at which maximum effort is used
active-defrag-threshold-upper 100

# Minimum CPU effort percentage (at lower threshold)
active-defrag-cycle-min 1

# Maximum CPU effort percentage (at upper threshold)
active-defrag-cycle-max 25
```

### Tuning Guide

**Conservative (latency-sensitive workloads):**
```
activedefrag yes
active-defrag-ignore-bytes 200mb
active-defrag-threshold-lower 15
active-defrag-threshold-upper 100
active-defrag-cycle-min 1
active-defrag-cycle-max 10
```

**Aggressive (memory-constrained, latency-tolerant):**
```
activedefrag yes
active-defrag-ignore-bytes 50mb
active-defrag-threshold-lower 5
active-defrag-threshold-upper 50
active-defrag-cycle-min 5
active-defrag-cycle-max 50
```

### Monitoring Defragmentation

```bash
# Check fragmentation ratio
INFO memory
# Look for: mem_fragmentation_ratio
# Healthy: 1.0 - 1.5
# Concerning: > 1.5
# Critical: > 2.0

# Check defrag stats
INFO stats
# Look for: active_defrag_hits, active_defrag_misses, active_defrag_key_hits
```

The latency monitor tracks `active-defrag-cycle` events for diagnosing defrag-induced latency.

Source: [Valkey default config](https://github.com/valkey-io/valkey/blob/unstable/valkey.conf), [Latency Monitor](https://valkey.io/topics/latency-monitor/)

---

## Latency Investigation and Monitoring

### Quick Checklist

1. Check for slow commands blocking the server (`SLOWLOG GET`)
2. EC2: use HVM-based modern instances (m3.medium or newer) - fork() is too slow on older types
3. Disable Transparent Huge Pages: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`
4. Measure intrinsic latency: `valkey-cli --intrinsic-latency 100` (run ON the server)
5. Enable latency monitoring: `CONFIG SET latency-monitor-threshold 100`

Source: [Latency Diagnosis](https://valkey.io/topics/latency/)

### Measuring Baseline Latency

```bash
# Intrinsic latency test (run on the SERVER, not client)
# Measures OS/hypervisor scheduling latency - your floor
./valkey-cli --intrinsic-latency 100

# Good result (bare metal):
# Max latency so far: 115 microseconds  (0.115 ms)

# Bad result (noisy VM):
# Max latency so far: 9671 microseconds  (9.7 ms)
# Can see up to 40ms in loaded VMs

# Continuous latency monitoring
valkey-cli --latency -h <host> -p <port>
```

### Network Latency Reference

| Connection Type | Typical Latency |
|----------------|----------------|
| 1 Gbit/s network | ~200 us |
| Unix domain socket | ~30 us |
| Loopback (localhost) | ~50-100 us |

### Latency Monitor

```bash
# Enable with threshold (milliseconds)
CONFIG SET latency-monitor-threshold 100

# View latest spikes for all events
LATENCY LATEST

# View history for specific event
LATENCY HISTORY command

# ASCII graph of latency
LATENCY GRAPH command

# Human-readable diagnosis
LATENCY DOCTOR

# Reset data
LATENCY RESET
```

Monitored events:
- `command` - regular command execution
- `fast-command` - O(1) and O(log N) commands
- `fork` - fork(2) system call
- `aof-fsync-always` - fsync when appendfsync=always
- `aof-write` - write(2) to AOF
- `active-defrag-cycle` - defrag cycle
- `expire-cycle` - key expiration cycle
- `eviction-cycle` - memory eviction cycle
- `eviction-del` - deletes during eviction

### Latency Tracking (Per-Command Percentiles)

```
# Enable per-command latency tracking
latency-tracking yes

# Configure exported percentiles (default: p50, p99, p99.9)
latency-tracking-info-percentiles 50 99 99.9

# View via INFO
INFO latencystats
```

### Common Latency Sources

| Source | Typical Impact | Mitigation |
|--------|---------------|------------|
| Slow commands (KEYS, SORT, SUNION on large sets) | 10-1000ms+ | Use SCAN instead of KEYS; avoid O(N) on large collections |
| fork() for BGSAVE/BGREWRITEAOF | Proportional to memory (48MB page table for 24GB instance) | Schedule during low-traffic; use `latency-monitor-threshold` |
| Transparent Huge Pages | Random 2ms+ spikes | `echo never > /sys/kernel/mm/transparent_hugepage/enabled` |
| AOF fsync | 1-25ms per fsync | Use `appendfsync everysec` instead of `always` |
| Swapping | 10-1000ms+ | Ensure adequate RAM; set `maxmemory` |
| Key expiration | Depends on expired key volume | Valkey limits to 25% of cycle time |

### Persistence Latency/Durability Tradeoffs (ordered strong->fast)

1. `AOF + fsync always` - very slow, strongest durability
2. `AOF + fsync every second` - good compromise
3. `AOF + fsync every second + no-appendfsync-on-rewrite yes` - less disk pressure during rewrites
4. `AOF + fsync never` - kernel decides when to fsync
5. `RDB` - periodic snapshots, configurable triggers

### Fork Latency by Memory Size

Fork copies the page table. For a 24 GB instance:
- Page table size: 24 GB / 4 KB * 8 = 48 MB
- Fork must allocate and copy this 48 MB
- More expensive on VMs where memory allocation is slower

Source: [Latency Diagnosis](https://valkey.io/topics/latency/), [Latency Monitor](https://valkey.io/topics/latency-monitor/)

---

## Client-Side Caching (CLIENT TRACKING)

### Overview

Server-assisted client-side caching. Two modes:

1. **Default (Tracking) mode**: Server remembers which keys each client accessed, sends invalidation only for those keys. Costs server memory.
2. **Broadcasting (BCAST) mode**: Clients subscribe to key prefixes, receive all invalidations matching those prefixes. Zero server memory cost but more messages.

### Protocol Support

- **RESP3**: Single connection - data and invalidation messages multiplexed
- **RESP2**: Two connections required - one for data, one for invalidation via Pub/Sub on `__redis__:invalidate` channel

### Setup Examples

**RESP3 (single connection):**
```
CLIENT TRACKING ON
GET foo
# Server remembers client may have "foo" cached
# When "foo" is modified, server sends: INVALIDATE "foo"
```

**RESP2 (two connections):**
```
# Connection 1 (invalidation listener):
CLIENT ID
# Returns :4
SUBSCRIBE __redis__:invalidate

# Connection 2 (data):
CLIENT TRACKING ON REDIRECT 4
GET foo
# "bar"

# When another client does SET foo newvalue:
# Connection 1 receives invalidation for "foo"
```

**Broadcasting mode with prefixes:**
```
CLIENT TRACKING ON REDIRECT 10 BCAST PREFIX object: PREFIX user:
# Receives invalidation for any key starting with object: or user:
```

**Opt-in mode:**
```
CLIENT TRACKING ON OPTIN
# Only cache keys explicitly marked:
CLIENT CACHING YES
GET foo
```

### Invalidation Table

- Global table with configurable max entries
- When full, server evicts older entries by sending "phantom" invalidation messages
- Stores client IDs (not pointers) - garbage collected incrementally on disconnect
- Single key namespace across all databases

### Performance Impact

- Reduces Valkey queries dramatically for read-heavy workloads with key locality
- Local memory access is orders of magnitude faster than network round-trip
- Most beneficial when a small percentage of keys are accessed frequently (power-law distribution)
- Particularly effective for immutable or rarely-changed data (user profiles, posts)

### NOLOOP Option

```
CLIENT TRACKING ON NOLOOP
# Prevents receiving invalidation messages for keys modified by this client itself
```

Source: [Client-Side Caching](https://valkey.io/topics/client-side-caching/)

---

## Eviction Policy Tuning

### Available Policies

| Policy | Description |
|--------|-------------|
| `noeviction` | Return errors on writes when memory limit reached |
| `allkeys-lru` | Evict least recently used keys (recommended default for caches) |
| `allkeys-lfu` | Evict least frequently used keys |
| `volatile-lru` | LRU eviction only for keys with TTL set |
| `volatile-lfu` | LFU eviction only for keys with TTL set |
| `allkeys-random` | Random eviction from all keys |
| `volatile-random` | Random eviction from keys with TTL |
| `volatile-ttl` | Evict keys with shortest remaining TTL first |

### LRU Approximation Tuning

```
# Number of keys sampled per eviction cycle (default: 5)
# Higher = more accurate but more CPU
maxmemory-samples 5

# At 10 samples, approximation is very close to true LRU
# At 5 samples, good enough for most workloads
```

### Choosing a Policy

- **`allkeys-lru`**: Best for power-law access patterns (most common). More memory-efficient than volatile policies since no TTL storage needed.
- **`allkeys-lfu`**: Better when access frequency matters more than recency
- **`allkeys-random`**: For uniform/cyclic access patterns
- **`volatile-ttl`**: When you control TTL hints on cache objects

### Monitoring Eviction

```bash
INFO memory
# used_memory, maxmemory, mem_not_counted_for_evict

INFO stats
# total_eviction_exceeded_time (ms that used_memory exceeded maxmemory)
# evicted_keys (total keys evicted)
```

Eviction triggers when: `used_memory - mem_not_counted_for_evict > maxmemory`

Source: [LRU Cache](https://valkey.io/topics/lru-cache/)

---

## RDMA (Experimental)

### Overview

Valkey Over RDMA was introduced as experimental in Valkey 8.0. Enables direct memory access between clients and server, bypassing kernel networking stack.

### Performance Claims

- Up to **275% increase in throughput** compared to TCP
- Significantly lower latency due to kernel bypass

### Status

- Experimental in Valkey 8.0, may change or be removed
- Requires RDMA-capable NICs (InfiniBand, RoCE)
- See PR [#477](https://github.com/valkey-io/valkey/issues/477) for implementation details

Source: [Valkey 8.0 RC1](https://valkey.io/blog/valkey-8-0-0-rc1/)

---

## Valkey 9.0 Performance Features

### Pipeline Memory Prefetch
- Extends the Valkey 8.0 memory access amortization to pipelined commands
- Up to **40% higher throughput** for pipelined workloads

### Zero-Copy Responses
- Large responses avoid internal memory copying
- Up to **20% higher throughput** for large value reads

### Multipath TCP (MPTCP)
- Splits TCP connection into subflows over multiple interfaces/paths
- Up to **25% latency reduction**
- Requires Linux kernel 5.6+
- Configuration: `mptcp yes`

### SIMD Optimizations
- SIMD instructions for BITCOUNT and HyperLogLog commands
- Up to **200% higher throughput** for these specific commands

### Atomic Slot Migrations
- Migrates entire slots atomically instead of key-by-key
- Prevents large-key migration blocking
- Eliminates mini-outages during migration for multi-key operations
- Uses AOF format for streaming individual collection items

### Hash Field Expiration
- New commands: HEXPIRE, HEXPIREAT, HGETEX, HPERSIST, HSETEX, HTTL, etc.
- Individual field-level TTLs instead of all-or-nothing key expiry
- Reduces need for workaround patterns with multiple keys

### Numbered Databases in Cluster Mode
- Full support for numbered databases (SELECT) in cluster mode
- Previously restricted to db 0 only

Source: [Valkey 9.0 Announcement](https://valkey.io/blog/introducing-valkey-9/)

---

## Large Cluster Scaling (1 Billion RPS)

### Architecture

- Valkey 9.0 cluster scaled to **2,000 nodes** (1,000 primary + 1,000 replica shards)
- Achieved **>1 billion RPS** for SET commands
- Throughput scales nearly linearly with primary count

### Hardware Configuration

| Component | Spec |
|-----------|------|
| Server instances | AWS r7g.2xlarge (8 cores, 64 GB, ARM/aarch64) |
| Client instances | 750x AWS c7g.16xlarge |
| Total nodes | 2,000 (1,000 primaries + 1,000 replicas) |

### Server Configuration (Per Node)

```bash
# System: Pin 2 cores for network IRQ
IFACE=$(ip route | awk '/default/ {print $5; exit}')
sudo ethtool -L "$IFACE" combined 2
# Pin IRQs to CPU 0 and 1
echo 0 | sudo tee /proc/irq/$IRQ0/smp_affinity_list
echo 1 | sudo tee /proc/irq/$IRQ1/smp_affinity_list
sudo systemctl stop irqbalance

# Increase file descriptors
ulimit -n 1048544

# Pin remaining 6 cores to valkey-server
CPUSET=2-7
sudo cset shield --cpu=$CPUSET --kthread=on
sudo cset shield --exec taskset -- -c $CPUSET \
  ./valkey-server valkey-cluster.conf --daemonize yes
```

```
# valkey-cluster.conf
cluster-enabled yes
cluster-config-file nodes.conf
cluster-require-full-coverage no
cluster-allow-reads-when-down yes
save ""
io-threads 6
maxmemory 50gb
```

### Benchmark Parameters (Per Client Instance)

```bash
valkey-benchmark -n 100000000 -c 1000 -t SET -d 512 --threads 20
```

### Cluster Improvements Enabling Scale

1. **Ranked failover elections** (Valkey 8.1): Prevents vote collision during multi-primary failure by ranking shards lexicographically
2. **Reconnection throttling**: Prevents reconnect storms to failed nodes (was every 100ms per node)
3. **Optimized failure reports**: Radix tree storage for failure reports, grouped by second
4. **Lightweight pub/sub headers**: Reduced cluster bus overhead from ~2KB to ~30 bytes for pub/sub messages

### Recovery Time

Tested killing up to 50% of primaries (500 nodes). Recovery measured from first PFAIL detection to cluster reporting OK with all slots covered. Bounded recovery time achieved through ranked failover mechanism.

Source: [1 Billion RPS](https://valkey.io/blog/1-billion-rps/)

---

## System-Level Tuning

### Kernel Parameters

```bash
# Disable Transparent Huge Pages (CRITICAL - causes latency spikes)
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# Enable memory overcommit (required for fork/BGSAVE)
sysctl vm.overcommit_memory=1
# Or permanently: add to /etc/sysctl.conf

# Increase max connections
sysctl net.core.somaxconn=65535

# Increase file descriptor limit
ulimit -n 1048544
```

### TCP Backlog

```
# Default 511 - increase for high-connection-count scenarios
tcp-backlog 511
```

Note: Linux kernel caps this at `net.core.somaxconn`.

### CPU Pinning and IRQ Affinity

```bash
# Pin Valkey main thread to a specific core
sudo taskset -cp <CORE> $(pidof valkey-server)

# Use cset for isolating cores
sudo cset shield --cpu=2-7 --kthread=on
sudo cset shield --exec taskset -- -c 2-7 ./valkey-server ...

# Pin network IRQs to dedicated cores (not shared with Valkey)
echo <CPU_MASK> > /proc/irq/<IRQ_NUM>/smp_affinity
sudo systemctl stop irqbalance
```

### hz (Server Timer Frequency)

```
# Default: 10 (calls per second for background tasks)
# Higher = more responsive expiration/eviction but more CPU
# Maximum recommended: 100 (only for ultra-low-latency requirements)
hz 10
```

### Swap Configuration

- Enable swap equal to system memory
- Without swap: OOM killer may terminate Valkey
- With swap: latency spikes are detectable and actionable
- Swapping itself causes severe latency - swap is a safety net, not a feature

### Memory Provisioning Rule

> Set `maxmemory` based on peak usage minus overhead.
> If you think you have 10 GB free, set maxmemory to 8 or 9 GB.
> Account for: replication buffers, AOF buffers, fragmentation, OS overhead.

### Lazy Freeing

```
# Offload expensive delete operations to background threads
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
replica-lazy-flush yes
lazyfree-lazy-user-del yes
lazyfree-lazy-user-flush yes
```

Source: [Valkey Admin](https://valkey.io/topics/admin/), [Latency Diagnosis](https://valkey.io/topics/latency/)

---

## Configuration Recipes

### Recipe: High-Throughput Single Shard (16-core machine)

```
# Server config
io-threads 8
save ""
maxmemory <80% of available RAM>
hz 10
tcp-backlog 4096
activedefrag yes
active-defrag-cycle-min 1
active-defrag-cycle-max 15
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes

# System tuning
# echo never > /sys/kernel/mm/transparent_hugepage/enabled
# sysctl vm.overcommit_memory=1
# Pin 2 cores for IRQ, 1 for main thread, rest for I/O
# taskset -cp <core> $(pidof valkey-server)
```

Expected: ~1M+ RPS for SET/GET with 512-byte values on ARM (c7g.4xlarge equivalent).

### Recipe: Low-Latency Cache (latency-sensitive application)

```
# Server config
io-threads 4
maxmemory <70% of available RAM>
maxmemory-policy allkeys-lfu
hz 50
latency-monitor-threshold 10
latency-tracking yes
latency-tracking-info-percentiles 50 95 99 99.9
save ""
appendonly no
activedefrag yes
active-defrag-cycle-min 1
active-defrag-cycle-max 10
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes

# Target percentiles:
# p50 < 0.5ms, p99 < 2ms, p99.9 < 5ms (local network)
```

### Recipe: Persistent Storage (durability required)

```
# Server config
io-threads 4
maxmemory <60% of available RAM>
appendonly yes
appendfsync everysec
no-appendfsync-on-rewrite yes
aof-rewrite-incremental-fsync yes
rdb-save-incremental-fsync yes
save 900 1 300 10 60 10000
hz 10
activedefrag yes
active-defrag-cycle-min 1
active-defrag-cycle-max 15
```

### Recipe: Memory-Optimized (maximum key density)

```
# Maximize listpack encoding
hash-max-listpack-entries 512
hash-max-listpack-value 64
zset-max-listpack-entries 128
zset-max-listpack-value 64
set-max-intset-entries 512
set-max-listpack-entries 128

# Use hash-based key sharding for small values
# Group keys into hashes of ~100 fields each

# Enable defrag to combat fragmentation
activedefrag yes
active-defrag-ignore-bytes 50mb
active-defrag-threshold-lower 5

# Use allkeys-lru (no TTL overhead)
maxmemory-policy allkeys-lru
```

### Recipe: Large Cluster (scaling to 1000+ nodes)

```
# Per-node config
cluster-enabled yes
cluster-config-file nodes.conf
cluster-require-full-coverage no
cluster-allow-reads-when-down yes
save ""
io-threads 6
maxmemory 50gb
cluster-node-timeout 15000

# System config per node
# 2 cores for IRQ, remaining for valkey-server
# ulimit -n 1048544
# Pin cores with cset shield
```

---

## Latency Percentile Targets by Use Case

| Use Case | p50 | p99 | p99.9 | Notes |
|----------|-----|-----|-------|-------|
| Real-time gaming/trading | < 0.2ms | < 1ms | < 2ms | Requires Unix socket or RDMA, single-instance |
| Session cache / API cache | < 0.5ms | < 2ms | < 5ms | Standard network, io-threads enabled |
| General application cache | < 1ms | < 5ms | < 10ms | Includes cluster routing overhead |
| Analytics / batch processing | < 5ms | < 20ms | < 50ms | Can tolerate persistence overhead |
| Background job queues | < 10ms | < 50ms | < 200ms | List/Stream operations, persistence enabled |

---

## Key Sources

| Source | URL |
|--------|-----|
| Unlock 1M RPS (Part 1 - I/O Threading) | https://valkey.io/blog/unlock-one-million-rps/ |
| Unlock 1M RPS (Part 2 - Memory Prefetch) | https://valkey.io/blog/unlock-one-million-rps-part2/ |
| Memory Efficiency in Valkey 8 | https://valkey.io/blog/valkey-memory-efficiency-8-0/ |
| Valkey 8.0 RC1 Announcement | https://valkey.io/blog/valkey-8-0-0-rc1/ |
| Valkey 9.0 Announcement | https://valkey.io/blog/introducing-valkey-9/ |
| 1 Billion RPS (Large Clusters) | https://valkey.io/blog/1-billion-rps/ |
| Testing the Limits (Raspberry Pi) | https://valkey.io/blog/testing-the-limits/ |
| Latency Diagnosis | https://valkey.io/topics/latency/ |
| Latency Monitor | https://valkey.io/topics/latency-monitor/ |
| Memory Optimization | https://valkey.io/topics/memory-optimization/ |
| Using Valkey as LRU Cache | https://valkey.io/topics/lru-cache/ |
| Client-Side Caching | https://valkey.io/topics/client-side-caching/ |
| Valkey Admin Guide | https://valkey.io/topics/admin/ |
| Valkey Default Config | https://github.com/valkey-io/valkey/blob/unstable/valkey.conf |
