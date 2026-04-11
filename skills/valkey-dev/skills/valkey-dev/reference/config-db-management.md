# Database Management

Use when understanding how Valkey stores, retrieves, modifies, and iterates keys across its database layer.

Standard key-value database with `lookupKey()`, `dbAdd()`, `setKey()`, `dbDelete()`, SCAN cursor iteration, FLUSHDB/FLUSHALL. See Redis internals docs for the base model.

## Valkey-Specific Changes

- **Multi-database cluster**: In cluster mode, each kvstore is partitioned into 16,384 hashtables (one per slot). `getKVStoreIndexForKey()` routes operations. Standalone mode uses a single hashtable (slot 0).
- **Lazy database allocation**: `server.db[]` is an array of `serverDb*` pointers. Unused databases remain NULL; `createDatabaseIfNeeded(id)` allocates on first access.
- **Hash field TTL tracking**: `db->keys_with_volatile_items` kvstore tracks hash keys that have per-field TTLs. Managed by `dbTrackKeyWithVolatileItems()` / `dbUntrackKeyWithVolatileItems()`.
- **kvstore keyspace**: Main keyspace uses `kvstore` (wrapping `hashtable`) instead of `dict`. See [kvstore.md](valkey-specific-kvstore.md).

Source: `src/db.c`
