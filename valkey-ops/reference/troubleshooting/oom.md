# Out of Memory (OOM) Diagnosis and Resolution

Use when Valkey returns OOM errors on writes, the Linux OOM killer terminates
Valkey, or memory usage is approaching limits.

---

## Symptoms

- Write commands return: `OOM command not allowed when used memory > 'maxmemory'`
- Valkey process killed by Linux OOM killer (check `dmesg` or `journalctl`)
- `INFO memory` shows `used_memory` near or exceeding `maxmemory`
- Clients receiving connection reset or timeout errors during memory pressure
- `mem_fragmentation_ratio` significantly above 1.5

## Diagnosis

### Step 1: Check Memory State

```bash
valkey-cli INFO memory | grep -E "used_memory|maxmemory|mem_fragmentation"
```

Key fields:

| Field | What to look for |
|-------|-----------------|
| `used_memory` | Total memory allocated by Valkey |
| `used_memory_rss` | Resident set size from OS perspective |
| `maxmemory` | Configured limit (0 = unlimited - this is the problem) |
| `maxmemory_policy` | Current eviction policy |
| `mem_fragmentation_ratio` | RSS / used_memory. > 1.5 = significant fragmentation |
| `used_memory_dataset` | Memory used by actual data |
| `mem_clients_normal` | Memory consumed by client buffers |
| `mem_clients_slaves` | Memory consumed by replica output buffers |

### Step 2: Run MEMORY DOCTOR

```bash
valkey-cli MEMORY DOCTOR
```

Returns a plain-text diagnostic. Common findings:
- "Peak memory is way larger than used memory" - possible fragmentation
- "High allocator fragmentation" - jemalloc internal fragmentation
- "Sam, I detected a non-trivial amount of memory in client buffers" - client memory issue

### Step 3: Identify Large Keys

```bash
# Find the biggest keys by type
valkey-cli --bigkeys

# Check memory usage of specific keys
valkey-cli MEMORY USAGE <key> SAMPLES 0

# Detailed memory breakdown
valkey-cli MEMORY STATS
```

### Step 4: Check Client Memory

```bash
# List clients sorted by output buffer memory
valkey-cli CLIENT LIST

# Look for clients with high omem (output memory) values
# Also check qbuf (query buffer) for large incoming requests
```

### Step 5: Check System Logs

```bash
# Check if OOM killer has been active
dmesg | grep -i "out of memory"
journalctl -u valkey --since "1 hour ago" | grep -i "oom\|memory"
```

## Resolution

### 1. Set Explicit maxmemory

Source-verified: `maxmemory` defaults to 0 (unlimited) in `src/config.c`
line 3442. This is the most common cause of OOM - Valkey grows until the OS
kills it.

```bash
# Set to 75% of available RAM
valkey-cli CONFIG SET maxmemory 12gb

# Persist
valkey-cli CONFIG REWRITE
```

Reserve at least 25% of RAM for:
- Fork operations (RDB/AOF rewrite can temporarily double memory usage)
- OS file system cache
- Client output buffers
- Fragmentation overhead

### 2. Choose an Eviction Policy

Source-verified: `maxmemory-policy` defaults to `noeviction` in `src/config.c`
line 3339. With `noeviction`, Valkey returns errors rather than evicting data.

```bash
# For cache workloads
valkey-cli CONFIG SET maxmemory-policy allkeys-lfu

# For session stores with TTLs
valkey-cli CONFIG SET maxmemory-policy volatile-lfu
```

### 3. Cap Client Buffer Memory

Source-verified: `maxmemory-clients` defaults to 0 (unlimited) in `src/config.c`
line 3458. Client buffers are not counted against `maxmemory` unless this is set.

```bash
# Cap client memory at 5% of maxmemory
valkey-cli CONFIG SET maxmemory-clients 5%
```

### 4. Address Fragmentation

```bash
# Check fragmentation ratio
valkey-cli INFO memory | grep mem_fragmentation_ratio

# If > 1.5, try purging
valkey-cli MEMORY PURGE

# For persistent fragmentation, enable active defrag
valkey-cli CONFIG SET activedefrag yes
valkey-cli CONFIG SET active-defrag-threshold-lower 10
```

### 5. Enable vm.overcommit_memory

Prevents fork failures during BGSAVE/BGREWRITEAOF. Without this, the kernel
may refuse fork() if it calculates insufficient virtual memory, even though
copy-on-write means actual usage will be much lower.

```bash
sysctl -w vm.overcommit_memory=1
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
```

### 6. Add Swap (Safety Net)

Swap is not a solution but prevents the OOM killer from terminating Valkey.
With swap, Valkey slows down rather than dying.

```bash
# Check current swap
free -h

# Create swap if missing (4GB example)
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

### 7. Review Data Patterns

- Run `--bigkeys` scan to find oversized keys
- Check if collections are growing unbounded (missing TTLs)
- Verify batch jobs are not loading excessive data
- Check for pub/sub clients with large output buffers

## Prevention

```bash
# Production baseline configuration
maxmemory 12gb
maxmemory-policy allkeys-lfu
maxmemory-clients 5%

# Alert thresholds (configure in your monitoring)
# WARN: used_memory > 70% of maxmemory
# CRITICAL: used_memory > 85% of maxmemory
# CRITICAL: mem_fragmentation_ratio > 2.0
```

---

## See Also

- [Memory Optimization](../performance/memory.md) - encoding thresholds, memory-efficient data modeling
- [Defragmentation](../performance/defragmentation.md) - active defrag configuration
- [Eviction Policies](../configuration/eviction.md) - maxmemory-policy selection
- [Capacity Planning](../operations/capacity-planning.md) - memory sizing guidelines
- [Monitoring Alerting](../monitoring/alerting.md) - memory alert rules
- [See valkey-dev: zmalloc](../valkey-dev/reference/memory/zmalloc.md) - allocator internals, per-thread counters
- [See valkey-dev: defragmentation](../valkey-dev/reference/memory/defragmentation.md) - active defragmentation implementation
