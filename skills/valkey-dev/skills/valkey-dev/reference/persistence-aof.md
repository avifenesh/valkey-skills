# AOF (Append-Only File) Persistence

Use when you need to understand how Valkey logs every write command for durability, the multi-part AOF architecture, the rewrite process, or fsync policies.

Standard multi-part AOF architecture (same as Redis 7.0+). Manifest-based system with BASE + INCR files in `appendonlydir/`. No major Valkey-specific changes to AOF internals.

Source: `src/aof.c`. Key difference from Redis: loading detects both `REDIS` and `VALKEY` magic bytes in RDB preamble BASE files. The `AOF_WAIT_REWRITE` state handles enabling AOF on replicas during full sync.

Config: `appendfsync` (always/everysec/no), `aof-use-rdb-preamble` (yes, default), `auto-aof-rewrite-percentage` (100), `auto-aof-rewrite-min-size` (64mb).
