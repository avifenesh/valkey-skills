# Durability vs Performance

Use when choosing persistence settings, tuning TCP/client connections, or
evaluating Valkey 9.0 performance features. Covers the full spectrum from
maximum safety to maximum speed.

---

## Durability Spectrum

From safest (slowest) to fastest (least durable):

### 1. AOF + appendfsync always

```
appendonly yes
appendfsync always
```

Every write is fsynced to disk before acknowledgment. Maximum durability -
at most one command lost on crash. Significant throughput penalty due to
blocking fsync on every write.

Source-verified: `appendfsync` defaults to `everysec` (AOF_FSYNC_EVERYSEC)
in `src/config.c` line 3340.

### 2. AOF + appendfsync everysec (default)

```
appendonly yes
appendfsync everysec
```

Background fsync every second. At most 1 second of data lost on crash.
Best balance of durability and performance for most production workloads.

### 3. AOF + everysec + no-appendfsync-on-rewrite

```
appendonly yes
appendfsync everysec
no-appendfsync-on-rewrite yes
```

Skips fsync while a child process is rewriting AOF or saving RDB. Reduces
latency spikes during background saves at the cost of potentially more data
loss if crash occurs during rewrite.

Source-verified: `no-appendfsync-on-rewrite` defaults to `no` (0) in
`src/config.c` line 3263.

### 4. AOF + appendfsync no

```
appendonly yes
appendfsync no
```

OS decides when to flush to disk (typically every 30 seconds on Linux).
Low latency but potential for significant data loss on crash.

### 5. RDB only

```
appendonly no
save 3600 1
save 300 100
save 60 10000
```

Periodic snapshots only. Data loss equals everything since the last snapshot.
Lower overhead than AOF but less granular recovery.

### 6. No persistence

```
appendonly no
save ""
```

Pure in-memory cache. Zero persistence overhead. All data lost on restart.
Use when data can be reconstructed from another source.

### Mixed Mode (Recommended for Production)

```
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
save 3600 1
save 300 100
```

Source-verified: `aof-use-rdb-preamble` defaults to `yes` (1) in
`src/config.c` line 3267. This uses an RDB snapshot at the start of the
AOF file for faster loading, followed by AOF commands for recent changes.

## TCP Backlog Configuration

Source-verified: `tcp-backlog` defaults to 511, immutable (cannot change at
runtime) in `src/config.c` line 3383.

```
tcp-backlog 511
```

The effective backlog is the minimum of this value and `net.core.somaxconn`.
If your kernel default is 128 (common), Valkey will warn at startup.

```bash
# Check current kernel value
sysctl net.core.somaxconn

# Increase for high-connection workloads
sysctl -w net.core.somaxconn=65535

# Persist across reboots
echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
```

## Client Connection Tuning

Source-verified defaults from `src/config.c`:

| Directive | Default | Source Line | Notes |
|-----------|---------|-------------|-------|
| `maxclients` | 10000 | 3409 | Upper bound on concurrent connections |
| `timeout` | 0 (disabled) | 3381 | Idle client timeout in seconds |
| `tcp-keepalive` | 300 | 3368 | TCP keepalive interval in seconds |
| `maxmemory-clients` | 0 (unlimited) | 3458 | Cap on aggregate client memory |

### Production Settings

```
maxclients 10000
timeout 300                          # Close idle clients after 5 minutes
tcp-keepalive 300                    # Detect dead connections
maxmemory-clients 5%                 # Cap aggregate client buffer memory
```

### Client Output Buffer Limits

```
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
```

Format: `<class> <hard-limit> <soft-limit> <soft-seconds>`

- `normal`: regular clients - no limit by default
- `replica`: disconnect replicas exceeding 256MB or sustaining 64MB for 60s
- `pubsub`: disconnect pub/sub clients exceeding 32MB or sustaining 8MB for 60s

### Client-Side Best Practices

- Use connection pooling (start with 1 connection per node)
- Set client connection timeout to 5 seconds
- Set request timeout to 10 seconds
- Implement exponential backoff with jitter on reconnection
- Pipeline commands to reduce round-trips (batch 50-100 commands)

## Valkey 9.0 Performance Features

### Memory Prefetching for Pipelines

Up to 40% higher throughput for pipelined workloads. Valkey prefetches key
data into CPU cache while processing the current command, amortizing memory
access latency across batched commands.

### Zero-Copy Responses

Up to 20% improvement for large payloads. Avoids copying response data when
sending to clients by referencing the original buffer directly.

### SIMD Optimizations

200% faster BITCOUNT and HyperLogLog operations using CPU vector instructions
(AVX2, NEON). Benefits workloads using bitmap analytics or cardinality
estimation.

### Multipath TCP

Up to 25% latency reduction when clients and server support MPTCP. Uses
multiple network paths simultaneously for lower latency and higher resilience.

### Atomic Slot Migration

4.6-9.5x faster cluster resharding. Slot data is migrated atomically rather
than key-by-key, reducing the time during which a slot is in a migrating state.

## Kernel Tuning for Performance

```bash
# TCP backlog
sysctl -w net.core.somaxconn=65535

# Disable transparent huge pages
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Allow overcommit for fork operations
sysctl -w vm.overcommit_memory=1

# Increase max open files
ulimit -n 65535
```

## Quick Decision Guide

| Scenario | Persistence | appendfsync | io-threads |
|----------|-------------|-------------|------------|
| Cache (reconstructible) | none | - | 4+ |
| Session store | AOF | everysec | 2-4 |
| Primary database | AOF + RDB | everysec | 2-4 |
| Financial/transactional | AOF | always | 1-2 |
| High-throughput analytics | RDB only | - | 8+ |

---

## See Also

- [AOF Persistence](../persistence/aof.md) - AOF configuration details
- [RDB Persistence](../persistence/rdb.md) - snapshot configuration details
- [I/O Threads](io-threads.md) - multi-threaded I/O configuration
- [Workload Presets](../configuration/workload-presets.md) - complete configs by use case
- [See valkey-dev: io-threads](../valkey-dev/reference/threading/io-threads.md) - I/O thread internals
- [See valkey-dev: prefetch](../valkey-dev/reference/threading/prefetch.md) - batch key prefetching
