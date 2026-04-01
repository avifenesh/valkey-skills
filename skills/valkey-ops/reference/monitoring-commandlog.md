Use when investigating slow commands, large requests, or large replies.

# Commandlog
The commandlog is Valkey's evolution of Redis SLOWLOG, expanded to cover
network bandwidth in addition to execution time.

## Contents

- What It Is (line 20)
- Three Log Types (line 29)
- Configuration (line 42)
- Commands (line 81)
- Migration from SLOWLOG (line 134)
- Operational Patterns (line 156)
- Grafana Panels for Commandlog (line 215)
- See Also (line 235)

---

## What It Is

The commandlog records recent commands that exceeded configured thresholds for
execution time, request size, or reply size. It is an in-memory circular buffer
(not written to disk) accessible via the `COMMANDLOG` command.

Three independent logs are maintained, each with its own threshold and max
length. Implementation is in `src/commandlog.c`.

## Three Log Types

| Type | What it captures | Threshold unit |
|------|-----------------|----------------|
| `slow` | Commands that took too long to execute | Microseconds |
| `large-request` | Commands with oversized input (arguments) | Bytes |
| `large-reply` | Commands that produced oversized output | Bytes |

Source-verified from `src/server.h` (lines 411-414):
- `COMMANDLOG_TYPE_SLOW` = 0
- `COMMANDLOG_TYPE_LARGE_REQUEST` = 1
- `COMMANDLOG_TYPE_LARGE_REPLY` = 2

## Configuration

All defaults source-verified from `src/config.c` (lines 3421-3434):

### Thresholds

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `commandlog-execution-slower-than` | `10000` (10 ms) | -1 to LLONG_MAX | Log commands slower than this (microseconds). -1 disables. Alias: `slowlog-log-slower-than`. |
| `commandlog-request-larger-than` | `1048576` (1 MB) | -1 to LLONG_MAX | Log commands with request payload larger than this (bytes). -1 disables. |
| `commandlog-reply-larger-than` | `1048576` (1 MB) | -1 to LLONG_MAX | Log commands with reply payload larger than this (bytes). -1 disables. |

### Maximum Entry Counts

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `commandlog-slow-execution-max-len` | `128` | 0-LONG_MAX | Max entries in the slow execution log. Alias: `slowlog-max-len`. |
| `commandlog-large-request-max-len` | `128` | 0-LONG_MAX | Max entries in the large request log. |
| `commandlog-large-reply-max-len` | `128` | 0-LONG_MAX | Max entries in the large reply log. |

Setting a max-len to 0 disables that log type (no entries are recorded).
Setting a threshold to -1 also disables the corresponding log type.

### Runtime Configuration

```bash
# Lower slow threshold to catch commands > 5ms
valkey-cli CONFIG SET commandlog-execution-slower-than 5000

# Lower request size threshold to catch large payloads > 100KB
valkey-cli CONFIG SET commandlog-request-larger-than 102400

# Increase slow log capacity for busy instances
valkey-cli CONFIG SET commandlog-slow-execution-max-len 1024

# Disable large-reply logging
valkey-cli CONFIG SET commandlog-reply-larger-than -1
```

## Commands

The `COMMANDLOG` command requires a type argument for all subcommands:

### COMMANDLOG GET

```bash
# Get last 10 slow commands
COMMANDLOG GET 10 slow

# Get last 10 large requests
COMMANDLOG GET 10 large-request

# Get last 10 large replies
COMMANDLOG GET 10 large-reply

# Get all entries (-1 means all)
COMMANDLOG GET -1 slow
```

Each entry contains 6 fields (source-verified from `src/commandlog.c` line 133):

| Field | Description |
|-------|-------------|
| id | Unique incrementing ID per log type |
| timestamp | Unix timestamp when the command was logged |
| value | Duration in microseconds (slow) or size in bytes (large-request/large-reply) |
| arguments | Command and arguments (truncated: max 32 args, 128 bytes per arg) |
| client_ip:port | Client address |
| client_name | Client name if set via `CLIENT SETNAME` |

Argument truncation limits (from `src/commandlog.h`):
- `COMMANDLOG_ENTRY_MAX_ARGC` = 32 arguments
- `COMMANDLOG_ENTRY_MAX_STRING` = 128 bytes per argument

### COMMANDLOG LEN

```bash
# Count entries in each log
COMMANDLOG LEN slow
COMMANDLOG LEN large-request
COMMANDLOG LEN large-reply
```

### COMMANDLOG RESET

```bash
# Clear a specific log type
COMMANDLOG RESET slow
COMMANDLOG RESET large-request
COMMANDLOG RESET large-reply
```

## Migration from SLOWLOG

The `SLOWLOG` command is still supported as an alias. Source-verified from
`src/commandlog.c` (the `slowlogCommand` function, lines 174-214): `SLOWLOG`
maps directly to the `slow` type of the commandlog.

| Old Command | New Equivalent |
|-------------|---------------|
| `SLOWLOG GET [count]` | `COMMANDLOG GET <count> slow` |
| `SLOWLOG LEN` | `COMMANDLOG LEN slow` |
| `SLOWLOG RESET` | `COMMANDLOG RESET slow` |
| `slowlog-log-slower-than` | `commandlog-execution-slower-than` (alias) |
| `slowlog-max-len` | `commandlog-slow-execution-max-len` (alias) |

The old config names are registered as aliases in `src/config.c` and work
transparently. No action needed for existing configs using `slowlog-*` names.

### Key Difference

`SLOWLOG GET` takes an optional count (defaults to 10) and does not require
a type. `COMMANDLOG GET` requires both count and type as mandatory arguments.

## Operational Patterns

### Regular Audit

```bash
# Check for slow commands every monitoring cycle
COMMANDLOG GET 20 slow

# Check for oversized requests (potential abuse or misuse)
COMMANDLOG GET 20 large-request

# Check for large replies (may indicate missing pagination)
COMMANDLOG GET 20 large-reply
```

### Tuning Thresholds

Start with defaults and tighten based on your SLA:

| Workload | Slow threshold | Request threshold | Reply threshold |
|----------|---------------|-------------------|-----------------|
| Low-latency cache | 1000 (1 ms) | 102400 (100 KB) | 102400 (100 KB) |
| General purpose | 10000 (10 ms) | 1048576 (1 MB) | 1048576 (1 MB) |
| Batch processing | 100000 (100 ms) | 10485760 (10 MB) | 10485760 (10 MB) |

### Alerting Integration

Poll the commandlog periodically and alert when new entries appear:

```bash
# In a monitoring script - track the entry count
prev=$(valkey-cli COMMANDLOG LEN slow)
# ... wait ...
curr=$(valkey-cli COMMANDLOG LEN slow)
# Alert if new slow commands appeared
```

For production monitoring, the Prometheus exporter (oliver006/redis_exporter)
exposes slowlog metrics that map to the commandlog's slow log:

| Prometheus Metric | Description |
|-------------------|-------------|
| `redis_slowlog_length` | Current number of entries in the slow log |
| `redis_slowlog_last_id` | ID of the most recent slow log entry |

Use `delta(redis_slowlog_length[10m]) > 10` as an alert for growing slow
command counts. The exporter reads via `SLOWLOG GET` which maps to the `slow`
commandlog type.

The exporter does not yet expose `large-request` or `large-reply`
commandlog types. Poll via `COMMANDLOG LEN large-request`
and `COMMANDLOG LEN large-reply` from your monitoring agent directly.

### Commands Excluded from Logging

Commands with the `CMD_SKIP_COMMANDLOG` flag are never logged. This prevents
sensitive commands (like AUTH) from appearing in the commandlog with their
arguments (source: `src/commandlog.c` line 148).

## Grafana Panels for Commandlog

Percona PMM ships a dedicated "Valkey Slowlog" dashboard with these panels:

| Panel | Source |
|-------|--------|
| Slowlog length | `redis_slowlog_length` |
| Slowlog max length | `redis_config_maxclients` (config) |
| Slowlog threshold | `commandlog-execution-slower-than` value in ms |
| Slowlog entries | Displayed as a table |

For custom Grafana dashboards, a minimal slow command panel:

```promql
# Slowlog entry growth rate
delta(redis_slowlog_length[10m])
```

---
