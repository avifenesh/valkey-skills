# Blocking Operations

Use when working on BLPOP, BRPOP, BLMOVE, BZPOPMIN, XREAD, WAIT, module blocking, or the key-readiness notification system.

Standard blocking operations implementation, same as Redis. No Valkey-specific changes.

Source: `src/blocked.c`. Clients blocked via `blockForKeys()` with per-key tracking in `db->blocking_keys`. Readiness signaled by `signalKeyAsReady()` from write commands. `handleClientsBlockedOnKeys()` runs from `beforeSleep()`. Re-execution via `pending_command` flag. Timeout handling per blocking type.
