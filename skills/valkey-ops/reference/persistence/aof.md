Use when configuring write-ahead logging for durability, choosing fsync policies, setting up hybrid persistence, or troubleshooting AOF corruption.

# AOF (Append-Only File) Persistence

Source: `src/config.c`, `src/aof.c` (Valkey source). Cross-ref: valkey-dev `reference/persistence/aof.md` for multi-part architecture internals.

## Contents

- Tested Example: AOF with Hybrid Persistence (line 22)
- When to Use AOF (line 50)
- Trade-offs (line 57)
- Configuration Reference (line 66)
- Multi-Part AOF Architecture (line 115)
- Hybrid Persistence (Recommended) (line 135)
- AOF Rewrite (line 153)
- Operational Procedures (line 185)
- Production Recommendations (line 244)
- See Also (line 254)

---

## Tested Example: AOF with Hybrid Persistence

```bash
# Start Valkey with recommended AOF settings
docker run -d --name valkey-aof -p 6379:6379 \
  -v valkey-aof-data:/data valkey/valkey:9 \
  valkey-server --appendonly yes --appendfsync everysec \
  --aof-use-rdb-preamble yes --save ""

# Write test data
valkey-cli SET test:aof "persistence works"

# Verify AOF is active
valkey-cli INFO persistence | grep aof_enabled
# Expected: aof_enabled:1

# Trigger a manual rewrite and check
valkey-cli BGREWRITEAOF
valkey-cli INFO persistence | grep aof_rewrite_in_progress

# Restart and verify data survived
docker restart valkey-aof
valkey-cli GET test:aof
# Expected: "persistence works"
```

---

## When to Use AOF

- You need higher durability than RDB alone
- You want to recover from accidental FLUSHALL (truncate the AOF)
- You need sub-second data loss guarantees
- You are running a primary data store (not just a cache)

## Trade-offs

| Strength | Weakness |
|----------|----------|
| Configurable durability (per-command to per-second) | Larger files than RDB |
| Append-only prevents mid-write corruption | Slower restart than pure RDB (mitigated by hybrid) |
| Recoverable from accidental FLUSHALL | Background rewrite uses fork (same COW overhead as BGSAVE) |
| Human-readable command log | `appendfsync always` has significant throughput cost |

## Configuration Reference

All defaults verified against `src/config.c` in the Valkey source tree.

### Core Parameters

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `appendonly` | `no` | Yes | Enable AOF persistence |
| `appendfilename` | `appendonly.aof` | No (immutable) | Base name for AOF files |
| `appenddirname` | `appendonlydir` | No (immutable) | Directory for multi-part AOF files |
| `appendfsync` | `everysec` | Yes | Fsync policy |
| `no-appendfsync-on-rewrite` | `no` | Yes | Skip fsync during AOF/RDB rewrite |
| `auto-aof-rewrite-percentage` | `100` | Yes | Trigger rewrite when AOF grows by this % |
| `auto-aof-rewrite-min-size` | `64mb` | Yes | Minimum AOF size before auto-rewrite |
| `aof-use-rdb-preamble` | `yes` | Yes | Hybrid mode: base file in RDB format |
| `aof-load-truncated` | `yes` | Yes | Load truncated AOF on startup |
| `aof-rewrite-incremental-fsync` | `yes` | Yes | Fsync every 32MB during rewrite |
| `aof-timestamp-enabled` | `no` | Yes | Add timestamps to AOF entries |

`appendfilename` and `appenddirname` are IMMUTABLE - they cannot be changed at runtime. Plan these at deployment time.

### Fsync Policies

| Policy | Behavior | Max Data Loss | Throughput Impact |
|--------|----------|---------------|-------------------|
| `always` | Fsync after every write command | Zero (single command) | High - every write waits for disk |
| `everysec` | Fsync once per second (default) | **~2 seconds worst case** | Low - background thread handles fsync |
| `no` | Let the OS flush when it decides | OS-dependent (up to 30s) | None |

**Worst-case for `everysec`**: If the background fsync takes > 1 second,
the main thread delays writes up to an additional second. If 2 seconds
elapse without fsync completing, a blocking write is forced. The actual
worst-case data loss is 2 seconds, not 1 second as commonly stated
(per antirez's persistence analysis).

**`always` mode group commit**: Multiple concurrent clients' writes are
batched into a single write+fsync. Practical limit ~1000 tx/s on rotational
disk. SSD improves this significantly.

Recommendation: `everysec` balances durability and performance for most workloads. Use `always` only when you cannot tolerate any data loss and accept the throughput cost.

### no-appendfsync-on-rewrite

When set to `yes`, Valkey skips fsync during AOF rewrite or RDB save to
reduce disk contention. Durability drops to `appendfsync no`
during rewrites - up to 30 seconds of data loss in the worst scenario
(with default Linux settings). The default `no` is safer.

## Multi-Part AOF Architecture

Since Valkey 7.0, AOF uses a manifest-based system with multiple files in the `appendonlydir/` directory:

| File Type | Suffix | Description |
|-----------|--------|-------------|
| BASE | `.base.rdb` or `.base.aof` | Snapshot at time of last rewrite |
| INCR | `.incr.aof` | Incremental commands since last rewrite |
| HISTORY | (same suffixes) | Previous files awaiting deletion |

The manifest file tracks all active components:

```
file appendonly.aof.2.base.rdb seq 2 type b
file appendonly.aof.4.incr.aof seq 4 type i
file appendonly.aof.5.incr.aof seq 5 type i
```

Type codes: `b` = base, `i` = incremental, `h` = history.

## Hybrid Persistence (Recommended)

Hybrid persistence combines RDB speed with AOF durability. When `aof-use-rdb-preamble yes` (the default), the AOF base file is written in RDB format during rewrites. Incremental files remain in AOF command format.

```
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
save 3600 1 300 100 60 10000
```

Benefits:
- Fast restarts (RDB base loads quickly)
- High durability (AOF incremental captures recent writes)
- On startup, Valkey loads AOF when both AOF and RDB exist (AOF is more complete)

Recommended production configuration.

## AOF Rewrite

AOF rewrite compacts the log by creating a new base file reflecting the current dataset state, then discarding old incremental files.

### Automatic Rewrite

Triggered when both conditions are met:
1. Current AOF size exceeds last-rewrite size by `auto-aof-rewrite-percentage` (default: 100%)
2. Current AOF size exceeds `auto-aof-rewrite-min-size` (default: 64MB)

If a rewrite fails, Valkey uses an exponential backoff mechanism for retries
to prevent repeated fork storms from failing rewrites (e.g., OOM on fork).

### Manual Rewrite

```bash
valkey-cli BGREWRITEAOF
```

### Monitoring Rewrite

```bash
valkey-cli INFO persistence | grep aof_

# Key fields:
# aof_enabled              - 1 if AOF is on
# aof_rewrite_in_progress  - 1 during rewrite
# aof_last_rewrite_time_sec - duration of last rewrite
# aof_current_size         - current AOF size in bytes
# aof_base_size            - size after last rewrite
```

## Operational Procedures

### Enable AOF at Runtime

```bash
valkey-cli CONFIG SET appendonly yes
valkey-cli CONFIG REWRITE
```

This triggers an initial AOF rewrite to capture the current dataset.

### Recover from Accidental FLUSHALL

If AOF is enabled and a FLUSHALL was accidentally issued:

1. Stop the server immediately (do not let it rewrite)
2. Edit the last `.incr.aof` file and remove the FLUSHALL command
3. Restart the server

### Fix Corrupted AOF

```bash
# Check and repair
valkey-check-aof --fix appendonlydir/appendonly.aof.1.incr.aof

# For the manifest
valkey-check-aof --fix appendonlydir/appendonly.aof.manifest
```

### Disable AOF for Cache-Only

```
appendonly no
```

Or at runtime:

```bash
valkey-cli CONFIG SET appendonly no
valkey-cli CONFIG REWRITE
```

### Startup Log Sequence (Hybrid Persistence)

When loading hybrid AOF (RDB preamble + AOF tail), the server logs:

```
* Reading RDB preamble from AOF file...
* Reading the remaining AOF tail...
```

If the AOF is truncated:

```
# !!! Warning: short read while loading the AOF file !!!
# !!! Truncating the AOF at offset 439 !!!
# AOF loaded anyway because aof-load-truncated is enabled
```

## Production Recommendations

1. **Enable hybrid persistence** - `aof-use-rdb-preamble yes` gives you fast restarts with AOF durability
2. **Use `appendfsync everysec`** for the best durability/performance balance
3. **Keep `no-appendfsync-on-rewrite no`** (default) unless disk contention is severe
4. **Monitor `aof_last_rewrite_time_sec`** - increasing rewrite times indicate growing datasets
5. **Set `auto-aof-rewrite-percentage`** based on your tolerance for disk usage spikes during rewrite
6. **Keep `aof-load-truncated yes`** (default) so the server can recover from power loss mid-write
7. **Test AOF recovery procedures** before you need them
