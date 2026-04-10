# AOF (Append-Only File) Persistence

Use when configuring write-ahead logging for durability, choosing fsync policies, or troubleshooting AOF corruption.

Standard Redis AOF behavior applies. See Redis docs for general AOF concepts.

## Valkey Default Values (same as Redis)

| Parameter | Default |
|-----------|---------|
| `appendonly` | `no` |
| `appendfsync` | `everysec` |
| `aof-use-rdb-preamble` | `yes` (hybrid mode) |
| `no-appendfsync-on-rewrite` | `no` |
| `auto-aof-rewrite-percentage` | `100` |
| `auto-aof-rewrite-min-size` | `64mb` |

`appendfilename` and `appenddirname` are IMMUTABLE - plan at deployment time.

## Valkey-Specific: Multi-Part AOF Architecture

Since Valkey 7.0, AOF uses a manifest file + multiple files in `appendonlydir/`:
- Base file: `.base.rdb` (hybrid) or `.base.aof`
- Incremental files: `.incr.aof`

## Valkey CLI for AOF Operations

```bash
valkey-cli BGREWRITEAOF
valkey-check-aof --fix appendonlydir/appendonly.aof.1.incr.aof
```

## Worst-Case Data Loss

`appendfsync everysec` can lose up to 2 seconds of data (not 1 second) - if background fsync takes over 1 second, a blocking write is forced after the second second.

## Hybrid Persistence (Recommended)

```
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
```

Fast restarts (RDB base) + high durability (AOF incremental). When both RDB and AOF exist, Valkey loads AOF (more complete).
