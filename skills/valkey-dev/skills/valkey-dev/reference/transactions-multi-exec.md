# MULTI/EXEC Transactions

Use when working on command queuing, optimistic locking, or transaction execution in Valkey.

Standard MULTI/EXEC implementation, same as Redis. No Valkey-specific changes.

Source: `src/multi.c`. Commands queued in `multiState` array. WATCH uses `watchedKey` with embedded `listNode` for O(1) removal. `dirty_cas` (watched key modified) returns null array. `dirty_exec` (queuing error) returns EXECABORT. Per-command errors do not abort the transaction. Lazy initialization of `multiState` on first MULTI/WATCH.
