# Troubleshooting

Use when investigating a production incident - quick triage, OOM, slow commands, cluster partitions, replication lag.

## Quick triage sequence

```sh
# Phase 1: responsiveness
valkey-cli PING
valkey-cli INFO server | head -20
valkey-cli LATENCY LATEST
valkey-cli COMMANDLOG GET 5 slow   # use COMMANDLOG, not SLOWLOG

# Phase 2: memory
valkey-cli INFO memory
valkey-cli MEMORY DOCTOR

# Phase 3: latency
valkey-cli LATENCY DOCTOR
valkey-cli --intrinsic-latency 10   # run on server

# Phase 4: replication
valkey-cli INFO replication

# Phase 5: clients
valkey-cli INFO clients
valkey-cli CLIENT LIST

# Phase 6: cluster (if applicable)
valkey-cli CLUSTER INFO
valkey-cli --cluster check <ip>:<port>

# Phase 7: persistence - rdb_last_cow_size, latest_fork_usec
valkey-cli INFO persistence
```

## Command cheat sheet

| Category | Command | Notes |
|---------|---------|-------|
| Server | `INFO [section]` | Valkey-specific: `tls`, `clients_statistics`, module-loaded sections. |
| Memory | `MEMORY DOCTOR / USAGE / STATS / PURGE / MALLOC-STATS` | |
| Latency | `LATENCY DOCTOR / LATEST / HISTORY <event> / GRAPH <event> / HISTOGRAM [cmd ...] / RESET` | |
| Commandlog | `COMMANDLOG GET <count> <type> / LEN <type> / RESET <type>` | `type` = `slow` / `large-request` / `large-reply`. `SLOWLOG *` is alias for `slow`. |
| Clients | `CLIENT LIST [TYPE type] / INFO / GETNAME / KILL <filter> / NO-EVICT on` | |
| Keys | `OBJECT ENCODING <key> / FREQ <key> / IDLETIME <key>`, `TYPE <key>`, `SCAN 0 MATCH <pattern> COUNT n` | `FREQ` needs LFU policy, `IDLETIME` needs LRU. |
| Cluster | `CLUSTER INFO / NODES / SHARDS / SLOTS / MYID / COUNTKEYSINSLOT <slot> / SLOT-STATS ...` | `SHARDS` scales better than `NODES` on large topologies. `SLOT-STATS` is Valkey-only. |

## COMMANDLOG for slow-command investigation

A client timing out on `HGETALL` against a large hash won't show in slow-log if the server was fast - but the **reply** was megabytes. That's the `large-reply` log, and it tells you the client's network or parser is the bottleneck, not the server.

```sh
valkey-cli COMMANDLOG GET 25 slow            # > 10ms by default
valkey-cli COMMANDLOG GET 25 large-request   # > 1MB by default
valkey-cli COMMANDLOG GET 25 large-reply     # > 1MB by default
```

Tighten thresholds during investigation, restore after:

```
commandlog-execution-slower-than 1000     # 1ms - surface more
commandlog-slow-execution-max-len 512
commandlog-reply-larger-than 65536        # 64KB - catch medium replies
```

Restore defaults: 10000 µs / 128 / 1048576 B. Full COMMANDLOG semantics in `monitoring.md`.

## Hot-key detection

`valkey-cli --hotkeys` needs `maxmemory-policy` set to an LFU variant (uses `OBJECT FREQ`). `--bigkeys` and `--memkeys` work without LFU. `MONITOR` adds per-command overhead - only run briefly.

In cluster mode, a hot key lives on exactly one shard. With `cluster-slot-stats-enabled yes`:

```
CLUSTER SLOT-STATS ORDERBY cpu-usec LIMIT 10 DESC
```

Points directly at the slot - combined with `CLUSTER NODES`, at the shard owning it. Replaces the "run --hotkeys on every node and diff" workflow.

## OOM

Standard Redis mitigation (`maxmemory`, eviction policy, `vm.overcommit_memory=1`, fragmentation check) applies.

Valkey-specific: `maxmemory-clients` caps aggregate client-buffer memory independently of `maxmemory`:

```sh
valkey-cli CONFIG SET maxmemory-clients 5%
```

Default is `0` (unlimited) and client buffers are NOT counted against `maxmemory`. Set this to protect against misbehaving clients. Alert at `used_memory / maxmemory` > 75% warn / 90% crit. Replication and AOF buffers are also not counted against `maxmemory` - size `maxmemory` 10-20% below available RAM when using replication.

Diagnosis:

```sh
valkey-cli INFO memory | grep -E "used_memory|maxmemory|mem_fragmentation"
valkey-cli MEMORY DOCTOR
valkey-cli --bigkeys
valkey-cli MEMORY USAGE <key> SAMPLES 0
dmesg | grep -i "out of memory"
```

## Replication lag

```sh
valkey-cli INFO replication    # primary: slave offset vs master_repl_offset
valkey-cli INFO replication    # replica: master_link_status, master_last_io_seconds_ago
valkey-cli COMMANDLOG GET 10 slow   # slow commands on replica (COMMANDLOG, not SLOWLOG)
```

Common resolutions:

```sh
valkey-cli CONFIG SET repl-backlog-size 512mb   # 10MB default is too small
valkey-cli CONFIG SET repl-diskless-sync yes
valkey-cli CONFIG SET repl-timeout 120
valkey-cli CONFIG SET client-output-buffer-limit "replica 512mb 128mb 60"
```

Full tuning and incident patterns in `replication.md`.

## Cluster partitions

### Bus-port check

Cluster gossip runs on `port + 10000`. Both client port (`6379`) AND bus port (`16379`) must be open between every pair. A firewall allowing client but blocking bus produces a failure mode that looks like total partition even though every node is individually healthy:

```sh
for n in node1 node2 node3 node4 node5 node6; do
  echo "=== $n ==="
  nc -zv $n 6379
  nc -zv $n 16379
done
```

### Failover escape hatches

| Mode | Catch-up | Majority vote | Use when |
|------|---------|---------------|----------|
| (default) | yes | yes | Planned - zero data loss |
| `FORCE` | no | yes | Primary unreachable, majority alive |
| `TAKEOVER` | no | **no** - replica bumps configEpoch | Majority unreachable |

`TAKEOVER` → two sides re-merging with overlapping slot ownership is the consequence. Only use if a real election is impossible.

### `--cluster fix` and `CLUSTER FORGET`

`valkey-cli --cluster fix <host>:<port>` reassigns uncovered slots, clears orphan `MIGRATING`/`IMPORTING` state from interrupted migrations, resolves ownership conflicts. Review the plan before confirming.

`CLUSTER FORGET <node-id>` must be sent to **every remaining node within 60 seconds**, or gossip re-adds it:

```sh
for n in node1:6379 node2:6379 node3:6379; do
  valkey-cli -h ${n%:*} -p ${n#*:} CLUSTER FORGET $NODE_ID
done
```

### Config defaults that differ

- `cluster-allow-pubsubshard-when-down` defaults to `yes` (Valkey-only flip) - shard pub/sub keeps working when cluster is FAIL. Redis-trained operators expect all ops to reject. Disable explicitly if your use case needs fail-closed pub/sub.

### Large-key migration (pre-9.0 issue)

**Pre-9.0**: multi-million-element set on key-by-key `MIGRATE` hangs migration - slot stuck in MIGRATING/IMPORTING. Workaround: raise `proto-max-bulk-len` on target, delete-and-recreate the key, or force `CLUSTER SETSLOT ... NODE` with accepted data loss.

**9.0+**: atomic slot migration bypasses the problem. Entire slots transfer as a forked RDB stream instead of key-by-key. See `cluster.md` for the ASM flow.

### Ranked failover elections (8.1+)

Replicas ranked by replication offset; most up-to-date tries first, others delay proportionally. Multi-primary failure (lost rack) doesn't collide on simultaneous elections - shards converge in rank order. Logged as `IO threads: vote rank X`.

### Reconnection throttling (9.0+)

Pre-9.0, a node reconnected to a lost peer every 100 ms until the peer came back - flapping links produced reconnect storms. 9.0 throttles within `cluster-node-timeout`. If logs are quieter than pre-9.0 under the same flap, that's expected.

### Post-incident hygiene

- `CLUSTER INFO` - verify `cluster_stats_messages_*_sent`/`_received` per-type counters stopped climbing abnormally.
- `CLUSTER SHARDS` - confirm `availability-zone` populated if configured (otherwise AZ-aware replica placement was silently off).
- Re-check `cluster-slot-stats-enabled`; default-off. Enable before next incident if you need per-slot CPU accounting.

## Incident patterns

### Mass TTL expiry spike

Same-second TTLs on thousands of keys → active-expire-cycle finds >stale-ratio threshold, loops aggressively, main thread stalls.

- **Symptom**: periodic latency spikes spaced exactly `N` seconds apart; `expire-cycle` in `LATENCY HISTORY`.
- **Fix**: jitter TTLs at the application: `EXPIRE key (base + rand(0..jitter))`. Tune `active-expire-effort` down if needed (default is already `1`).

### THP-induced BGSAVE latency

THP on → after fork, each COW copies a 2 MB hugepage instead of a 4 KB page. `rdb_last_cow_size` approaches `used_memory`.

- **Symptom**: seconds-long latency spikes correlated with BGSAVE, even with low `latest_fork_usec`.
- **Fix**: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`. Valkey logs a warning at startup if THP is enabled - easy to miss in Docker.

### Pub/Sub slow-subscriber OOM

Publisher fast, subscriber slow → output buffer grows unbounded.

- **Symptom**: `used_memory` climbs; `CLIENT LIST` shows pub/sub clients with `omem` in hundreds of MB.
- **Fix**: `client-output-buffer-limit pubsub 32mb 8mb 60`. Add `maxmemory-clients 5%` as second line of defense.

### Replica cascading full resync

Undersized `repl-backlog-size` + brief network blip → replicas all trigger full resync simultaneously → fork amplifies latency → more replicas disconnect.

- **Symptom**: `sync_full` increments, `latest_fork_usec` climbs, replica lag across the board.
- **Fix**: size `repl-backlog-size` per `replication.md`. `repl-diskless-sync-delay 5` batches concurrent arrivals into one stream.

### Swap-induced latency

- **Symptom**: random 100+ ms spikes uncorrelated with any command.
- **Diagnose**: `cat /proc/$(pidof valkey-server)/smaps | grep '^Swap:' | grep -v '0 kB'`.
- **Fix**: `maxmemory` well below physical RAM; `vm.swappiness=1`; add RAM or shrink dataset.

### Primary without persistence wipes replicas

If persistence is disabled on the primary and it restarts, all replicas sync with an empty dataset and lose their data. Enable persistence on primary or disable auto-restart. See `replication.md`.

## Mitigation handles

- Disable dangerous commands via `rename-command KEYS ""` (valkey.conf only, not runtime). Prefer ACL `-@dangerous`.
- `UNLINK` instead of `DEL` for large keys (but all five lazyfree defaults are `yes` on Valkey so `DEL` already goes async unless disabled).
- `CLIENT NO-EVICT on` on the exporter's connection so scraping doesn't churn the LRU.
- `io-threads > 1` helps I/O-bound workloads - a slow single command is still slow.

## Memory test

```sh
valkey-server --test-memory 4096   # destructive - not on live instance
```

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
