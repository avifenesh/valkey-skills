# I/O Threads Configuration

Use when tuning Valkey throughput on multi-core systems, deciding whether to
enable I/O threads, or choosing the right thread count for your workload.

---

## Tested Example: Enable I/O Threads

```bash
# Start Valkey with 4 I/O threads (3 workers + 1 main)
docker run -d --name valkey-io -p 6379:6379 valkey/valkey:9 \
  valkey-server --io-threads 4 --save ""

# Verify the setting
valkey-cli CONFIG GET io-threads
# Expected: io-threads = 4

# Quick benchmark to exercise I/O threads
docker exec valkey-io valkey-benchmark -t set,get -c 100 -n 100000 -q

# Check if I/O threads activated under load
valkey-cli INFO server | grep io_threads_active
# Expected: io_threads_active:1 (under load)

# Adjust at runtime (no restart needed)
valkey-cli CONFIG SET io-threads 2
valkey-cli CONFIG GET io-threads
# Expected: io-threads = 2
```

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

| Available Cores | Recommended `io-threads` | Rationale |
|-----------------|--------------------------|-----------|
| 4 | 2 | Leave cores for main thread + OS. Over-subscribing hurts - a Raspberry Pi CM4 dropped from 416K to 336K RPS with io-threads=5 on 4 cores. |
| 8 | 5-6 | Reserve 2 cores for IRQ affinity, 1 for main thread, rest for I/O. |
| 16 | 8-9 | Best tested config: 8 I/O threads + main on c7g.4xlarge (16 ARM cores) reached 1.19M RPS. |
| 64 (e.g. c7g.16xlarge) | 6 | 1B RPS cluster setup uses 2 cores for IRQ, 6 for valkey-server per node. More threads not needed per shard. |

Key rule: never set io-threads >= number of available cores. Over-subscribing
causes context switching that degrades performance. On a 4-core Raspberry Pi,
io-threads=2 with prefetch reached 760K RPS while io-threads=5 only managed
336K RPS.

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

From Valkey benchmarks on AWS c7g.4xlarge (16-core ARM, 650 clients, 512-byte
values, 3M keys):

| Config | Throughput (SET RPS) | Avg Latency |
|--------|---------------------|-------------|
| `io-threads 1` (Valkey 7.2) | ~360K | 1.792ms |
| `io-threads 9` + prefetch (Valkey 8.0) | 1.19M | 0.542ms |

That is a 230% throughput improvement and 69.8% latency reduction.

The bottleneck in high-throughput scenarios is memory access latency, not CPU
compute. I/O threads parallelize the memory-intensive read/write/parse work.
Combined with batch key prefetching, this amortizes cache misses across commands.
Profiling shows `lookupKey` consumed >40% of main thread time due to cache
misses before prefetching was added.

### Reproducing 1.19M RPS

```bash
# 1. Pin network IRQs to 2 dedicated cores
for i in {48..51}; do echo 1000 > /proc/irq/$i/smp_affinity; done
for i in {52..55}; do echo 2000 > /proc/irq/$i/smp_affinity; done

# 2. Start server with 9 threads (8 I/O + 1 main)
./valkey-server --io-threads 9 --save "" --protected-mode no

# 3. Pin main thread to core 3 (avoid IRQ cores)
sudo taskset -cp 3 $(pidof valkey-server)

# 4. Run benchmark from a SEPARATE machine
./valkey-benchmark -t set -d 512 -r 3000000 -c 650 \
  --threads 50 -h "host-name" -n 100000000000
```

Key details: match client `--threads` to available load-generation capacity.
Run the benchmark from a different host - never on the same machine as the
server.

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
`io_threads_active` to check if I/O threads are active (0=off, 1=on).

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
- [Latency Diagnosis](latency.md) - troubleshooting latency with I/O threads
- [Slow Command Investigation](../troubleshooting/slow-commands.md) - when slow commands, not I/O, are the bottleneck
- [Configuration Essentials](../configuration/essentials.md) - `io-threads` config reference
- [Monitoring Metrics](../monitoring/metrics.md) - `io_threads_active` and throughput metrics
- [Kubernetes StatefulSets](../kubernetes/statefulset.md) - CPU resource sizing for I/O threads in containers
- [Kubernetes Tuning](../kubernetes/tuning-k8s.md) - kernel and CPU tuning for I/O threads in K8s
- [See valkey-dev: io-threads](../../../valkey-dev/reference/threading/io-threads.md) - internal architecture, job queue design
- [See valkey-dev: prefetch](../../../valkey-dev/reference/threading/prefetch.md) - batch key prefetching
