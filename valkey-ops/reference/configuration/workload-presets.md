# Configuration Presets by Workload

Use when configuring Valkey for a specific use case. Each preset lists the parameters to set and why. Defaults verified against `src/config.c`.

---

## Cache-Only (Volatile Data)

Data is expendable. Speed and memory efficiency matter. No persistence needed.

```
# Memory
maxmemory <80% of available RAM>
maxmemory-policy allkeys-lru
maxmemory-samples 5

# Disable all persistence
save ""
appendonly no

# Performance
io-threads 4
tcp-keepalive 300
timeout 300

# Logging
loglevel notice
```

### Why These Settings

| Parameter | Rationale |
|-----------|-----------|
| `maxmemory` 80% of RAM | Leave headroom for OS, client buffers, and temporary spikes. |
| `allkeys-lru` | Automatically evict least-recently-used keys. Best general-purpose cache policy. |
| `save ""` | Disables RDB snapshots. No persistence overhead, no fork latency spikes. |
| `appendonly no` | Disables AOF. No fsync overhead. |
| `io-threads 4` | Offload read/write I/O to threads. Adjust based on CPU cores (2-8 typical). |
| `timeout 300` | Disconnect idle clients after 5 minutes. Prevents connection leaks. |

### When to Use allkeys-lfu Instead

Switch to `allkeys-lfu` if your access pattern has clear popularity tiers - a small set of hot keys accounts for most requests. LFU keeps popular keys longer than LRU would.

```
maxmemory-policy allkeys-lfu
lfu-log-factor 10
lfu-decay-time 1
```


## Primary Data Store (Durability Required)

Data must survive restarts. Write acknowledgment must mean the data is safe.

```
# Memory
maxmemory <60-70% of available RAM>
maxmemory-policy noeviction

# AOF persistence (primary mechanism)
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# RDB snapshots (backup + faster restart)
save 3600 1 300 100 60 10000
rdbcompression yes
rdbchecksum yes

# Safety
stop-writes-on-bgsave-error yes

# Performance
io-threads 4
```

### Why These Settings

| Parameter | Rationale |
|-----------|-----------|
| `maxmemory` 60-70% of RAM | Fork operations (BGSAVE, BGREWRITEAOF) need copy-on-write headroom. |
| `noeviction` | Never silently remove data. Application gets OOM error and can handle it. |
| `appendfsync everysec` | Fsync once per second. At most 1 second of data loss on crash. |
| `aof-use-rdb-preamble yes` | Hybrid AOF: RDB snapshot + AOF tail. Faster load times with AOF durability. |
| `save 3600 1 300 100 60 10000` | Periodic RDB for backup and faster cold restarts. |
| `stop-writes-on-bgsave-error yes` | If background save fails, stop accepting writes. Alerts you to disk issues. |

### Maximum Durability Variant

If you need zero data loss (at significant performance cost):

```
appendfsync always
```

This fsyncs after every write command. Throughput drops substantially (depends on disk speed), but no writes are lost even on power failure.


## Session Store

Sessions have natural TTLs. Losing a session is inconvenient but not catastrophic.

```
# Memory
maxmemory <70% of available RAM>
maxmemory-policy volatile-ttl

# Moderate persistence
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes

# No RDB snapshots (AOF is sufficient)
save ""

# Connection management
timeout 0
tcp-keepalive 300

# Performance
io-threads 4
```

### Why These Settings

| Parameter | Rationale |
|-----------|-----------|
| `volatile-ttl` | Evict sessions closest to expiration first. Sessions nearing TTL are about to expire anyway. |
| `appendonly yes` | Persist sessions across restarts. Users do not have to re-authenticate. |
| `save ""` | AOF is sufficient. Skipping RDB avoids fork overhead. |
| `timeout 0` | Do not disconnect idle clients - the application manages session lifecycle. |

### Alternative: volatile-lru

If sessions are accessed with varying frequency and you want to keep the most active ones:

```
maxmemory-policy volatile-lru
```

This evicts least-recently-accessed sessions first, regardless of TTL.


## Message Queue / Job Queue

Valkey as a task queue using Lists or Streams. Data loss means lost jobs.

```
# Memory
maxmemory <70% of available RAM>
maxmemory-policy noeviction

# Strong persistence
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes

# RDB for backup
save 3600 1 300 100 60 10000

# Queue-specific tuning
list-max-listpack-size -2
stream-node-max-entries 100
stream-node-max-bytes 4096

# Client management
timeout 0
tcp-keepalive 60

# Performance
io-threads 4
```

### Why These Settings

| Parameter | Rationale |
|-----------|-----------|
| `noeviction` | Never drop queue entries. Workers must process them. |
| `appendfsync everysec` | Balance between durability and throughput. |
| `tcp-keepalive 60` | Detect dead worker connections quickly (60s vs default 300s). |
| `list-max-listpack-size -2` | 8KB per quicklist node. Good balance for queue entries. |
| `timeout 0` | Workers may block on BRPOP/XREAD - do not disconnect them. |


## Rate Limiter / Counter

High write throughput, short-lived keys, acceptable data loss on restart.

```
# Memory
maxmemory <50% of available RAM>
maxmemory-policy volatile-ttl

# No persistence (counters reset on restart)
save ""
appendonly no

# Performance
io-threads 4
tcp-keepalive 300
timeout 60

# Logging
commandlog-execution-slower-than 5000
```

### Why These Settings

| Parameter | Rationale |
|-----------|-----------|
| `volatile-ttl` | Rate limit windows have TTLs. Evict expired windows first. |
| No persistence | Counter state is transient. Restart resets all limits - acceptable for most rate limiters. |
| `maxmemory` 50% of RAM | Conservative - rate limiter keys are small but can spike with attack traffic. |
| `timeout 60` | Short timeout - rate limiter clients are typically short-lived. |
| `commandlog-execution-slower-than 5000` | 5ms threshold - rate limiters need consistent low latency. |


## Shared Tuning Notes

### io-threads Sizing

| CPU Cores | Recommended io-threads |
|-----------|----------------------|
| 1-2 | 1 (default, single-threaded) |
| 4 | 2-3 |
| 8 | 4 |
| 16+ | 4-8 |

Rarely beneficial above 8. Profile with `valkey-benchmark` to find the sweet spot.

### maxmemory-clients

For all workloads, consider setting `maxmemory-clients` to prevent a single misbehaving client from consuming all memory:

```
maxmemory-clients 5%
```

This caps aggregate client buffer memory at 5% of `maxmemory`. Default is `0` (disabled).

### Replication Add-On

If adding replication to any preset, add:

```
min-replicas-to-write 1
min-replicas-max-lag 10
repl-backlog-size 256mb
```

This ensures the primary rejects writes if no replicas are connected and acknowledging, preventing split-brain data divergence.


## See Also

- [Eviction Policies](eviction.md) - policy details and tuning
- [Configuration Essentials](essentials.md) - all config defaults
- [Encoding Thresholds](encoding.md) - memory tuning via compact encodings
- [I/O Threads](../performance/io-threads.md) - thread count guidelines
- [Durability vs Performance](../performance/durability.md) - persistence trade-offs
