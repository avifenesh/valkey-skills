# COMMANDLOG - Unified Command Logging (Valkey 8.1+)

Use when diagnosing slow commands, large requests, or large replies. Replaces the legacy SLOWLOG with a unified logging system that captures three categories.

## Syntax

```
COMMANDLOG GET count type
COMMANDLOG LEN type
COMMANDLOG RESET type
```

## Types

| Type | What it captures | Config parameter |
|------|------------------|-----------------|
| `slow` | Commands exceeding execution time threshold | `commandlog-execution-slower-than` (default: 10000 microseconds) |
| `large-request` | Commands exceeding request size threshold | `commandlog-request-larger-than` (default: 1048576 bytes) |
| `large-reply` | Commands exceeding reply size threshold | `commandlog-reply-larger-than` (default: 1048576 bytes) |

## Examples

```
# Get last 10 slow commands
COMMANDLOG GET 10 slow

# Get commands with large replies (potential N+1 queries)
COMMANDLOG GET 5 large-reply

# Get oversized requests (bulk uploads, large LUA scripts)
COMMANDLOG GET 5 large-request

# Check how many slow entries are logged
COMMANDLOG LEN slow

# Clear the slow log
COMMANDLOG RESET slow
```

## Entry Format

Each entry is an array:
```
1) (integer) id              # Unique log entry ID
2) (integer) timestamp       # Unix timestamp when logged
3) (integer) duration_or_size # Microseconds (slow) or bytes (large-request/large-reply)
4) (array) command_args      # The command and its arguments
5) "client_addr"             # Client IP:port
6) "client_name"             # Connection name (from CLIENT SETNAME)
```

## Configuration

```
# Set slow command threshold to 5ms
CONFIG SET commandlog-execution-slower-than 5000

# Set large request threshold to 512KB
CONFIG SET commandlog-request-larger-than 524288

# Set large reply threshold to 512KB
CONFIG SET commandlog-reply-larger-than 524288

# Max entries retained per type (default 128 each)
CONFIG SET commandlog-slow-execution-max-len 256
CONFIG SET commandlog-large-request-max-len 256
CONFIG SET commandlog-large-reply-max-len 256
```

Set a threshold to `-1` to **disable** that log type (e.g. `CONFIG SET commandlog-reply-larger-than -1`). `0` logs every command of that type - rarely what you want.

### Legacy config aliases

Two pre-8.1 Redis config names still work as aliases:

| Legacy name | Aliased to |
|-------------|------------|
| `slowlog-log-slower-than` | `commandlog-execution-slower-than` |
| `slowlog-max-len` | `commandlog-slow-execution-max-len` |

An existing valkey.conf using the old names continues to work - no rename needed. The two large-request/large-reply configs have no legacy alias (they are new in 8.1).

## Use Cases

**Find latency-causing commands:**
```
COMMANDLOG GET 20 slow
# Look for KEYS, SMEMBERS on large sets, HGETALL on large hashes, unindexed FT.SEARCH
```

**Find N+1 query patterns (large replies):**
```
COMMANDLOG GET 10 large-reply
# Commands returning >1MB suggest missing pagination or over-fetching
```

**Find bulk upload issues:**
```
COMMANDLOG GET 10 large-request
# Large MSET, EVAL with huge scripts, oversized pipeline batches
```

## Migration from SLOWLOG

| Legacy (pre-8.1) | Valkey 8.1+ |
|-------------------|-------------|
| `SLOWLOG GET [count]` | `COMMANDLOG GET <count> slow` |
| `SLOWLOG LEN` | `COMMANDLOG LEN slow` |
| `SLOWLOG RESET` | `COMMANDLOG RESET slow` |
| No equivalent | `COMMANDLOG GET <count> large-request` |
| No equivalent | `COMMANDLOG GET <count> large-reply` |

`SLOWLOG` still works in Valkey 8.1+ and returns from the same underlying log as `COMMANDLOG GET ... slow`. Note that `SLOWLOG GET`'s count is optional (defaults to 10) whereas `COMMANDLOG GET` requires an explicit count.

## Cluster mode

`COMMANDLOG GET` / `LEN` / `RESET` are tagged `REQUEST_POLICY: ALL_NODES` - a cluster-aware client (`valkey-cli -c`, smart SDK) will dispatch the command to every shard and aggregate. For cluster-wide diagnosis, run once with a smart client rather than connecting to each node manually. `LEN` also carries `RESPONSE_POLICY: AGG_SUM` so the aggregated total is the sum across nodes.
