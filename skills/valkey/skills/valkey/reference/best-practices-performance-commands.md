# Performance: Command Selection

Use when choosing between UNLINK and DEL, or replacing KEYS with SCAN.

## UNLINK vs DEL

`DEL` frees memory synchronously on the main thread - large keys block all clients. `UNLINK` reclaims memory on a background thread.

**Valkey 8.0+ change**: `lazyfree-lazy-user-del` defaults to `yes`, making `DEL` behave like `UNLINK` by default. This is a behavioral change from Redis, where the default was `no`.

Still prefer explicit `UNLINK` in code:
- communicates intent
- remains non-blocking if someone sets `lazyfree-lazy-user-del no`

Other lazyfree defaults changed in Valkey 8.0: `lazyfree-lazy-eviction`, `lazyfree-lazy-expire`, `lazyfree-lazy-server-del`, and `lazyfree-lazy-user-flush` also default to `yes` (the whole lazyfree family flipped in one commit).

## SCAN vs KEYS

`KEYS pattern` blocks the server. Use `SCAN cursor MATCH pattern COUNT hint` instead. Iterate until cursor returns 0. Deduplicate results - SCAN may return the same key twice. COUNT is a hint only.

Type-specific variants: `HSCAN`, `SSCAN`, `ZSCAN` for iterating inside a single key.
