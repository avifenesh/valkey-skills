# Latency Diagnosis

Use when investigating latency spikes, establishing baseline latency, or analyzing slow commands.

Standard Redis latency diagnosis applies - intrinsic latency measurement, LATENCY DOCTOR, client analysis, THP as the #1 Linux misconfiguration. See Redis docs for general latency diagnosis workflow.

## Valkey-Specific: COMMANDLOG Replaces SLOWLOG

Valkey extends slowlog with three dimensions. Source-verified defaults from `src/config.c`:

| Config | Alias | Default |
|--------|-------|---------|
| `commandlog-execution-slower-than` | `slowlog-log-slower-than` | 10000 µs |
| `commandlog-request-larger-than` | - | 1048576 bytes (1MB) |
| `commandlog-reply-larger-than` | - | 1048576 bytes (1MB) |
| `commandlog-slow-execution-max-len` | `slowlog-max-len` | 128 entries |

```bash
# New interface
COMMANDLOG GET 25 slow
COMMANDLOG GET 25 large-request
COMMANDLOG GET 25 large-reply

# Legacy interface (still works)
SLOWLOG GET 25
```

## Standard Diagnosis Commands (Valkey)

```bash
valkey-cli --intrinsic-latency 100   # run on server, 100s baseline
valkey-cli LATENCY DOCTOR
valkey-cli LATENCY LATEST
valkey-cli LATENCY HISTOGRAM GET SET HGET
CONFIG SET latency-monitor-threshold 100
CONFIG SET watchdog-period 500   # emergency stall diagnosis; disable after
```

## Common Causes (same as Redis)

THP enabled, slow commands, fork latency, AOF fsync, disk I/O contention, expiration storms, swapping.
