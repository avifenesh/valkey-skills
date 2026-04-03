# RDB Snapshot Persistence

Use when you need to understand how Valkey creates point-in-time snapshots, the binary RDB file format, or the BGSAVE fork-based persistence model.

Source: `src/rdb.c`, `src/rdb.h`. Standard RDB persistence with these Valkey-specific changes:

## Magic String and Version

Valkey 9.0+ uses RDB version 80 with `VALKEY` magic: 9-byte header is `VALKEY080`. Legacy RDB version 11 uses `REDIS0011` (Valkey 7.x/8.x). Versions 12-79 reserved as "foreign" range. Loading accepts both magic strings.

## Valkey-Specific RDB Types

- `RDB_TYPE_HASH_2` (22) - Hash with field-level expiration (RDB 80, Valkey 9.0)
- `RDB_TYPE_SET_LISTPACK` (20) - Set in listpack encoding

## Other Differences

- Aux field `valkey-ver` written alongside `redis-ver` for compatibility
- Diskless replication uses 40-byte random hex EOF marker
- Return codes: `RDB_OK`, `RDB_NOT_EXIST`, `RDB_INCOMPATIBLE`, `RDB_FAILED`
