# Dict - Legacy Chained Hash Table

Use when working with code that still uses the dict API - primarily Lua scripting, sentinel, cluster legacy, pub/sub, latency tracking, and some configuration internals. New code should use `hashtable.c` instead.

Source: `src/dict.c`, `src/dict.h`

The legacy `dict` is a chained hash table with power-of-two sizing and incremental rehashing. Starting in Valkey 8.1, the new open-addressing `hashtable` replaced `dict` for the main keyspace and for Hash, Set, and Sorted Set backing structures. See `data-structures-hashtable.md` for the replacement.

Subsystems still using dict (post-8.1): Lua scripting, Sentinel, cluster_legacy.c, pub/sub, latency, config, functions, blocked clients.

The API is standard Redis dict. Key difference: Valkey's dict uses `hashtable *subcommands_ht` for subcommand lookup in the command table (mixing old and new APIs in the transition period).
