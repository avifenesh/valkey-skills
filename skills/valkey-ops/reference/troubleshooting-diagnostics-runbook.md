# Diagnostics Runbook

Use when investigating a production Valkey issue - the 7-phase diagnostic runbook, fork latency diagnosis, and memory testing.

## Contents

- 7-Phase Diagnostic Runbook (line 14)
- Fork Latency (line 58)
- Memory Testing (line 130)

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
```

THP causes the kernel to allocate 2MB pages instead of 4KB. During fork,
copy-on-write must copy the entire 2MB page when a single byte changes.
The `createLatencyReport()` function in `src/latency.c` explicitly checks
for THP via `THPGetAnonHugePagesSize()`.

2. **Use diskless replication**

```bash
CONFIG SET repl-diskless-sync yes
```

Avoids fork for sending RDB to replicas by streaming directly over the socket.

3. **Offload BGSAVE to replicas**

Configure replicas to do the RDB saves instead of the primary. This moves
the fork latency to the replica, which has a smaller impact on client-facing traffic.

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

For thorough testing, use memtest86. Most Linux distributions include it
in the GRUB boot menu. Run for at least 2 passes (several hours for large RAM).

### When to Test Memory

- Unexplained segfaults in Valkey logs
- Data corruption that persists across restarts
- Valkey crashes at irregular intervals with no pattern
- After hardware changes (new RAM modules, BIOS updates)

---

## See Also

- [diagnostics-commands](diagnostics-commands.md) - Diagnostic command reference, incident patterns, health script
- [oom](oom.md) - Out of memory troubleshooting
- [slow-commands](slow-commands.md) - Slow command investigation
