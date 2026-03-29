# I/O Threads Configuration

Use when tuning Valkey throughput on multi-core systems, deciding whether to
enable I/O threads, or choosing the right thread count for your workload.

---

## How It Works

Valkey keeps command execution single-threaded on the main thread. I/O threads
handle only network read/write, parsing, response serialization, and polling.
This means no locking around data structures - the parallelism is strictly in
the I/O path.

Each I/O thread has its own lock-free ring buffer job queue (2048 entries).
Clients are assigned to threads deterministically by client ID, so the same
client always maps to the same thread for cache locality.

## Configuration

| Directive | Default | Range | Notes |
|-----------|---------|-------|-------|
| `io-threads` | 1 | 1-256 | Total threads including main. Set N+1 for N I/O workers |
| `events-per-io-thread` | 2 | 0-INT_MAX | Events needed per active thread. 0 = always offload |

Source-verified defaults from `src/config.c`:
- `io-threads` default is 1 (single-threaded, line 3359)
- `events-per-io-thread` default is 2 (line 3360, hidden config)
- Maximum is `IO_THREADS_MAX_NUM` = 256 (defined in `src/config.h`)
- Both are modifiable at runtime via `CONFIG SET`

### Deprecated Config

`io-threads-do-reads` is deprecated in current Valkey. It appears in the
deprecated config list in `src/config.c`. When I/O threads are enabled (count
> 1), reads are always offloaded - there is no separate toggle.

## When to Enable

Enable I/O threads when:

- CPU is not the bottleneck but network I/O is
- You have spare CPU cores dedicated to Valkey
- Your workload is throughput-bound (high request rate, many clients)
- You see the main thread saturated on read/write operations

Do NOT enable when:

- Running on a single-core or dual-core system
- Your workload is latency-sensitive with low request rates
- Memory is the bottleneck (I/O threads do not help with eviction or persistence)

## Thread Count Guidelines

| System | Recommended `io-threads` | Rationale |
|--------|--------------------------|-----------|
| 2-4 cores | 2-3 | Leave at least 1 core for OS and background tasks |
| 8 cores | 4-5 | Diminishing returns beyond this for most workloads |
| 16 cores | 6-9 | Benchmark showed 1.19M SET RPS with 9 threads on 16-core ARM |
| 32+ cores | 8-12 | Test incrementally; rarely need more than 12 |

Key rule: never exceed physical core count. I/O threads that compete for cores
with the main thread or with each other will hurt rather than help.

## Dynamic Thread Adjustment

Valkey dynamically activates and deactivates I/O threads based on current event
load. The formula from `src/io_threads.c`:

```
target_threads = numevents / events_per_io_thread
target_threads = max(1, min(target_threads, io_threads))
```

Threads are parked via mutex when idle and unparked when load increases. This
means setting `io-threads 8` does not force 8 threads to run constantly - they
spin up only as needed.

## Performance Benchmarks

From Valkey benchmarks on AWS C7g.16xlarge (16-core ARM, 650 clients):

| Config | Throughput (SET RPS) | Avg Latency |
|--------|---------------------|-------------|
| `io-threads 1` | ~360K | 1.792ms |
| `io-threads 9` | 1.19M | 0.542ms |

That is a 230% throughput improvement and 69.8% latency reduction.

The bottleneck in high-throughput scenarios is memory access latency, not CPU
compute. I/O threads parallelize the memory-intensive read/write/parse work.
Combined with batch key prefetching (introduced in Valkey 8.1+), this amortizes
cache misses across commands.

## Applying the Configuration

```bash
# Check current setting
valkey-cli CONFIG GET io-threads

# Enable 4 I/O threads (3 workers + main)
valkey-cli CONFIG SET io-threads 4

# Persist to config file
valkey-cli CONFIG REWRITE
```

Monitor I/O thread utilization with `INFO server` - check
`io_threads_active` to see how many threads are currently running.

## Troubleshooting I/O Threads

**No throughput improvement after enabling**:
- Check if workload is actually I/O-bound (not CPU or memory-bound)
- Verify `events-per-io-thread` is not too high (default 2 is usually fine)
- Ensure sufficient CPU cores are available

**Higher latency after enabling**:
- Too many threads competing for cores - reduce `io-threads`
- Check CPU affinity settings (`server-cpulist` config)

**Thread not activating**:
- Dynamic adjustment requires enough concurrent events
- Set `events-per-io-thread 0` temporarily to force all threads active for testing

---

## See Also

- [Durability vs Performance](durability.md) - persistence trade-offs with I/O threads
- [Configuration Essentials](../configuration/essentials.md) - `io-threads` config reference
- [Latency Diagnosis](latency.md) - troubleshooting latency with I/O threads
- [See valkey-dev: io-threads](../valkey-dev/reference/threading/io-threads.md) - internal architecture, job queue design
- [See valkey-dev: prefetch](../valkey-dev/reference/threading/prefetch.md) - batch key prefetching
