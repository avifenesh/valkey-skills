# Diagnostic Commands and Incident Patterns

Use as a command cheat-sheet and a collection of Valkey-specific incident patterns.

The command reference below is Redis-standard except for `COMMANDLOG` and cluster additions. For the full per-command docs, the official site or `HELP` output is authoritative.

## Command cheat sheet

| Category | Command | Notes |
|---------|---------|-------|
| Server | `INFO [section]` | Valkey-specific sections: `tls`, `clients_statistics`, module-loaded sections. |
| Memory | `MEMORY DOCTOR / USAGE / STATS / PURGE / MALLOC-STATS` | |
| Latency | `LATENCY DOCTOR / LATEST / HISTORY <event> / GRAPH <event> / HISTOGRAM [cmd ...] / RESET` | |
| Commandlog | `COMMANDLOG GET <count> <type> / LEN <type> / RESET <type>` | `type` = `slow` / `large-request` / `large-reply`. `SLOWLOG *` is alias for `slow`. |
| Clients | `CLIENT LIST [TYPE type] / INFO / GETNAME / KILL <filter> / NO-EVICT on` | |
| Keys | `OBJECT ENCODING <key> / FREQ <key> / IDLETIME <key>`, `TYPE <key>`, `SCAN 0 MATCH <pattern> COUNT n` | `FREQ` needs LFU policy, `IDLETIME` needs LRU. |
| Cluster | `CLUSTER INFO / NODES / SHARDS / SLOTS / MYID / COUNTKEYSINSLOT <slot> / SLOT-STATS ...` | `SHARDS` scales better than `NODES` on large topologies. `SLOT-STATS` is Valkey-only. |

## Valkey incident patterns

### Mass TTL expiry spike

Same-second TTLs on thousands of keys → active-expire-cycle finds > stale-ratio threshold, loops aggressively, main thread stalls.

- **Symptom**: periodic latency spikes spaced exactly `N` seconds apart; `expire-cycle` appears in `LATENCY HISTORY`.
- **Fix**: jitter TTLs at the application: `EXPIRE key (base + rand(0..jitter))`. Tune `active-expire-effort` down if needed (Valkey 9.0 defaults to `1` already).

### THP-induced BGSAVE latency

Transparent Huge Pages on → after fork, each COW copies a 2 MB hugepage instead of a 4 KB page. `rdb_last_cow_size` approaches `used_memory`.

- **Symptom**: seconds-long latency spikes correlated with BGSAVE, even though `latest_fork_usec` is low.
- **Fix**: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`. Valkey logs a warning at startup if THP is enabled; easy to miss in Docker.

### Pub/Sub slow-subscriber OOM

Publisher fast, subscriber slow → output buffer grows unboundedly.

- **Symptom**: `used_memory` climbs; `CLIENT LIST` shows pub/sub clients with `omem` in hundreds of MB.
- **Fix**: `client-output-buffer-limit pubsub 32mb 8mb 60`. Add `maxmemory-clients 5%` as a second line of defense.

### Replica cascading full resync

Undersized `repl-backlog-size` + brief network blip → replicas all trigger full resync simultaneously → fork amplifies latency → more replicas disconnect.

- **Symptom**: `sync_full` increments, `latest_fork_usec` climbs, replica lag across the board.
- **Fix**: size `repl-backlog-size` per `replication-tuning.md`. `repl-diskless-sync-delay 5` batches concurrent arrivals into one stream.

### Swap-induced latency

- **Symptom**: Random 100 ms+ spikes uncorrelated with any command.
- **Diagnose**: `cat /proc/$(pidof valkey-server)/smaps | grep '^Swap:' | grep -v '0 kB'`.
- **Fix**: `maxmemory` well below physical RAM; `vm.swappiness=1`; add RAM or shrink dataset.

### Large-key cluster migration blocked (pre-9.0)

Key-by-key `MIGRATE` of a multi-million-element set exceeds target buffer → migration hangs in MIGRATING/IMPORTING.

- **9.0 fix**: atomic slot migration (see `cluster-resharding.md`). Pre-9.0 workarounds: raise `proto-max-bulk-len` on target, or delete-and-recreate the large key before migration.

## Quick health-check script

```sh
#!/usr/bin/env bash
set -eu
host="${1:-127.0.0.1}" port="${2:-6379}"
cli="valkey-cli -h $host -p $port"

section() { echo; echo "=== $1 ==="; }
section Server      ; $cli INFO server      | grep -E 'valkey_version|uptime_in_days|connected_clients'
section Memory      ; $cli INFO memory      | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
section Persistence ; $cli INFO persistence | grep -E 'rdb_last_bgsave_status|aof_last_bgrewrite_status|latest_fork_usec'
section Replication ; $cli INFO replication | grep -E 'role|connected_slaves|master_link_status'
section Stats       ; $cli INFO stats       | grep -E 'instantaneous_ops_per_sec|rejected_connections|expired_keys|evicted_keys'
section Latency     ; $cli LATENCY LATEST
section "Slow cmds" ; $cli COMMANDLOG GET 5 slow
```

## See also

- `troubleshooting-diagnostics-runbook.md` - structured 7-phase investigation flow.
- `troubleshooting-oom.md`, `troubleshooting-slow-commands.md`, `troubleshooting-cluster-partitions.md`, `troubleshooting-replication-lag.md` for focused playbooks.
