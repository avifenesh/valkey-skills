# Server, Scripting, and Transactions Quick Reference

Use when looking up server management, Lua scripting (EVAL/FCALL), transaction (MULTI/EXEC), monitoring (SLOWLOG, LATENCY), configuration, or client management commands.

Standard Redis-compatible server management, Lua scripting, and transaction commands. For Valkey-specific monitoring, use COMMANDLOG (see valkey-features/commandlog.md).

## Server Information
`INFO [section]`, `DBSIZE`, `LASTSAVE`, `TIME`, `MEMORY USAGE key`, `MEMORY DOCTOR`, `MEMORY STATS`

## Client Management
`CLIENT ID`, `CLIENT SETNAME name`, `CLIENT GETNAME`, `CLIENT LIST`, `CLIENT INFO`, `CLIENT NO-EVICT ON|OFF`, `CLIENT NO-TOUCH ON|OFF`, `CLIENT KILL`, `CLIENT PAUSE`

## Configuration
`CONFIG GET pattern`, `CONFIG SET param value`, `CONFIG REWRITE`, `CONFIG RESETSTAT`

## Monitoring
`COMMANDLOG GET count type` (Valkey 8.1+ - see valkey-features/commandlog.md)
`SLOWLOG GET [count]` (legacy, pre-8.1)
`MONITOR` (debug only, not production)
`LATENCY LATEST`, `LATENCY HISTORY event`

## Keyspace Scanning
`SCAN cursor [MATCH pattern] [COUNT hint] [TYPE type]`
`HSCAN`, `SSCAN`, `ZSCAN` (per-type variants)

Never use `KEYS pattern` in production - use SCAN instead.

## Lua Scripting
`EVAL script numkeys key [key ...] arg [arg ...]`
`EVALSHA sha1 numkeys key [key ...] arg [arg ...]`
`SCRIPT LOAD script`, `SCRIPT EXISTS sha1`, `SCRIPT FLUSH`

Many patterns that previously required Lua (compare-and-swap, safe lock release) now have native commands in Valkey - SET IFEQ and DELIFEQ.

## Functions (Valkey 7.0+)
`FUNCTION LOAD [REPLACE] function-code`
`FCALL function numkeys key [key ...] arg [arg ...]`
`FCALL_RO function numkeys key [key ...] arg [arg ...]`
`FUNCTION LIST`, `FUNCTION DELETE`, `FUNCTION DUMP`, `FUNCTION RESTORE`

## Transactions
`MULTI`, `EXEC`, `DISCARD`, `WATCH key [key ...]`, `UNWATCH`

For simple compare-and-swap, prefer SET IFEQ over WATCH/MULTI/EXEC.

## Replication and Durability
`WAIT numreplicas timeout`, `WAITAOF numlocal numreplicas timeout`
`REPLICAOF host port`, `REPLICAOF NO ONE`

## Cluster
`CLUSTER INFO`, `CLUSTER NODES`, `CLUSTER SLOTS`, `CLUSTER SHARDS`
`CLUSTER MEET host port`, `CLUSTER FORGET node-id`
`CLUSTER FAILOVER [FORCE|TAKEOVER]`
`CLUSTERSCAN cursor ...` (cluster-wide scanning)
