# Diagnostics Runbook

Use when investigating a production Valkey issue - quick triage sequence, fork latency diagnosis, memory testing.

Standard Redis diagnostics apply. See Redis docs for general runbook guidance.

## Valkey Quick Triage Sequence

```bash
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

# Phase 7: persistence
valkey-cli INFO persistence   # check rdb_last_cow_size, latest_fork_usec
```

## Fork Latency

`rdb_last_cow_size` approaching `used_memory` indicates THP is causing COW amplification. Fix: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`. Valkey disables THP for its own process but system-wide is still needed.

## Memory Test

```bash
valkey-server --test-memory 4096   # destructive - not on live instance
```
