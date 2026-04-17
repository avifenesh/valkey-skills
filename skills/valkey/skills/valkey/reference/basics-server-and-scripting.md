# Server Commands - Valkey-Specific Extensions

Use when looking up Valkey-only server and monitoring commands: COMMANDLOG or noting which Lua patterns now have native replacements.

Standard commands (INFO, CONFIG, CLIENT, MULTI/EXEC, EVAL, SCAN) are assumed known. This file covers only what Valkey adds or replaces.

## COMMANDLOG (Valkey 8.1+)

Replaces SLOWLOG. Tracks slow commands, oversized requests, and oversized replies in three separate logs.

```
COMMANDLOG GET count <slow|large-request|large-reply>
COMMANDLOG LEN <slow|large-request|large-reply>
COMMANDLOG RESET <slow|large-request|large-reply>
```

Configuration (thresholds - set to `-1` to disable that type):
```
commandlog-execution-slower-than 10000     # microseconds for slow log
commandlog-request-larger-than 1048576     # bytes for large-request log
commandlog-reply-larger-than 1048576       # bytes for large-reply log
```

Per-log retention:
```
commandlog-slow-execution-max-len 128
commandlog-large-request-max-len 128
commandlog-large-reply-max-len 128
```

Legacy `slowlog-log-slower-than` and `slowlog-max-len` remain as aliases for the slow log. `SLOWLOG` as a command still works and reads from the same underlying slow log. See `valkey-features-commandlog.md` for full command reference and cluster-mode behavior.

## Native Replacements for Common Lua Patterns

Two patterns that previously required Lua scripts now have native commands:

- Compare-and-swap: use `SET key value IFEQ old_value` instead of WATCH/MULTI/EXEC or Lua.
- Safe lock release: use `DELIFEQ key value` instead of a Lua CAS script.

See `basics-data-types.md` for full syntax.
