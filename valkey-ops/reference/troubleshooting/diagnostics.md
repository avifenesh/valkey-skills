# Diagnostics Reference

Use when investigating fork latency, running memory tests, or as a quick
reference for Valkey diagnostic commands. Covers the general investigation
workflow for any production issue.

---

## General Investigation Workflow

For any production issue, follow this sequence:

1. **Triage** - identify the symptom class (latency, errors, memory, replication)
2. **Baseline** - compare current state against known-good metrics
3. **Narrow** - use diagnostic commands to isolate the subsystem
4. **Root cause** - correlate findings with recent changes or events
5. **Fix** - apply the targeted resolution
6. **Verify** - confirm the fix resolved the issue
7. **Prevent** - add monitoring/alerting to catch recurrence

## Fork Latency

### Symptoms

- `latest_fork_usec` in INFO shows high values (> 100ms for large datasets)
- Clients experience periodic freezes during BGSAVE or BGREWRITEAOF
- Latency monitor shows spikes on the `fork` event

### Diagnosis

```bash
valkey-cli INFO persistence | grep fork
# latest_fork_usec: microseconds of the last fork operation

valkey-cli LATENCY LATEST
# Look for 'fork' event
```

The fork latency is proportional to the size of the page tables, which grows
with the dataset size and memory layout. Typical rates:

| Environment | Fork Rate | Quality |
|-------------|-----------|---------|
| Bare metal, SSD | > 100 GB/s | Excellent |
| Good VM | 25-100 GB/s | Good |
| Average VM | 10-25 GB/s | Poor |
| Bad VM (Xen) | < 10 GB/s | Terrible |

The LATENCY DOCTOR report (source: `src/latency.c`) uses these same thresholds
to rate fork quality and advise on VM upgrades.

### Resolution

1. **Disable Transparent Huge Pages (THP)**

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Persist across reboots (add to /etc/rc.local or systemd unit)
```

THP causes the kernel to allocate 2MB pages instead of 4KB. During fork,
copy-on-write must copy the entire 2MB page when a single byte changes,
causing massive latency spikes. The `createLatencyReport()` function in
`src/latency.c` explicitly checks for THP via `THPGetAnonHugePagesSize()`.

2. **Use diskless replication**

```bash
CONFIG SET repl-diskless-sync yes
```

Avoids fork for sending RDB to replicas by streaming directly over the socket.

3. **Offload BGSAVE to replicas**

Configure replicas to do the RDB saves instead of the primary. This moves
the fork latency to the replica, which typically has a smaller impact.

4. **Use bare metal for large datasets**

VMs add overhead to fork because the hypervisor must copy additional page
table structures. For datasets exceeding 24GB, bare metal can cut fork
latency by 2-10x compared to VMs.

## Memory Testing

Use when experiencing unexplained crashes, data corruption, or intermittent
errors that suggest hardware issues.

### Built-in Memory Test

```bash
# Test 4096 MB of RAM
valkey-server --test-memory 4096
```

This runs a series of memory pattern tests (walking ones, walking zeros,
random patterns) and reports any errors. The test is destructive - do not
run it on a production server that is serving traffic.

### System-Level Memory Test

For thorough testing, use memtest86:

```bash
# Reboot into memtest86
# Most Linux distributions include it in the GRUB boot menu
# Run for at least 2 passes (several hours for large RAM)
```

### When to Test Memory

- Unexplained segfaults in Valkey logs
- Data corruption that persists across restarts
- Valkey crashes at irregular intervals with no pattern
- After hardware changes (new RAM modules, BIOS updates)

## Diagnostic Commands Reference

### Server State

| Command | Purpose |
|---------|---------|
| `INFO [section]` | Server statistics (server, clients, memory, persistence, stats, replication, cpu, modules, keyspace) |
| `CONFIG GET <pattern>` | Current configuration values |
| `DBSIZE` | Number of keys in current database |
| `DEBUG SLEEP <seconds>` | Simulate delay (testing only - never in production) |

### Memory

| Command | Purpose |
|---------|---------|
| `MEMORY DOCTOR` | Automated memory issue analysis |
| `MEMORY USAGE <key> [SAMPLES n]` | Estimated memory for a key (SAMPLES 0 for exact) |
| `MEMORY STATS` | Detailed memory breakdown by category |
| `MEMORY PURGE` | Force jemalloc to release pages to OS |
| `MEMORY MALLOC-STATS` | Raw allocator statistics |

### Latency

| Command | Purpose |
|---------|---------|
| `LATENCY DOCTOR` | Automated latency analysis with advice |
| `LATENCY LATEST` | Most recent spike per event type |
| `LATENCY HISTORY <event>` | Time series for specific event |
| `LATENCY GRAPH <event>` | ASCII visualization of latency over time |
| `LATENCY HISTOGRAM [cmd ...]` | Per-command HdrHistogram distributions |
| `LATENCY RESET [event ...]` | Clear latency data |

### Commandlog (Slowlog)

| Command | Purpose |
|---------|---------|
| `SLOWLOG GET [count]` | Recent slow commands (default 10) |
| `SLOWLOG LEN` | Number of entries in slow log |
| `SLOWLOG RESET` | Clear slow log |
| `COMMANDLOG GET <count> <type>` | Entries by type: slow, large-request, large-reply |
| `COMMANDLOG LEN <type>` | Entry count by type |
| `COMMANDLOG RESET <type>` | Clear entries by type |

### Client Connections

| Command | Purpose |
|---------|---------|
| `CLIENT LIST [TYPE type]` | All connected clients with details |
| `CLIENT INFO` | Current connection details |
| `CLIENT GETNAME` | Current client name |
| `CLIENT KILL <filter>` | Terminate specific connections |
| `CLIENT NO-EVICT on` | Protect current client from eviction |

### Key Inspection

| Command | Purpose |
|---------|---------|
| `OBJECT ENCODING <key>` | Internal encoding (listpack, hashtable, skiplist, etc.) |
| `OBJECT FREQ <key>` | LFU frequency counter (requires LFU policy) |
| `OBJECT IDLETIME <key>` | Seconds since last access (requires LRU policy) |
| `OBJECT REFCOUNT <key>` | Reference count |
| `OBJECT HELP` | List available OBJECT subcommands |
| `TYPE <key>` | Data type (string, list, set, zset, hash, stream) |
| `TTL <key>` | Remaining time to live in seconds |
| `SCAN 0 MATCH <pattern> COUNT n` | Iterate keyspace without blocking |

### Cluster

| Command | Purpose |
|---------|---------|
| `CLUSTER INFO` | Cluster state summary |
| `CLUSTER NODES` | Full node topology |
| `CLUSTER SLOTS` | Slot-to-node mapping |
| `CLUSTER MYID` | Current node's ID |
| `CLUSTER COUNTKEYSINSLOT <slot>` | Keys in a specific slot |

## Quick Health Check Script

```bash
#!/bin/bash
HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"
CLI="valkey-cli -h $HOST -p $PORT"

echo "=== Server ==="
$CLI INFO server | grep -E "valkey_version|uptime_in_days|connected_clients"

echo "=== Memory ==="
$CLI INFO memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio"

echo "=== Persistence ==="
$CLI INFO persistence | grep -E "rdb_last_bgsave_status|aof_last_bgrewrite_status|latest_fork_usec"

echo "=== Replication ==="
$CLI INFO replication | grep -E "role|connected_slaves|master_link_status"

echo "=== Stats ==="
$CLI INFO stats | grep -E "instantaneous_ops_per_sec|rejected_connections|expired_keys|evicted_keys"

echo "=== Latency ==="
$CLI LATENCY LATEST

echo "=== Slow Commands (last 5) ==="
$CLI SLOWLOG GET 5
```

---

## See Also

- [Latency Diagnosis](../performance/latency.md) - full latency diagnosis workflow
- [Troubleshooting OOM](oom.md) - out of memory diagnosis
- [Slow Command Investigation](slow-commands.md) - slow command investigation
- [Monitoring Metrics](../monitoring/metrics.md) - INFO metric reference
- [See valkey-dev: debug](../valkey-dev/reference/monitoring/debug.md) - DEBUG command internals, software watchdog
- [See valkey-dev: latency](../valkey-dev/reference/monitoring/latency.md) - latency monitor internals
- [See valkey-dev: commandlog](../valkey-dev/reference/monitoring/commandlog.md) - commandlog architecture
