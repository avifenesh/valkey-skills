# Performance Improvements Summary

Use when evaluating Valkey's performance characteristics or understanding what version-specific optimizations benefit your application without configuration changes.

---

Performance figures below are from Valkey project benchmarks and release notes. Actual improvements depend on workload characteristics, hardware, and configuration. See the linked Valkey release notes for methodology details.

## Contents

- Version-by-Version Performance Changes (line 17)
- What Application Developers Get for Free (line 51)
- What Requires Configuration (line 82)
- I/O Thread Tuning Details (line 117)
- MPTCP Details (line 153)
- Benchmarking Guidance (line 185)
- Application-Side Optimizations (line 241)

## Version-by-Version Performance Changes

### Valkey 8.0

| Feature | Impact | Detail |
|---------|--------|--------|
| I/O multithreading overhaul | 3x throughput (360K -> 1.2M RPS) | I/O threads handle read/parse/write; main thread handles command execution |
| Command batching | Reduced CPU cache misses | Commands grouped for better cache locality |
| Dual-channel replication | Faster replica sync | RDB transfer and replication stream run in parallel |

### Valkey 8.1

| Feature | Impact | Detail |
|---------|--------|--------|
| New hashtable implementation | 20-30 bytes less memory per key | Open-addressing with 64-byte buckets, SIMD probing |
| Iterator prefetching | 3.5x faster iteration | SCAN, KEYS, HGETALL, and similar commands benefit |
| TLS offload to I/O threads | 300% faster TLS connection acceptance | TLS handshake no longer blocks main thread |
| ZRANK optimization | 45% faster | Optimized skiplist traversal |
| BITCOUNT (AVX2) | 514% faster | SIMD-accelerated bit counting |
| PFMERGE/PFCOUNT (AVX) | 12x faster | SIMD-accelerated HyperLogLog operations |

### Valkey 9.0

| Feature | Impact | Detail |
|---------|--------|--------|
| Pipeline memory prefetch | Up to 40% higher throughput | Batch key prefetching for pipelined commands |
| Zero-copy responses | Up to 20% higher throughput for large values | Eliminates buffer copies for read-heavy workloads |
| SIMD BITCOUNT/HLL | Up to 200% higher throughput | Further SIMD improvements over 8.1 |
| Multipath TCP (MPTCP) | Up to 25% latency reduction | Multiple network paths for a single connection |
| Atomic slot migration | Faster resharding | Bulk transfer instead of key-by-key |
| 1 billion RPS at scale | Cluster benchmark | Across 2,000 cluster nodes |

---

## What Application Developers Get for Free

No application code changes needed. These take effect on upgrade:

### Transparent throughput gains

- Higher ops/sec at the same connection count
- Lower p99 latency under load
- Better multi-core utilization (I/O threading)

### Transparent memory savings

- Smaller per-key memory footprint (8.1 hashtable)
- More efficient encoding of small collections (listpack improvements)
- Better memory fragmentation handling

### Faster specific commands

Applications using these operations see immediate speedups:

| Command | Improvement | Version |
|---------|------------|---------|
| `BITCOUNT` | 5-7x faster | 8.1+ |
| `PFCOUNT` / `PFMERGE` | 12x faster | 8.1+ |
| `ZRANK` / `ZREVRANK` | 45% faster | 8.1+ |
| `SCAN` / `HSCAN` / `SSCAN` / `ZSCAN` | 3.5x faster | 8.1+ |
| Pipelined commands | 40% higher throughput | 9.0+ |
| Large value reads | 20% higher throughput | 9.0+ |

---

## What Requires Configuration

Some improvements need operator-side configuration.

### I/O threading

Default is 1 (main thread only, no separate I/O threads). For high-throughput workloads:

```
io-threads 4        # Main + 3 I/O threads (good starting point)
io-threads 9        # Main + 8 I/O threads (dedicated high-throughput hardware)
```

Requires available CPU cores. The main thread still handles command execution (single-threaded) - this scales I/O, not computation.

### TLS offload (8.1+)

TLS handshake is offloaded to I/O threads automatically when `io-threads > 1`. No additional configuration needed beyond setting `io-threads`.

### Multipath TCP (9.0+)

Requires kernel support and network configuration. When available, Valkey uses MPTCP automatically. This benefits deployments with multiple network interfaces.

### Pipeline prefetch (9.0+)

Enabled automatically for pipelined commands. Applications already pipelining benefit with no changes. Applications not pipelining should add it - the gains are significant.

---

## I/O Thread Tuning Details

### Choosing `io-threads` count

Rule of thumb: set `io-threads` to half your available cores, capped at 8. The value includes the main thread, so `io-threads 4` means the main thread plus 3 I/O threads.

| Core count | Recommended `io-threads` |
|------------|--------------------------|
| 2-4 cores  | 2                        |
| 6-8 cores  | 4                        |
| 12-16 cores | 6-8                     |
| 32+ cores  | 8 (max)                  |

The maximum useful value is 8. Beyond that, lock contention on the command queue cancels any I/O gains. The main thread remains single-threaded for command execution regardless of `io-threads`.

### `events-per-io-thread`

Controls how many epoll events each I/O thread processes per cycle before yielding back to the main thread.

```
events-per-io-thread 16   # default
```

Lower values reduce latency at the cost of throughput (more frequent context switches). Higher values improve throughput but can increase tail latency under bursty traffic. The default of 16 is appropriate for most workloads. Reduce to 4-8 if you see p99 spikes on mixed small/large payload workloads.

### `io-threads-do-reads` is removed in Valkey

In Redis, reads were optionally threaded via `io-threads-do-reads yes`. Valkey removed this option - reads are always handled by I/O threads when `io-threads > 1`. There is no separate toggle. If you are migrating configuration from Redis, remove `io-threads-do-reads` from valkey.conf to avoid a startup warning.

### When I/O threads do NOT help

I/O threading targets network I/O throughput. It provides little benefit in these cases:

- **Small payload, low connection count** - the main thread can keep up; I/O thread overhead adds latency without adding capacity.
- **CPU-bound Lua scripts or EVAL** - command execution stays single-threaded; Lua runs on the main thread. More I/O threads do not speed up script-heavy workloads.
- **Very few concurrent clients** - I/O threading shines when hundreds of connections are open simultaneously. A single client issuing pipelined commands saturates a single I/O thread.
- **Unix socket deployments** - local socket throughput is rarely the bottleneck.

### Monitoring I/O thread effectiveness

Check `INFO stats` and `INFO commandstats` before and after enabling I/O threads:

```
# Key fields in INFO stats
total_commands_processed   # rising faster = I/O threads helping
instantaneous_ops_per_sec  # direct throughput indicator

# Watch for diminishing returns
io_threads_active          # available in DEBUG JMAP output and logs
```

If `instantaneous_ops_per_sec` does not improve after enabling I/O threads, the bottleneck is elsewhere (CPU on the main thread, network saturation, or client-side throughput). Use `top -H` to verify I/O thread CPU consumption is spread across cores rather than pinned to a single core.

---

## MPTCP Details

### What MPTCP is and why it helps

Multipath TCP (MPTCP) allows a single TCP connection to use multiple network subflows simultaneously across two NICs or two network paths. Each subflow is standard TCP so firewalls and middleboxes see no change. The socket API is unchanged for applications.

For Valkey, MPTCP reduces per-request latency (up to 25% in Valkey 9.0 benchmarks) by distributing traffic across paths and enabling faster retransmission when one path congests. The benefit is latency variance reduction and resilience, not raw bandwidth increase.

### Kernel requirements

MPTCP requires Linux kernel 5.6 or later (upstream). Most distributions shipping a 5.15 or 6.x kernel have it available. Check:

```bash
# Confirm MPTCP is compiled in
grep MPTCP /boot/config-$(uname -r)
# Expect: CONFIG_MPTCP=y

# Enable at runtime if not already on
sudo sysctl -w net.mptcp.enabled=1

# Persist across reboots
echo "net.mptcp.enabled = 1" | sudo tee /etc/sysctl.d/99-mptcp.conf
```

Valkey 9.0+ detects MPTCP availability at startup and uses it automatically. No `valkey.conf` change is needed.

### Verifying MPTCP is active

After connecting a client, confirm subflows are established:

```bash
# ss with MPTCP filter - shows active MPTCP sockets
ss -M

# Expected output includes lines like:
# MPTCP   ESTAB  0  0  10.0.0.1:6379  10.0.0.2:54321
# with subflow details below each line

# Confirm Valkey is listening on MPTCP socket type
ss -tlnp | grep 6379
# On MPTCP-enabled systems, Valkey binds using SOCK_MPTCP internally
```

Valkey logs a startup notice when MPTCP is active: `MPTCP socket type in use`.

### Expected latency reduction

25% p99 latency reduction is the figure from Valkey 9.0 benchmarks on multi-path hardware. Results vary by:

- Number of available network paths (benefit requires at least 2 subflows)
- Baseline congestion on the primary path
- Geographic distance (MPTCP helps more at higher RTTs)

On single-NIC hosts with no secondary path, MPTCP falls back to standard TCP behavior with no regression.

### Client-side requirements

Clients do not need MPTCP support in their socket library. The server-side MPTCP socket transparently handles subflow negotiation during the TCP handshake. If the client's kernel does not support MPTCP, the connection falls back to standard TCP automatically - no connection failure occurs.

For maximum benefit, the client host should also run Linux 5.6+ with MPTCP enabled and have a second network path reachable from the server.

---

## Benchmarking Guidance

### `valkey-benchmark` key flags

```bash
# Basic syntax
valkey-benchmark [OPTIONS]

# Key flags
-t SET,GET          # comma-separated list of commands to benchmark
-c 50               # number of concurrent connections (default 50)
-n 100000           # total number of requests (default 100000)
-P 16               # pipeline depth: send N commands per batch (default 1)
--threads 4         # client-side threads (matches server io-threads)
-d 64               # payload size in bytes (default 3)
--tls               # enable TLS for the benchmark connection
-q                  # quiet mode: print only ops/sec summary
```

Example - benchmark GET/SET with pipelining and 4 client threads:

```bash
valkey-benchmark -t get,set -c 100 -n 1000000 -P 16 --threads 4 -d 128 -q
```

### Common pitfalls

**Single-threaded client against a multi-threaded server** - `valkey-benchmark` defaults to `--threads 1`. With `io-threads 8` on the server, the benchmark client becomes the bottleneck. Pass `--threads` equal to your server's `io-threads` for peak throughput measurement.

**Too few connections with pipelining** - pipelining within one connection saturates that socket buffer. Combine `-c 100` with `-P 16` rather than `-c 1 -P 1000`.

**Cold start** - run a warm-up pass first, then measure:

```bash
valkey-benchmark -t set -n 50000 -q          # warm up
valkey-benchmark -t set,get -n 500000 -q     # measure
```

**Single command type** - benchmark the read/write mix that reflects your application, not GET-only.

### Baseline numbers (rough reference)

These are approximate figures on modern hardware (bare metal, 10 GbE, io-threads 4). Use as a sanity check, not a specification.

| Workload | Payload | Pipeline | Approx ops/sec |
|----------|---------|----------|----------------|
| SET | 64 B | no | 400K-600K |
| GET | 64 B | no | 500K-800K |
| SET | 64 B | 16 | 2M-4M |
| GET | 64 B | 16 | 3M-5M |
| SET | 1 KB | no | 300K-500K |
| GET | 1 KB | no | 350K-600K |
| HSET (10 fields) | 64 B | no | 300K-500K |

Valkey 9.0 cluster benchmarks at 1 billion RPS were achieved across 2,000 nodes, not a single instance. Single-instance peak is approximately 1.5M RPS for small payloads with `io-threads 8` and aggressive pipelining.

### Pipeline vs non-pipeline comparison

Run both and compare:

```bash
# No pipeline
valkey-benchmark -t set,get -c 50 -n 500000 -d 64 -q

# Pipeline depth 16
valkey-benchmark -t set,get -c 50 -n 500000 -P 16 -d 64 -q

# Pipeline depth 128
valkey-benchmark -t set,get -c 50 -n 500000 -P 128 -d 64 -q
```

Throughput typically scales linearly from P1 to P16, then flattens. Pipeline depths beyond 64-128 rarely improve throughput further and increase per-batch latency.

### memtier_benchmark for realistic workloads

`valkey-benchmark` tests one command type at a time. `memtier_benchmark` generates mixed read/write ratios and variable key distributions, which better represent real workloads.

```bash
# Install: apt-get install memtier-benchmark
# or build from https://github.com/RedisLabs/memtier_benchmark

# 80% read / 20% write, 1M keys, 32-byte values
memtier_benchmark \
  --server 127.0.0.1 --port 6379 \
  --protocol valkey \
  --ratio 4:1 \
  --key-maximum 1000000 \
  --data-size 32 \
  --threads 10 \
  --clients 50 \
  --test-time 60
# Output: ops/sec, p50/p99/p99.9 latency, bandwidth MB/s
```

Use memtier when validating that a change (new `io-threads`, MPTCP, TLS offload) improves or does not regress your specific read/write mix.

---

## Application-Side Optimizations

Not version-specific, but compound with server-side improvements:

### Pipelining

Send multiple commands in one batch. Up to 10x throughput improvement at the application level, further amplified by server-side pipeline prefetch in 9.0.

```
# Without pipelining: N round-trips
SET key1 val1  -> OK
SET key2 val2  -> OK

# With pipelining: 1 round-trip
[SET key1 val1, SET key2 val2] -> [OK, OK]
```

Recommended batch size: ~10,000 commands per batch.

### Connection pooling

Reuse connections instead of creating per-request. Valkey GLIDE uses a single multiplexed connection per node with auto-pipelining - no pool management needed.

### Client-side caching

Use `CLIENT TRACKING` to cache frequently-read keys locally. The server sends invalidation messages when tracked keys change, eliminating round-trips.

---

