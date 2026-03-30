# Server Client Management Commands

Use when managing client connections, checking or adapting to server configuration, finding slow or large commands with COMMANDLOG, or debugging connection issues.

---

## Client Management

### CLIENT ID

```
CLIENT ID
```

Returns the unique integer ID of the current connection. Useful for `CLIENT TRACKING REDIRECT` and log correlation.

**Complexity**: O(1)

```
CLIENT ID
-- (integer) 42
```

### CLIENT SETNAME / CLIENT GETNAME

```
CLIENT SETNAME connection-name
CLIENT GETNAME
```

Sets and retrieves a name for the current connection. Named connections appear in `CLIENT LIST` output and server logs, making debugging easier.

**Complexity**: O(1)

```
CLIENT SETNAME worker:orders:1
-- OK

CLIENT GETNAME
-- "worker:orders:1"
```

**Use when**: running multiple application instances and needing to identify which connection is which during debugging or in `CLIENT LIST` output.

### CLIENT INFO

```
CLIENT INFO
```

Returns information about the current connection in the same format as CLIENT LIST but only for this connection. Since 6.2.

**Complexity**: O(1)

```
CLIENT INFO
-- id=42 addr=127.0.0.1:52300 name=worker:orders:1 db=0 ...
```

### CLIENT LIST

```
CLIENT LIST [TYPE normal|master|replica|pubsub]
            [ID client-id [...]]
            [additional filters...]
```

Lists all open client connections with detailed metadata. Each connection is one line with space-separated key=value pairs.

**Complexity**: O(N) where N is the number of connected clients

**Key fields in output**:

| Field | Meaning |
|-------|---------|
| `id` | Unique client ID |
| `addr` | Client address:port |
| `name` | Connection name (from CLIENT SETNAME) |
| `db` | Current database number |
| `cmd` | Last command executed |
| `age` | Connection age in seconds |
| `idle` | Idle time in seconds |
| `flags` | Client flags (N=normal, S=replica, M=master, P=pubsub, x=executing) |
| `omem` | Output buffer memory usage |
| `tot-mem` | Total memory consumed by this client |

**Filtering (Valkey 9.0+)**:

```
-- Filter by connection name
CLIENT LIST NAME worker:*

-- Filter by library
CLIENT LIST LIB-NAME ioredis

-- Filter by idle time (seconds)
CLIENT LIST IDLE 300

-- Filter by flags
CLIENT LIST FLAGS S

-- Negation filters
CLIENT LIST NOT-TYPE replica NOT-DB 0
```

```
-- Find idle connections
CLIENT LIST IDLE 600
-- Shows connections idle for 10+ minutes

-- Find by type
CLIENT LIST TYPE pubsub
```

**Use when**: debugging connection leaks, finding blocked or idle clients, or identifying which application instances are connected.

### CLIENT NO-EVICT

```
CLIENT NO-EVICT ON|OFF
```

When ON, prevents this connection from being evicted when the server hits `maxmemory`. Useful for admin/monitoring connections that must stay alive. Since 7.0.

**Complexity**: O(1)

### CLIENT NO-TOUCH

```
CLIENT NO-TOUCH ON|OFF
```

When ON, commands from this connection do not update the LRU/LFU counters of accessed keys. Useful for monitoring or analytics reads that should not affect eviction decisions. Since 7.2.

**Complexity**: O(1)

```
-- Monitoring connection that should not warm up keys
CLIENT NO-TOUCH ON
GET cold:key    -- does not update idle time or frequency counter
```

---

## Configuration

### CONFIG GET

```
CONFIG GET parameter [parameter ...]
```

Returns the current value of configuration parameters. Supports glob patterns. Read-only - does not change any settings.

**Complexity**: O(N) where N is the number of matching parameters

```
-- Check memory limit
CONFIG GET maxmemory
-- 1) "maxmemory"
-- 2) "1073741824"

-- Check eviction policy
CONFIG GET maxmemory-policy
-- 1) "maxmemory-policy"
-- 2) "allkeys-lru"

-- Glob pattern
CONFIG GET *timeout*
-- Returns all timeout-related settings

-- Multiple patterns
CONFIG GET maxmemory maxmemory-policy hz
```

**Commonly checked parameters for app developers**:

| Parameter | What it tells you |
|-----------|-------------------|
| `maxmemory` | Memory limit (0 = unlimited) |
| `maxmemory-policy` | Eviction policy (noeviction, allkeys-lru, volatile-lfu, etc.) |
| `timeout` | Idle client timeout in seconds (0 = disabled) |
| `databases` | Number of available databases |
| `hz` | Server timer frequency (affects expire precision) |
| `save` | RDB snapshot schedule |
| `appendonly` | Whether AOF is enabled |
| `cluster-enabled` | Whether cluster mode is active |

**Use when**: verifying server configuration matches your application's assumptions, or dynamically adapting behavior based on server settings.

---

## Command Logging

### COMMANDLOG GET

```
COMMANDLOG GET count type
```

Returns entries from the command log. Valkey 8.1+ replaces SLOWLOG with a unified command log that tracks three categories. The `type` argument is required.

**Complexity**: O(N) where N is the count

**Types**:

| Type | What it captures |
|------|------------------|
| `slow` | Commands exceeding `commandlog-slow-execution-time` threshold |
| `large-request` | Commands exceeding `commandlog-large-request-size` threshold |
| `large-reply` | Commands exceeding `commandlog-large-reply-size` threshold |

**Entry format**: Each entry is an array of [id, timestamp, duration_or_size, [command args], client_addr, client_name].

```
-- Get last 10 slow commands
COMMANDLOG GET 10 slow

-- Get commands with large replies
COMMANDLOG GET 5 large-reply
```

**Use when**: identifying slow commands causing latency spikes, or finding commands that send/receive unusually large payloads.

### SLOWLOG GET (Legacy)

```
SLOWLOG GET [count]
```

Returns the last `count` entries from the slow log (default: all). Legacy command - use COMMANDLOG GET on Valkey 8.1+.

**Complexity**: O(N)

```
SLOWLOG GET 10
-- Each entry: [id, timestamp, duration_microseconds, [command args], client_addr, client_name]
```

**Use when**: on Valkey versions before 8.1, or for quick slow command diagnostics.

---

## See Also

- [Server Information](server.md) - INFO, MEMORY USAGE, OBJECT, DBSIZE
- [Server Operations](server-ops.md) - SCAN, COPY, WAIT/WAITAOF, debugging
- [Performance Best Practices](../best-practices/performance.md) - pipelining, connection management, COMMANDLOG analysis
- [Cluster Best Practices](../best-practices/cluster.md) - cluster-aware client configuration
- [Compatibility and Migration](../overview/compatibility.md) - extended-redis-compatibility mode for CONFIG SET
