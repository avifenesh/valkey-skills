# Data Types - Valkey-Specific Extensions

Use when looking up Valkey-only command additions to standard data types: conditional string ops, per-field hash expiry, or polygon geo search.

Standard Redis commands (SET, GET, HSET, ZADD, etc.) are assumed known. This file covers only what Valkey adds.

## Strings

`SET key value IFEQ old_value` (Valkey 8.1+) - conditional update, only sets if current value equals `old_value`. Does not create missing keys (returns nil). Replaces WATCH/MULTI/EXEC for compare-and-swap.

`DELIFEQ key value` (Valkey 9.0+) - conditional delete, only deletes if current value equals `value`. Replaces Lua scripts for safe lock release.

## Hashes - Per-Field TTL (Valkey 9.0+)

`HSETEX key [FNX|FXX] [EX seconds|PX ms|EXAT unix|PXAT unix-ms|KEEPTTL] FIELDS count field value [field value ...]` - set fields (optionally with TTL) in one command. `FNX` = set only if field doesn't exist; `FXX` = set only if it does. `KEEPTTL` preserves the field's existing TTL when updating its value.

`HGETEX key [EX seconds|PX ms|EXAT unix|PXAT unix-ms|PERSIST] FIELDS count field [field ...]` - get fields and optionally set/refresh/remove their TTL atomically.

`HGETDEL key FIELDS count field [field ...]` - get fields and delete them atomically.

`HEXPIRE key seconds [NX|XX|GT|LT] FIELDS count field [field ...]` - set per-field TTL (seconds).
`HPEXPIRE key ms [NX|XX|GT|LT] FIELDS count field [field ...]` - set per-field TTL (milliseconds).
`HEXPIREAT key unix-seconds [NX|XX|GT|LT] FIELDS count field [field ...]` - absolute expiry (seconds).
`HPEXPIREAT key unix-ms [NX|XX|GT|LT] FIELDS count field [field ...]` - absolute expiry (milliseconds).
`HTTL key FIELDS count field [field ...]` - remaining TTL per field (seconds).
`HPTTL key FIELDS count field [field ...]` - remaining TTL per field (milliseconds).
`HEXPIRETIME key FIELDS count field [field ...]` - expiry as absolute Unix timestamp (seconds).
`HPEXPIRETIME key FIELDS count field [field ...]` - expiry as absolute Unix timestamp (milliseconds).
`HPERSIST key FIELDS count field [field ...]` - remove per-field TTL.

`NX|XX|GT|LT` on HEXPIRE family: `NX` only if no TTL, `XX` only if TTL, `GT` only if new TTL is greater, `LT` only if new TTL is less.

Per-field expiry is the primary Valkey advantage for session storage - individual hash fields expire without needing to manage separate keys. See `patterns-sessions-field-expiry.md`.

## Geospatial

`GEOSEARCH key FROMMEMBER member | FROMLONLAT lon lat BYPOLYGON numpoints lon lat [lon lat ...] [ASC|DESC] [COUNT count]` (Valkey 9.0+) - match members inside an arbitrary polygon. Standard Redis only supports BYRADIUS and BYBOX.
