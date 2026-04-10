# Key Expiration

Use when understanding how Valkey expires keys (and hash fields), both lazily on access and proactively via the active expiration cycle.

Standard lazy + active expiration. Lazy: `expireIfNeeded()` on every key access. Active: `activeExpireCycle()` samples keys with TTLs periodically. See Redis expiry docs for the base model.

## Valkey-Specific Changes

- **Hash field TTL (Valkey 9.0)**: Per-field expiration on hash objects. Tracked via `db->keys_with_volatile_items` kvstore. Active expiry cycle alternates between KEYS and FIELDS job types to prevent starvation. `dbReclaimExpiredFields()` removes expired fields, propagates HDEL, fires `hexpired` keyspace notifications. If hash becomes empty, deletes the key entirely.
- **Two active expiry job types**: `activeExpireCycle()` runs independent KEYS and FIELDS expiry jobs, alternating priority each cycle.
- **Effort scaling**: `active-expire-effort` config (1-10) adjusts keys_per_loop, acceptable_stale threshold, and cycle budgets.

Source: `src/expire.c`, `src/db.c`
