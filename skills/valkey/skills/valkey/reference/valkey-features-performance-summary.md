# Performance Improvements Summary

Use when you need to know what version-specific optimizations benefit your workload and what tuning knobs control them. Numbers below are rough - treat as ballpark, not specification.

## Version-by-Version Performance Changes

### Valkey 8.0

| Feature | Impact | Detail |
|---------|--------|--------|
| Async I/O threading | Higher throughput under high connection concurrency | I/O threads handle read/parse/write; main thread handles command execution |
| Dual-channel replication | Faster replica sync | RDB transfer and replication stream run in parallel |

### Valkey 8.1

| Feature | Impact | Detail |
|---------|--------|--------|
| New hashtable implementation | Lower per-key memory and better cache locality | 64-byte (cache-line) buckets holding 7 entries each, bucket chaining, SIMD hash-bit scan, incremental rehashing |
| Iterator prefetching | 3.5x faster iteration | SCAN, KEYS, HGETALL, and similar commands benefit |
| TLS offload to I/O threads | Small (~10%) throughput gain on TLS workloads | TLS handshake and error-queue handling moved off main thread; activates with io-threads > 1 |
| ZRANK optimization | Up to 45% faster (mostly unique scores); ~8-27% with many duplicate scores | Skiplist traversal skips redundant string comparisons |
| BITCOUNT SIMD | Negligible for <256B; ~6x at 1MB (AVX2), up to ~10x at 10MB (ARM NEON) | Enabled at runtime when CPU has AVX2 or ARM NEON |
| PFMERGE/PFCOUNT SIMD | ~12x faster on multi-HLL merge with dense encoding (AVX2) | Sparse-encoded HLLs unaffected; requires default HLL config |

### Valkey 9.0

| Feature | Impact | Detail |
|---------|--------|--------|
| Pipeline memory prefetch | Measurable throughput gain on pipelined workloads (also helps MGET/MSET/DEL) | Parser reads multiple commands from the query buffer; keys for queued commands are prefetched in batches. Batch size: `prefetch-batch-max-size` (default 16). |
| Reply copy avoidance | Skips a payload copy when replying with large bulk strings under I/O threads | Auto-enabled above thread and size thresholds (`min-io-threads-avoid-copy-reply`, `min-string-size-avoid-copy-reply`). Internal/hidden configs. |
| Additional SIMD (BITCOUNT, HLL findBucket, hash findBucket) | Further acceleration on CPUs with ARM NEON or AVX2 | Complements the 8.1 SIMD work |
| Multipath TCP (MPTCP) | Latency resilience under packet loss (opt-in); negligible on clean networks | Config `mptcp yes` + `repl-mptcp yes`, both immutable. See MPTCP section. |
| Atomic slot migration | Faster, safer resharding | Bulk transfer instead of key-by-key |

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
| `BITCOUNT` | Negligible <256B; ~6x at 1MB (AVX2), up to ~10x at 10MB (ARM NEON) | 8.1+ |
| `PFCOUNT` / `PFMERGE` | ~12x on multi-HLL merge, dense encoding, AVX2 CPU | 8.1+ |
| `ZRANK` / `ZREVRANK` | Up to 45% (mostly unique scores); less with duplicate scores | 8.1+ |
| `KEYS` full iteration | ~3.5x faster | 8.1+ |
| `SCAN` / `HSCAN` / `SSCAN` / `ZSCAN` | Benefit from the same iterator; magnitude unmeasured | 8.1+ |
| Pipelined commands | Measurable throughput gain via batch key prefetch | 9.0+ |
| Large bulk-string replies under I/O threads | Skips a payload copy | 9.0+ |

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

Opt-in. Requires Linux kernel 5.6+ and explicit `mptcp yes` (client-facing) and/or `repl-mptcp yes` (replication) in valkey.conf. Both are immutable. See MPTCP section below.

### Pipeline prefetch (9.0+)

Enabled automatically. Tune via `prefetch-batch-max-size` (default 16, max 128). Applications already pipelining benefit with no changes. Multi-key commands (MGET, MSET, DEL) also benefit when pipelined or when `io-threads > 1`.

---

## I/O Thread Tuning Details

### Choosing `io-threads` count

The server accepts `io-threads` up to 256. Beyond a handful of threads the main thread (which still executes commands single-threaded) becomes the bottleneck and additional I/O threads stop helping. Start at half the available cores and tune with a benchmark.

| Core count | Starting `io-threads` |
|------------|-----------------------|
| 2-4 cores  | 2                     |
| 6-8 cores  | 4                     |
| 12-16 cores | 6-8                  |
| 32+ cores  | 8, then measure       |

The value includes the main thread, so `io-threads 4` means the main thread plus 3 I/O threads. The main thread remains single-threaded for command execution regardless of `io-threads`, so CPU-bound commands (Lua, long EVAL) do not scale with more I/O threads.

### `events-per-io-thread`

Controls how many epoll events each I/O thread processes per cycle before yielding back to the main thread. Hidden/internal config; default `2`. Raise it if you want I/O threads to amortize more events per yield; lower it only to investigate tail-latency.

### `io-threads-do-reads` silently ignored

Valkey always handles reads on I/O threads when `io-threads > 1` - there is no toggle. The `io-threads-do-reads` directive, if present in valkey.conf, is silently ignored with no warning and no effect. Safe to leave in or remove when migrating from Redis.

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

For Valkey, MPTCP reduces per-request latency under packet loss by retransmitting on an alternate subflow instead of waiting on the lossy path. The benefit is latency variance reduction and resilience, not raw bandwidth increase. On a clean single-path network, MPTCP provides near-zero improvement.

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

MPTCP is **opt-in**. Two config options, both default `no` and both immutable (set at startup, not via `CONFIG SET`):

```
mptcp yes           # listener accepts MPTCP connections from clients
repl-mptcp yes      # replica opens MPTCP connection to primary
```

Startup fails with `MPTCP is not supported on this platform` if the kernel lacks MPTCP.

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

### When MPTCP pays off

Loss resilience, not bandwidth. Pays off with packet loss and at least two reachable network paths. On a clean single-NIC network, expect near-zero delta. Use MPTCP when:

- Clients cross an unreliable path (WAN, multi-AZ with occasional loss)
- Host has two NICs or two routable paths to the server
- Clients also run Linux 5.6+ with MPTCP enabled

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

Single-instance peak is roughly 1-1.5M RPS for small payloads with `io-threads` tuned and aggressive pipelining. Cluster throughput scales roughly linearly with shard count when the workload avoids cross-slot operations.

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

Send multiple commands in one batch. Up to ~10x throughput improvement at the application level by eliminating RTT per command. Further amplified on 9.0+ by server-side pipeline prefetch.

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

