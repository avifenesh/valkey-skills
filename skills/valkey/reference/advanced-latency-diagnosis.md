# Latency Diagnosis for Application Developers

Use when investigating high p99 latency, intermittent timeouts, slow command execution, or trying to determine whether latency is caused by the network, the server, or your command patterns.

## Contents

- End-to-End Diagnosis Workflow (line 12)
- Step 1: Establish Baselines (line 23)
- Step 2: Check the Latency Monitor (line 53)
- Step 3: Correlate with COMMANDLOG (line 95)
- Step 4: Common Latency Sources (line 126)
- Step 5: Event Loop and I/O Thread Impact (line 166)
- Practical Playbook: "Client Reports High p99" (line 193)

---

## End-to-End Diagnosis Workflow

Latency has three components and you need to isolate which one is the problem:

1. **Network latency** - time for the request to travel from client to server and back
2. **Queue latency** - time the command waits in the server's input buffer before execution
3. **Command execution latency** - time the server spends executing the command

Most applications measure only the total round-trip. The diagnosis tools below let you decompose it.

---

## Step 1: Establish Baselines

### Intrinsic Latency (Server-Side Floor)

Run this **on the server host itself** to measure the minimum scheduling latency of the OS and hypervisor:

```bash
valkey-cli --intrinsic-latency 100
# Runs for 100 seconds, reports min/max/avg
# Max latency so far: 83 microseconds
```

This is the floor. You cannot achieve application latency below this. Values above 1 ms indicate a noisy environment - VM contention, CPU throttling, or NUMA effects. On bare metal, expect < 100 microseconds.

### Network Latency (Client to Server)

From the **client machine**:

```bash
# Continuous measurement - shows running min/max/avg
valkey-cli --latency -h <host> -p 6379

# Windowed measurement - shows latency in 15-second buckets
valkey-cli --latency-history -h <host> -p 6379

# Distribution - collects samples and shows a spectrum
valkey-cli --latency-dist -h <host> -p 6379
```

`--latency` sends PING commands and measures round-trip time. Compare the result against the intrinsic latency. If network latency is 10x or more above intrinsic latency, the network is the bottleneck, not Valkey.

| Connection Type | Typical Round-Trip |
|----------------|-------------------|
| Loopback (localhost) | 50-100 us |
| Same-AZ network (1 Gbit) | 150-300 us |
| Cross-AZ | 500 us - 2 ms |
| Cross-region | 10-100 ms |

---

## Step 2: Check the Latency Monitor

### Enable the Monitor

The latency monitor is **disabled by default** (threshold is 0). Enable it before diagnosis:

```
CONFIG SET latency-monitor-threshold 5
```

This records any internal operation exceeding 5 ms. Set a lower threshold for latency-sensitive applications. The overhead is negligible when enabled.

### LATENCY Subcommands

```
LATENCY LATEST              # Most recent spike per event: [event, timestamp, latency_ms, max_ms]
LATENCY HISTORY <event>     # Up to 160 timestamped samples: [timestamp, latency_ms]
LATENCY GRAPH <event>       # ASCII sparkline chart of latency over time
LATENCY DOCTOR              # Automated analysis with remediation advice
LATENCY RESET [event ...]   # Clear recorded data
```

Use `LATENCY HISTORY` to correlate spikes with external events (deployments, traffic bursts, backup jobs).

### Key Event Types to Check

| Event | What It Means |
|-------|--------------|
| `command` | A command took longer than the threshold to execute. Check COMMANDLOG for which command. |
| `fast-command` | A command expected to be O(1) exceeded the threshold. Indicates system-level issues, not bad queries. |
| `fork` | RDB save or AOF rewrite triggered a fork. Large datasets cause pauses of 1-2 ms per GB. |
| `expire-cycle` | Active expiration is finding many expired keys. Indicates bursty TTL expirations. |
| `active-defrag-cycle` | Active defragmentation is consuming measurable CPU. |
| `aof-fsync-always` | AOF fsync in `always` mode is blocking the main thread. |
| `aof-write-pending-fsync` | AOF write is delayed because a previous fsync has not finished. Indicates disk contention. |

Always run `LATENCY DOCTOR` first - it checks for THP, evaluates fork speed, and suggests specific fixes automatically.

---

## Step 3: Correlate with COMMANDLOG

The latency monitor tells you **what subsystem** is slow. COMMANDLOG tells you **which specific commands** are slow.

### Check All Three Dimensions

```
# Slow commands (execution time > threshold)
COMMANDLOG GET 25 slow

# Large requests (payload > threshold)
COMMANDLOG GET 25 large-request

# Large replies (response > threshold)
COMMANDLOG GET 25 large-reply
```

Each entry shows the command, its duration in microseconds, the client address, and client name (from `CLIENT SETNAME`).

### Common Offenders

| Command Pattern | Why It Is Slow | Fix |
|----------------|---------------|-----|
| `KEYS *` or `KEYS prefix:*` | O(N) scan of entire keyspace | Use `SCAN` with cursor |
| `HGETALL` on large hash | Serializes thousands of fields | Use `HSCAN` or `HMGET` specific fields |
| `SMEMBERS` on large set | Serializes entire set | Use `SSCAN` with cursor |
| `SORT` on large list | O(N log N) sort | Pre-sort in application or use sorted set |
| `DEL` on large key | Frees millions of allocations synchronously | Use `UNLINK` (async free) |
| `LRANGE 0 -1` on large list | Returns entire list | Paginate with explicit ranges |

### Tuning Thresholds

```
# Lower the slow command threshold to catch more queries
CONFIG SET commandlog-execution-slower-than 5000    # 5 ms instead of default 10 ms

# Increase the log length to capture more entries
CONFIG SET commandlog-slow-execution-max-len 256    # Default: 128
```

---

## Step 4: Common Latency Sources

### Fork Latency (RDB Save, AOF Rewrite)

Every RDB snapshot and AOF rewrite calls `fork()`. Fork time scales with dataset size:

| Dataset Size | Approximate Fork Time |
|-------------|----------------------|
| 1 GB | 1-2 ms |
| 10 GB | 10-20 ms |
| 25 GB | 25-50 ms |
| 64 GB | 64-130 ms |

During the fork, all clients are paused. Check `INFO persistence` for `latest_fork_usec` to see the last fork duration.

**Transparent Huge Pages (THP)** make this dramatically worse. With THP enabled, copy-on-write operates on 2 MB pages instead of 4 KB. A write to any byte in a huge page copies the entire 2 MB. Symptom: `rdb_last_cow_size` in `INFO persistence` approaches `used_memory`. Disable THP on all Valkey hosts.

### Lazy Expiry and Active Expiration

Valkey expires keys lazily on access and actively via a periodic sweep that samples random keys with TTLs. If > 25% of sampled keys are expired, the sweep loops immediately. A burst of expirations (all session keys expire at the same time) can block the main thread for multiple milliseconds.

Fix: **jitter your TTLs**. Instead of `SET key val EX 3600`, use `SET key val EX <3600 + random(0, 300)>`. This spreads expirations over a 5-minute window.

### Disk I/O

With `appendfsync everysec`, a background thread handles fsync. But if fsync takes longer than 1 second (disk contention), the main thread delays new writes for up to 1 additional second. Symptom: `aof-write-pending-fsync` events in `LATENCY LATEST`.

### Swapping

If the OS swaps Valkey pages to disk, latency spikes are severe and unpredictable (10-100 ms per swapped page access). Fix: set `maxmemory` to ~75% of available RAM.

---

## Step 5: Event Loop and I/O Thread Impact

### Event Loop Latency

The Valkey main thread runs a single event loop: read commands, execute commands, write responses, run periodic tasks. If any step takes too long, all other clients wait. Check `INFO latencystats` for `eventloop_duration_sum` and `eventloop_duration_cmd_sum`. If command execution dominates, look at COMMANDLOG. If not, the event loop is spending time on I/O, persistence, or periodic tasks.

### I/O Threading (Valkey 8.0+)

I/O threads handle network read/write on separate threads, freeing the main thread for command execution. With I/O threads enabled, high p99 is more likely caused by slow commands than I/O bottlenecks. Without them, a burst of clients sending large requests queues up, inflating tail latency.

If your p99 is high but p50 is normal and COMMANDLOG shows no slow commands, the issue is likely queue latency from too many concurrent clients on too few I/O threads. Coordinate with ops to increase `io-threads`.

---

## Practical Playbook: "Client Reports High p99"

Follow this sequence when a client application reports intermittent high latency:

**1. Quantify the problem**
```
valkey-cli --latency-history -h <host> -p 6379
# Watch for 60 seconds. Note the pattern - constant or periodic spikes?
```

**2. Check for obvious system issues**
```
valkey-cli INFO memory | grep -E "mem_fragmentation|used_memory_rss"
# Fragmentation > 2.0? See advanced-memory-defrag.
# RSS near system RAM? Possible swapping.

valkey-cli INFO persistence | grep latest_fork_usec
# Fork time > 50ms? Large dataset + frequent saves.
```

**3. Enable latency monitoring (if not already on)**
```
CONFIG SET latency-monitor-threshold 5
```

**4. Check LATENCY DOCTOR**
```
LATENCY DOCTOR
# Follow its advice. It catches THP, fork issues, and disk contention.
```

**5. Inspect COMMANDLOG**
```
COMMANDLOG GET 25 slow
# Identify the specific commands causing spikes.
```

**6. Isolate network vs server latency**
```bash
# From the client host
valkey-cli --latency -h <host> -p 6379
# Note the baseline

# From the server itself
valkey-cli --latency -h 127.0.0.1 -p 6379
# If server-local latency is low but remote is high, it is the network.
```

**7. Check for blocking operations**
```
CLIENT LIST
# Look for clients with flags containing 'b' (blocked) or high 'omem' (output buffer)
```

**8. Review application patterns**
- Replace `KEYS` with `SCAN`, `DEL` on large keys with `UNLINK`
- Add jitter to identical TTLs to prevent expiration storms
- Enable pipelining if not already used
- Set `CLIENT SETNAME` so COMMANDLOG entries trace back to your service

**9. Use per-command histograms** - `LATENCY HISTOGRAM GET SET HGET HSET` shows latency distributions in microseconds. Look for long-tail entries.

**10. Coordinate with ops** for server-side fixes: reduce save frequency (fork pauses), move to SSD (disk contention), enable active defrag (high fragmentation), increase `io-threads` (queue latency).

---
