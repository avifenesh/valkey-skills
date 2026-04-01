Use when looking up Valkey diagnostic commands, investigating real incident patterns, or running a quick health check script.

# Diagnostic Commands and Incident Patterns

## Contents

- Diagnostic Commands Reference (line 13)
- Real Incident Patterns (line 86)
- Quick Health Check Script (line 163)
- See Also (line 179)

---

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

**Root cause**: Application sets thousands of keys with identical TTL. When
the expiration second arrives, the active expiry cycle finds > 25% of
sampled keys expired and loops aggressively, blocking the main thread.

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

**Root cause**: Some Valkey memory pages swapped to disk.

**Diagnosis**:
```bash
REDIS_PID=$(valkey-cli INFO server | grep process_id | cut -d: -f2 | tr -d '\r')
cat /proc/$REDIS_PID/smaps | grep '^Swap:' | grep -v '0 kB'
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

- [diagnostics-runbook](diagnostics-runbook.md) - 7-phase investigation runbook, fork latency, memory testing
- [oom](oom.md) - Out of memory troubleshooting
- [slow-commands](slow-commands.md) - Slow command investigation
