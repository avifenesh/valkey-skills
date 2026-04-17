# I/O Threads

Use when deciding whether to enable I/O threads and how many to run.

## What I/O threads do

Command execution stays **single-threaded** on the main thread. I/O threads only handle socket read/write, RESP parsing, and response serialization. No data-structure locking - parallelism is strictly in the I/O path. Each worker has its own SPSC queue; clients are assigned to threads deterministically by `client-id % (active-threads - 1) + 1`, so the same client always maps to the same thread for cache locality.

Under TLS, `SSL_accept` also runs on I/O threads automatically via `trySendAcceptToIOThreads` - see `security-tls.md`.

## Config

| Parameter | Default | Notes |
|-----------|---------|-------|
| `io-threads` | `1` | Total including main. `io-threads 4` = main + 3 workers. Range 1-256. Runtime-modifiable (DEBUG_CONFIG). |
| `events-per-io-thread` | `2` | HIDDEN_CONFIG on 9.0. Events needed per active worker. `0` = always offload. |
| `min-io-threads-avoid-copy-reply` | `7` | HIDDEN_CONFIG. At ≥ this many threads, the zero-copy reply path kicks in. |
| `io-threads-do-reads` | (deprecated) | Silently accepted. Reads are always offloaded when workers exist. |

## Dynamic activation

Workers park on a per-thread mutex when idle and unpark when load rises. The scaling formula (9.0):

```
target = clamp(numevents / events-per-io-thread, 1, io-threads)
```

Setting `io-threads 8` doesn't spin 8 threads constantly - they activate on demand. Monitor `io_threads_active` in `INFO stats` to see what's actually running.

## When to enable

- Throughput-bound workload, many concurrent clients, spare cores.
- Main thread is near-saturated on read/write (visible in CPU profiling as time in `readQueryFromClient` / `sendReplyToClient`).

When NOT to enable:

- 2-core boxes (context switching costs more than the I/O parallelism buys).
- Latency-sensitive low-RPS workloads (the handoff adds a few microseconds per request).
- Memory or eviction-bound workloads (I/O threads don't help those paths).

## Sizing

Rule: never set `io-threads` ≥ the number of physical cores available. Over-subscription adds context switches that hurt throughput.

| Cores | Reasonable `io-threads` | Rationale |
|-------|------------------------|-----------|
| 4 | 2 | Leave main + OS + IRQs headroom. |
| 8 | 5-6 | 1-2 cores for IRQ affinity, 1 for main, rest I/O. |
| 16 | 8-9 | Common sweet spot on bigger boxes. |
| 32+ | 6-8 | Gains flatten - you're single-main-thread limited on command execution. |

A 4-core Raspberry Pi CM4 case study: `io-threads 2` reached ~760K RPS; `io-threads 5` dropped to ~336K RPS. Over-subscription is real.

## IRQ affinity for high-throughput nodes

On a big server (32+ cores) where you're chasing the highest numbers:

1. Pin NIC IRQs to dedicated cores (`/proc/irq/<n>/smp_affinity`).
2. Set `server-cpulist` to the remaining cores.
3. Set `bio-cpulist` on a separate NUMA node if applicable.

Don't do this on a shared VM - the underlying CPU topology isn't under your control.

## Client-side threading

`valkey-benchmark --threads N` is the **client** thread count (separate from server `io-threads`). To stress-test server I/O threading, the benchmark client needs enough threads to saturate server sockets - usually `--threads 50` or more from a different host.

## Troubleshooting

- **No throughput gain after enabling**: workload might not be I/O-bound. Profile `main` thread CPU; if `readQueryFromClient` / `sendReplyToClient` aren't the top symbols, I/O threads won't help.
- **Latency up after enabling**: too few cores for the thread count. Reduce `io-threads`.
- **`io_threads_active` stays at 1**: dynamic activation requires enough concurrent events. Temporarily set `events-per-io-thread 0` to force all workers active during testing.
