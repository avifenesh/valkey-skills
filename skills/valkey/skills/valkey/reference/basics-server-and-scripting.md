# Server Commands - Valkey-Specific Extensions

Use when looking up Valkey-only server and monitoring commands: COMMANDLOG, CLUSTERSCAN, or noting which Lua patterns now have native replacements.

Standard commands (INFO, CONFIG, CLIENT, MULTI/EXEC, EVAL, SCAN) are assumed known. This file covers only what Valkey adds or replaces.

## COMMANDLOG (Valkey 8.1+)

Replaces SLOWLOG. Tracks slow commands, large payloads, and rejected commands in separate logs.

```
COMMANDLOG GET count <slow|large|denied>
COMMANDLOG LEN <slow|large|denied>
COMMANDLOG RESET <slow|large|denied>
```

Configuration:
```
commandlog-slow-execution-time 10000   # microseconds
commandlog-max-slow-entries 128
commandlog-large-request-threshold 1048576   # bytes
commandlog-max-large-entries 128
```

SLOWLOG remains available for backward compatibility but COMMANDLOG is the preferred interface.

## CLUSTERSCAN (Valkey 8.0+)

Cluster-wide SCAN across all slots without client-side orchestration.

```
CLUSTERSCAN cursor [MATCH pattern] [COUNT hint] [TYPE type]
```

Standard SCAN only covers the local node's keyspace. CLUSTERSCAN iterates across the entire cluster transparently. Use in cluster mode wherever you would use SCAN in standalone mode.

## Native Replacements for Common Lua Patterns

Two patterns that previously required Lua scripts now have native commands:

- Compare-and-swap: use `SET key value IFEQ old_value` instead of WATCH/MULTI/EXEC or Lua.
- Safe lock release: use `DELIFEQ key value` instead of a Lua CAS script.

See `basics-data-types.md` for full syntax.
