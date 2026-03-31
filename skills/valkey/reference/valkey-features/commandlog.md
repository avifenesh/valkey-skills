# COMMANDLOG - Unified Command Logging (Valkey 8.1+)

Use when diagnosing slow commands, large requests, or large replies. Replaces the legacy SLOWLOG with a unified logging system that captures three categories.

---

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
| `SLOWLOG GET 10` | `COMMANDLOG GET 10 slow` |
| `SLOWLOG LEN` | `COMMANDLOG LEN slow` |
| `SLOWLOG RESET` | `COMMANDLOG RESET slow` |
| No equivalent | `COMMANDLOG GET 10 large-request` |
| No equivalent | `COMMANDLOG GET 10 large-reply` |

SLOWLOG still works in Valkey 8.1+ for backward compatibility but returns the same data as `COMMANDLOG GET ... slow`.
