# Configuration Presets by Workload

Use when configuring Valkey for a specific use case. Each preset lists the parameters to set and why. Defaults verified against `src/config.c`.

## Contents

- Cache-Only (Volatile Data) (line 17)
- Primary Data Store (Durability Required) (line 79)
- Session Store (line 129)
- Message Queue / Job Queue (line 185)
- Rate Limiter / Counter (line 236)
- Shared Tuning Notes (line 269)

---

## Cache-Only (Volatile Data)

Data is expendable. Speed and memory efficiency matter. No persistence needed.

```
# Memory
maxmemory <80% of available RAM>
maxmemory-policy allkeys-lru
maxmemory-samples 5
maxmemory-clients 5%

# Disable all persistence
save ""
appendonly no

# Performance
io-threads 4
tcp-keepalive 300
timeout 300

# Encoding - optimize for many small objects
hash-max-listpack-entries 128
hash-max-listpack-value 64

# Defrag - caches have high churn
activedefrag yes
active-defrag-ignore-bytes 200mb
active-defrag-threshold-lower 15
active-defrag-cycle-max 15

# Network
tcp-backlog 65535
maxclients 20000

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
| `maxmemory-clients 5%` | Protect data memory from misbehaving clients. |
| `io-threads 4` | Offload read/write I/O to threads. Adjust based on CPU cores (2-8 typical). |
| `timeout 300` | Disconnect idle clients after 5 minutes. Prevents connection leaks. |
| `activedefrag yes` | Caches with high key churn benefit from online defragmentation (jemalloc only). |

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
no-appendfsync-on-rewrite yes

# No RDB snapshots (AOF is sufficient)
save ""

# Encoding - sessions are small hashes (10-30 fields)
hash-max-listpack-entries 128
hash-max-listpack-value 128

# Expiry - sessions expire frequently, be moderately aggressive
active-expire-effort 3

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
| `no-appendfsync-on-rewrite yes` | Skip fsync during AOF rewrite to reduce disk pressure. |
| `save ""` | AOF is sufficient. Skipping RDB avoids fork overhead. |
| `hash-max-listpack-value 128` | Sessions may contain JSON blobs in fields - raise from default 64. |
| `active-expire-effort 3` | Sessions expire frequently; reclaim memory moderately faster than default. |
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
no-appendfsync-on-rewrite yes

# RDB for backup
save 3600 1 300 100 60 10000

# Queue-specific tuning
list-max-listpack-size -2
list-compress-depth 0
stream-node-max-entries 100
stream-node-max-bytes 4096

# Client management
timeout 0
tcp-keepalive 60

# Replication (queues need HA)
repl-backlog-size 256mb
client-output-buffer-limit replica 512mb 128mb 120

# Performance
io-threads 4
```

### Why These Settings

| Parameter | Rationale |
|-----------|-----------|
| `noeviction` | Never drop queue entries. Workers must process them. |
| `appendfsync everysec` | Balance between durability and throughput. |
| `no-appendfsync-on-rewrite yes` | Reduce disk pressure during AOF rewrite. |
| `tcp-keepalive 60` | Detect dead worker connections quickly (60s vs default 300s). |
| `list-max-listpack-size -2` | 8KB per quicklist node. Good balance for queue entries. |
| `list-compress-depth 0` | No compression - queues are LIFO/FIFO, all nodes are accessed. |
| `timeout 0` | Workers may block on BRPOP/XREAD - do not disconnect them. |
| `repl-backlog-size 256mb` | Large backlog for write-heavy queues to support partial resync. |
| `client-output-buffer-limit replica 512mb ...` | Match buffer to backlog size for write-heavy primaries with long RDB transfers. |


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
| `timeout 60` | Short timeout - rate limiter clients are short-lived. |
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

For all workloads, set `maxmemory-clients` to prevent a single misbehaving client from consuming all memory. `maxmemory-clients 5%` caps aggregate client buffer memory at 5% of `maxmemory`. Default is `0` (disabled).

### Replication Add-On

If adding replication to any preset, add:

```
min-replicas-to-write 1
min-replicas-max-lag 10
repl-backlog-size 256mb
```

This ensures the primary rejects writes if no replicas are connected and acknowledging, preventing split-brain data divergence.
