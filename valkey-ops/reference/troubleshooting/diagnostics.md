# Diagnostics Reference

Use when investigating fork latency, running memory tests, or as a quick
reference for Valkey diagnostic commands. Covers the general investigation
workflow for any production issue.

---

## 7-Phase Diagnostic Runbook

When investigating a production issue, run this sequence:

```bash
# Phase 1: Quick assessment (< 30 seconds)
valkey-cli PING                          # Is it responsive?
valkey-cli INFO server | head -20        # Version, uptime, mode
valkey-cli LATENCY LATEST                # Any recent spikes?
valkey-cli SLOWLOG GET 5                 # Recent slow commands?

# Phase 2: Memory health (< 1 minute)
valkey-cli INFO memory                   # Full memory picture
valkey-cli MEMORY DOCTOR                 # Automated memory diagnosis

# Phase 3: Latency analysis (< 1 minute)
valkey-cli LATENCY DOCTOR                # Automated latency diagnosis
valkey-cli --intrinsic-latency 10        # 10s baseline test (run on server)

# Phase 4: Replication health (if applicable)
valkey-cli INFO replication              # Lag, link status, backlog

# Phase 5: Client analysis (< 1 minute)
valkey-cli INFO clients                  # Connection counts
valkey-cli CLIENT LIST                   # Per-client details

# Phase 6: Cluster health (if applicable)
valkey-cli CLUSTER INFO                  # Cluster state
valkey-cli CLUSTER NODES                 # Node health
valkey-cli --cluster check <ip>:<port>   # Slot coverage

# Phase 7: Persistence health
valkey-cli INFO persistence              # RDB/AOF status, COW size, fork time
```

After gathering data, follow the general workflow:
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
with the dataset size. Formula: `page_table_size = (dataset / 4KB) * 8 bytes`.

| Dataset | Page Table Copy | Typical Fork Time |
|---------|----------------|-------------------|
| 1 GB | 2 MB | 10-20 ms |
| 8 GB | 16 MB | 80-160 ms |
| 24 GB | 48 MB | 240-480 ms |
| 64 GB | 128 MB | 640-1280 ms |

Fork rate quality thresholds (used by LATENCY DOCTOR in `src/latency.c`):

| Environment | Fork Rate | Quality |
|-------------|-----------|---------|
| Bare metal, SSD | > 100 GB/s | Excellent |
| Good VM | 25-100 GB/s | Good |
| Average VM | 10-25 GB/s | Poor |
| Bad VM (Xen) | < 10 GB/s | Terrible |

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
| `TYPE <key>` | Data type (string, list, set, zset, hash, stream) |
| `SCAN 0 MATCH <pattern> COUNT n` | Iterate keyspace without blocking |

### Cluster

| Command | Purpose |
|---------|---------|
| `CLUSTER INFO` | Cluster state summary |
| `CLUSTER NODES` | Full node topology |
| `CLUSTER SLOTS` | Slot-to-node mapping |
| `CLUSTER MYID` | Current node's ID |
| `CLUSTER COUNTKEYSINSLOT <slot>` | Keys in a specific slot |

## Real Incident Patterns

### Mass Key Expiration Spike

**Symptoms**: Periodic latency spikes every N seconds, `expire-cycle` events
in latency monitor.

**Root cause**: Application sets thousands of keys with identical TTL (e.g.,
cache TTL aligned to clock boundaries). When the expiration second arrives,
the active expiry cycle finds > 25% of sampled keys expired and loops
aggressively, blocking the main thread.

**Resolution**: Add jitter to TTLs:
`EXPIRE key (base_ttl + random(0, jitter_seconds))`. Monitor with
`LATENCY HISTORY expire-cycle`.

### THP-Induced Latency After BGSAVE

**Symptoms**: Periodic 500ms-2s latency spikes correlated with BGSAVE schedule.
`latest_fork_usec` shows 50ms, but `rdb_last_cow_size` is nearly equal to
`used_memory` (near-complete COW).

**Root cause**: THP enabled. After fork, every page touched triggers a 2MB COW
copy instead of 4KB.

**Resolution**: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`

### Pub/Sub Subscriber OOM

**Symptoms**: Memory usage growing unboundedly, eventually OOM kill.
`CLIENT LIST` shows pub/sub clients with `omem` in the hundreds of MB.

**Root cause**: Slow subscriber cannot consume messages fast enough. Output
buffer grows without limit.

**Resolution**: Set strict limits:
`CONFIG SET client-output-buffer-limit pubsub 32mb 8mb 60`. Implement
application-level backpressure. Use `maxmemory-clients` to cap aggregate
client memory.

### Replica Cascade Full Resync

**Symptoms**: Repeated full resyncs (`sync_full` incrementing), spike in primary
memory during BGSAVE, high I/O.

**Root cause**: Replication backlog too small (default 10MB). Brief network glitch
overflows the backlog, full resync fork causes latency spike, which disconnects
other replicas.

**Resolution**: Increase `repl-backlog-size` to >= 512MB. Enable
`repl-diskless-sync yes`. Monitor `sync_partial_err`.

### Swap-Induced Latency

**Symptoms**: Sporadic 100ms+ latency spikes unrelated to commands.
`--intrinsic-latency` shows normal baseline.

**Root cause**: Some Valkey memory pages swapped to disk.

**Diagnosis**:
```bash
REDIS_PID=$(valkey-cli INFO server | grep process_id | cut -d: -f2 | tr -d '\r')
cat /proc/$REDIS_PID/smaps | grep '^Swap:' | grep -v '0 kB'
# Any non-trivial swap entries indicate the problem
```

**Resolution**: Set `maxmemory` well below available RAM. Increase RAM or
reduce dataset size.

### Large Key Migration Blocked (Cluster)

**Symptoms**: Slot migration hangs, slot stuck in `migrating`/`importing` state.

**Root cause**: Very large key exceeds target node's buffer during migration.

**Resolution (pre-9.0)**: Increase `proto-max-bulk-len` on target. Valkey 9.0
fixes this with atomic slot-level migration.

## Quick Health Check Script

```bash
#!/bin/bash
HOST="${1:-127.0.0.1}"; PORT="${2:-6379}"; CLI="valkey-cli -h $HOST -p $PORT"
echo "=== Server ===";      $CLI INFO server | grep -E "valkey_version|uptime_in_days|connected_clients"
echo "=== Memory ===";      $CLI INFO memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio"
echo "=== Persistence ==="; $CLI INFO persistence | grep -E "rdb_last_bgsave_status|aof_last_bgrewrite_status|latest_fork_usec"
echo "=== Replication ==="; $CLI INFO replication | grep -E "role|connected_slaves|master_link_status"
echo "=== Stats ===";       $CLI INFO stats | grep -E "instantaneous_ops_per_sec|rejected_connections|expired_keys|evicted_keys"
echo "=== Latency ===";     $CLI LATENCY LATEST
echo "=== Slow Cmds ===";   $CLI SLOWLOG GET 5
```

---

## See Also

- [Latency Diagnosis](../performance/latency.md) - full latency diagnosis workflow
- [Memory Optimization](../performance/memory.md) - encoding thresholds, memory-efficient modeling
- [Defragmentation](../performance/defragmentation.md) - active defrag for fragmentation issues
- [Troubleshooting OOM](oom.md) - out of memory diagnosis and resolution
- [Slow Command Investigation](slow-commands.md) - slow command patterns and fixes
- [Replication Lag](replication-lag.md) - replication lag diagnosis and resolution
- [Cluster Partition Issues](cluster-partitions.md) - cluster state and failover diagnosis
- [Monitoring Metrics](../monitoring/metrics.md) - INFO metric reference
- [Monitoring Alerting](../monitoring/alerting.md) - alert rules for all diagnostic categories
- [Security ACL](../security/acl.md) - ACL LOG for unauthorized access diagnosis
- [Security Hardening](../security/hardening.md) - security checklist and defense-in-depth layers
- [See valkey-dev: debug](../../../valkey-dev/reference/monitoring/debug.md) - DEBUG command internals, software watchdog
- [See valkey-dev: latency](../../../valkey-dev/reference/monitoring/latency.md) - latency monitor internals
- [See valkey-dev: commandlog](../../../valkey-dev/reference/monitoring/commandlog.md) - commandlog architecture
