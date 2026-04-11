# Server Architecture Overview

Use when you need a map of the Valkey codebase, the global server state, or the boot sequence.

Standard single-threaded event loop server with `ae.c` event loop, `server.c` main, `networking.c` client I/O, `db.c` key operations, `rdb.c`/`aof.c` persistence, `replication.c` sync, `cluster.c`/`cluster_legacy.c` clustering.

## Valkey-Specific Architecture Changes

- **kvstore**: Keyspace uses `kvstore` - a slot-aware wrapper around the new `hashtable` implementation. In cluster mode, 16,384 hashtables (one per slot); in standalone, one hashtable. Replaces the legacy `dict` for the main keyspace. See [kvstore.md](valkey-specific-kvstore.md) and [hashtable.md](data-structures-hashtable.md).
- **Open-addressing hashtable**: `hashtable.c` replaces the chained `dict` for new code paths. Uses open addressing with Robin Hood hashing.
- **Lazy database allocation**: `server.db[]` is an array of pointers; databases are allocated on first use via `createDatabaseIfNeeded()`.
- **I/O threading**: `io_threads.c` provides dynamic I/O thread pool with read, write, and poll offloading. Thread count adjusts based on event load.
- **Pluggable scripting engines**: `scripting_engine.c` defines an engine ABI so modules can register new scripting languages (not just Lua).
- **Hash field TTL**: `keys_with_volatile_items` kvstore tracks hashes with per-field expiration.
- **RDMA connection type**: `connTypeInitialize()` registers TCP, TLS, Unix, and RDMA transports.
- **entry.c**: Hash field-value entry encoding abstraction.

Source: `src/server.c`, `src/server.h`
