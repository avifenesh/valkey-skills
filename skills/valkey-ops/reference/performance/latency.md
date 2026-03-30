# Latency Diagnosis

Use when investigating latency spikes, establishing baseline latency, analyzing
slow commands, or using LATENCY DOCTOR for automated diagnostics.

---

## Diagnosis Workflow

1. Measure intrinsic (baseline) latency
2. Enable the latency monitor
3. Check LATENCY DOCTOR for automated analysis
4. Inspect commandlog (slowlog) for specific slow commands
5. Review CLIENT LIST for blocked or overloaded connections
6. Check persistence and fork impact

## Step 1: Measure Intrinsic Latency

Run this on the Valkey server itself (not remotely) to establish the OS/hardware
latency floor:

```bash
valkey-cli --intrinsic-latency 100    # Run for 100 seconds
```

This measures the minimum scheduling latency of the OS and hypervisor. Results
above 1ms indicate a noisy environment (VM contention, CPU throttling, etc.).
You cannot achieve application latency below this floor.

### Measure Client-Server Latency

From the client machine:

```bash
valkey-cli --latency -h <host> -p <port>
# Continuous mode - shows min/max/avg over time

valkey-cli --latency-history -h <host> -p <port>
# Shows latency in 15-second windows
```

## Step 2: Enable Latency Monitor

Source-verified: `latency-monitor-threshold` defaults to 0 (disabled) in
`src/config.c` line 3435. When disabled, the monitoring macros in `src/latency.c`
short-circuit with zero overhead.

```bash
# Enable - log events taking >= 100ms
valkey-cli CONFIG SET latency-monitor-threshold 100

# For more sensitive monitoring
valkey-cli CONFIG SET latency-monitor-threshold 10
```

The threshold applies globally to all event types. Any operation exceeding
this value is recorded in a per-event circular buffer of 160 samples
(`LATENCY_TS_LEN = 160` in `src/latency.h`).

### Monitored Event Types

Source-verified from `src/latency.c` (the LATENCY DOCTOR report generator):

| Event | What it measures |
|-------|-----------------|
| `command` | Slow command execution |
| `fast-command` | Commands that should be fast but exceeded threshold |
| `fork` | fork() for RDB/AOF background save |
| `expire-cycle` | Active expiration sweep |
| `eviction-cycle` | Memory eviction loop |
| `eviction-del` | Individual key eviction |
| `aof-write-pending-fsync` | AOF write while fsync is pending |
| `aof-write-active-child` | AOF write during child rewrite |
| `aof-write-alone` | AOF write with no contention |
| `aof-fsync-always` | AOF fsync in `always` mode |
| `aof-fstat` / `aof-rename` | AOF file operations |
| `active-defrag-cycle` | Active defragmentation |

## Step 3: LATENCY DOCTOR

```bash
valkey-cli LATENCY DOCTOR
```

This runs `createLatencyReport()` in `src/latency.c`, which analyzes all
recorded events, computes statistics (average, MAD, min, max, all-time high),
and generates specific remediation advice.

The report checks for:
- THP (Transparent Huge Pages) impact via `/proc/self/smaps`
- Fork rate quality (terrible < 10 GB/s, poor < 25, good < 100, excellent >= 100)
- Commandlog configuration (whether slow logging is enabled and properly tuned)
- Disk contention indicators
- CPU scheduling issues

Example output:

```
Latency spikes are observed in this Valkey instance.

1. command: 5 latency spikes (average 300ms, mean deviation 120ms,
   period 73.40 sec). Worst all time event 500ms.

Here is some advice for you:

- Check your Slow Log to understand what commands are too slow to execute.
- The system is slow to execute code paths not containing system calls.
  Check with 'valkey-cli --intrinsic-latency 100' what is the intrinsic
  latency in your system.
```

### Other LATENCY Subcommands

```bash
# Most recent spike per event type
LATENCY LATEST

# Time series for a specific event
LATENCY HISTORY command

# ASCII graph of latency over time
LATENCY GRAPH command

# Per-command latency histograms (HdrHistogram-based)
LATENCY HISTOGRAM GET SET HGET

# Clear all latency data
LATENCY RESET
```

## Step 4: Commandlog (Slowlog) Analysis

Valkey's commandlog (evolved from slowlog) records commands exceeding thresholds
across three dimensions. Source-verified defaults from `src/config.c`:

| Config | Alias | Default | Unit |
|--------|-------|---------|------|
| `commandlog-execution-slower-than` | `slowlog-log-slower-than` | 10000 | microseconds (10ms) |
| `commandlog-request-larger-than` | - | 1048576 | bytes (1MB) |
| `commandlog-reply-larger-than` | - | 1048576 | bytes (1MB) |
| `commandlog-slow-execution-max-len` | `slowlog-max-len` | 128 | entries |

```bash
# View slow commands (legacy interface, still works)
SLOWLOG GET 25

# New interface with type selection
COMMANDLOG GET 25 slow
COMMANDLOG GET 25 large-request
COMMANDLOG GET 25 large-reply

# Each entry shows:
# - Unique ID
# - Unix timestamp
# - Duration (microseconds) or size (bytes)
# - Command + arguments
# - Client IP:port
# - Client name
```

### Tuning Commandlog Thresholds

```bash
# Log commands slower than 5ms (more sensitive)
CONFIG SET commandlog-execution-slower-than 5000

# Increase history for more data
CONFIG SET commandlog-slow-execution-max-len 256

# Log large requests over 512KB
CONFIG SET commandlog-request-larger-than 524288
```

## Step 5: Client Analysis

```bash
# List all connected clients
CLIENT LIST

# Key fields to check:
# age     - connection age in seconds
# idle    - idle time in seconds
# cmd     - last command
# qbuf    - query buffer length
# omem    - output buffer memory
# flags   - client flags (S=replica, M=master, x=MULTI, b=blocked)
```

Look for clients with high `omem` (output buffer memory), long-running `cmd`,
or `flags` containing `b` (blocked).

## Step 6: Software Watchdog (Emergency)

For severe, hard-to-reproduce stalls, enable the software watchdog temporarily.
Source-verified: `watchdog-period` defaults to 0 (disabled), `src/config.c`
line 3400.

```bash
# Enable watchdog - generates stack traces for stalls > 500ms
CONFIG SET watchdog-period 500

# ALWAYS disable when done
CONFIG SET watchdog-period 0
```

The watchdog uses SIGALRM to interrupt the main thread and log a stack trace.
This has overhead - use only during active investigation.

## Transparent Huge Pages - The #1 Linux Misconfiguration

THP is the single most common Linux misconfiguration for Valkey. When enabled,
after fork, copy-on-write operates on 2MB pages instead of 4KB. A write to any
byte in a 2MB huge page forces the entire 2MB to be copied. In a busy instance,
a few event loops can trigger near-complete COW of the entire process memory.

Diagnosis: `rdb_last_cow_size` (in `INFO persistence`) approaching
`used_memory` is a strong indicator that THP is the cause.

```bash
# Check THP status
cat /sys/kernel/mm/transparent_hugepage/enabled
# If output contains [always] or [madvise], THP is active

# Disable immediately
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# Persist across reboots (add to systemd unit or /etc/rc.local)
```

### Network Latency Reference

| Connection Type | Typical Latency |
|----------------|----------------|
| 1 Gbit/s network | ~200 us |
| Loopback (localhost) | ~50-100 us |
| Unix domain socket | ~30 us |

## Common Latency Causes

| Cause | Indicator | Fix |
|-------|-----------|-----|
| THP enabled | `rdb_last_cow_size` near `used_memory`, LATENCY DOCTOR warns | `echo never > /sys/kernel/mm/transparent_hugepage/enabled` |
| Slow commands | commandlog entries, `command` event | Use SCAN instead of KEYS, UNLINK instead of DEL |
| Fork latency | `fork` event, `latest_fork_usec` | Disable THP, use diskless replication |
| AOF fsync | `aof-fsync-always` event | Switch to `appendfsync everysec` |
| Disk I/O contention | `aof-write-*` events | Use SSD, local disk, `data=writeback` |
| Expiration storms | `expire-cycle` event | Jitter TTLs, tune `hz` |
| Mass eviction | `eviction-cycle` event | Increase maxmemory, use LFU |
| Swapping | Sporadic 100ms+ spikes unrelated to commands | Set maxmemory, check `/proc/<pid>/smaps` for swap entries |
| Noisy neighbor (VM) | High intrinsic latency | Dedicated instance or bare metal |

---

## See Also

- [Commandlog](../monitoring/commandlog.md) - slow command, large request/reply logging
- [Slow Command Investigation](../troubleshooting/slow-commands.md) - specific slow command patterns
- [Diagnostics Reference](../troubleshooting/diagnostics.md) - 7-phase diagnostic runbook, fork latency
- [Troubleshooting OOM](../troubleshooting/oom.md) - memory pressure as latency contributor
- [Monitoring Metrics](../monitoring/metrics.md) - performance metrics and thresholds
- [Monitoring Alerting](../monitoring/alerting.md) - latency alert rules
- [Defragmentation](defragmentation.md) - defrag-related latency
- [I/O Threads](io-threads.md) - throughput optimization to reduce I/O-bound latency
- [Kubernetes Tuning](../kubernetes/tuning-k8s.md) - THP and kernel settings affecting latency in containers
- [See valkey-dev: latency](../../../valkey-dev/reference/monitoring/latency.md) - latency monitor internals, event types, HdrHistogram integration
- [See valkey-dev: commandlog](../../../valkey-dev/reference/monitoring/commandlog.md) - commandlog architecture, entry format
- [See valkey-dev: debug](../../../valkey-dev/reference/monitoring/debug.md) - software watchdog, DEBUG commands
