# Data Types - Valkey-Specific Extensions

Use when looking up Valkey-only command additions to standard data types: conditional string ops, per-field hash expiry, or polygon geo search.

Standard Redis commands (SET, GET, HSET, ZADD, etc.) are assumed known. This file covers only what Valkey adds.

## Strings

`SET key value IFEQ old_value` (Valkey 9.0+) - conditional update, only sets if current value equals `old_value`. Replaces WATCH/MULTI/EXEC for compare-and-swap.

`DELIFEQ key value` (Valkey 9.0+) - conditional delete, only deletes if current value equals `value`. Replaces Lua scripts for safe lock release.

## Hashes - Per-Field TTL (Valkey 7.4+)

`HSETEX key ttl-seconds field value [field value ...]` - set fields with TTL in one command.

`HGETEX key [EX seconds | PX ms | EXAT unix | PXAT unix-ms | PERSIST] FIELDS count field [field ...]` - get fields and optionally set/refresh/remove their TTL atomically.

`HGETDEL key FIELDS count field [field ...]` - get fields and delete them atomically.

`HEXPIRE key seconds FIELDS count field [field ...]` - set per-field TTL (seconds).
`HPEXPIRE key ms FIELDS count field [field ...]` - set per-field TTL (milliseconds).
`HTTL key FIELDS count field [field ...]` - get remaining TTL per field.
`HPTTL key FIELDS count field [field ...]` - get remaining TTL in ms per field.
`HEXPIRETIME key FIELDS count field [field ...]` - get expiry as Unix timestamp.
`HPERSIST key FIELDS count field [field ...]` - remove per-field TTL.

Per-field expiry is the primary Valkey advantage for session storage - individual hash fields expire without needing to manage separate keys. See `patterns-sessions-field-expiry.md`.

## Geospatial

`GEOSEARCH key FROMMEMBER member | FROMLONLAT lon lat BYPOLYGON numpoints lon lat [lon lat ...] [ASC|DESC] [COUNT count]` (Valkey 9.0+) - match members inside an arbitrary polygon. Standard Redis only supports BYRADIUS and BYBOX.
