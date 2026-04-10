# Command Dispatch

Use when you need to understand how a client request goes from raw bytes on the wire to command execution and reply.

Standard Redis command dispatch pattern. Valkey-specific differences:

- Command table uses `hashtable *` at `server.commands` (Valkey's new open-addressing hashtable, not dict)
- Struct is `serverCommand` (renamed from `redisCommand`)
- `processCommand()` includes a failover redirect step - during coordinated failover, writes get `-REDIRECT host:port`
- Key prefetching (`prefetchCommandQueueKeys`) warms CPU cache for pipelined commands before execution
- Pipeline queue supports up to 1024 queued commands (was 512 in older versions)

For the hashtable backing the command table, see `data-structures-hashtable.md`.
