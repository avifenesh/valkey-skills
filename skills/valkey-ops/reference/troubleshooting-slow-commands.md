# Slow Command Investigation

Use when clients report high latency, timeouts, or when monitoring shows elevated command execution times.

## Contents

- Symptoms (line 17)
- Diagnosis (line 25)
- Common Culprits (line 111)
- Resolution (line 177)
- Hot Key Detection (line 228)

---

## Symptoms

- Client-side timeouts or increased error rates
- `LATENCY LATEST` shows spikes on `command` or `fast-command` events
- Commandlog (slowlog) entries accumulating
- `CLIENT LIST` shows connections with long-running commands
- Overall throughput drops while CPU usage stays moderate (blocking on main thread)

## Diagnosis

### Step 1: Check Commandlog (Slowlog)

Source-verified defaults from `src/config.c`:
- `commandlog-execution-slower-than` (alias `slowlog-log-slower-than`): 10000 microseconds (10ms)
- `commandlog-slow-execution-max-len` (alias `slowlog-max-len`): 128 entries

```bash
# View recent slow commands
valkey-cli SLOWLOG GET 25

# Each entry:
# 1) Unique ID
# 2) Unix timestamp
# 3) Execution time in microseconds
# 4) Command + arguments
# 5) Client IP:port
# 6) Client name
```

Look for patterns:
- Same command type repeated (e.g., many KEYS or SMEMBERS entries)
- Same client IP generating most slow entries
- Duration increasing over time (growing dataset)
- Sudden spike in entries at a specific timestamp (batch job, deployment)

### Step 2: Check for Large Request/Reply Commands

```bash
# Commands with oversized requests (> 1MB default)
valkey-cli COMMANDLOG GET 25 large-request

# Commands with oversized replies (> 1MB default)
valkey-cli COMMANDLOG GET 25 large-reply
```

Large replies often indicate retrieving entire collections (`HGETALL`,
`SMEMBERS`, `LRANGE 0 -1`) without pagination.

### Step 3: Check Latency Monitor

```bash
# Enable if not already active
valkey-cli CONFIG SET latency-monitor-threshold 10

# Check for command-related latency events
valkey-cli LATENCY LATEST
valkey-cli LATENCY DOCTOR
```

The `command` event tracks slow O(N) commands. The `fast-command` event
tracks commands that are expected to be O(1) but exceeded the threshold -
this often indicates CPU scheduling issues or memory allocation stalls.

### Step 4: Inspect Active Clients

```bash
valkey-cli CLIENT LIST
```

| Field | What to check |
|-------|--------------|
| `cmd` | Currently executing command |
| `age` | Connection age |
| `idle` | Seconds since last activity |
| `qbuf` | Query buffer size (large = big incoming command) |
| `omem` | Output buffer memory (large = big response pending) |
| `flags` | `b` = blocked, `x` = in MULTI, `d` = key tracking dirty |
| `tot-mem` | Total memory used by this client |

Look for:
- Clients with `flags` containing `b` (blocked on BRPOP, BLPOP, etc.)
- Clients with high `omem` (consuming output buffer memory)
- Clients running `SUBSCRIBE` with no consumer processing messages

### Step 5: Check Command Stats

```bash
valkey-cli INFO commandstats
```

Each command shows: `calls`, `usec`, `usec_per_call`, `rejected_calls`,
`failed_calls`. Sort by `usec_per_call` to find the slowest commands on
average.

## Common Culprits

### KEYS * in Production

The `KEYS` command scans the entire keyspace in a single blocking operation.
With millions of keys, this can block for seconds.

```bash
# NEVER in production:
KEYS user:*

# Use instead:
SCAN 0 MATCH user:* COUNT 100
# Iterate with the returned cursor until 0
```

### Large Collection Operations

| Command | Problem | Alternative |
|---------|---------|------------|
| `SMEMBERS` on huge set | Returns all members at once | `SSCAN` with cursor |
| `HGETALL` on huge hash | Returns all fields at once | `HSCAN` with cursor |
| `LRANGE 0 -1` on long list | Returns entire list | Paginate with `LRANGE start stop` |
| `SORT` on large list | O(N*log(N)) + O(N) | Sort client-side or use sorted sets |
| `ZRANGEBYSCORE` unbounded | Can return millions | Add `LIMIT offset count` |

### Large Key Deletion

`DEL` on a key with millions of elements blocks the main thread. Use `UNLINK`
for asynchronous deletion.

```bash
# Blocking (bad for large keys):
DEL my_huge_set

# Non-blocking (freed in background):
UNLINK my_huge_set
```

### Long-Running Lua Scripts

Lua scripts execute atomically on the main thread. A script that runs for
seconds blocks all other clients.

```bash
# Check for Lua-related slowlog entries
SLOWLOG GET 25
# Look for EVAL / EVALSHA entries with high duration

# Set a script timeout
CONFIG SET lua-time-limit 5000    # 5 seconds, then allows SCRIPT KILL
```

### Pub/Sub Without Consumers

Publishers pushing to channels with slow or absent subscribers cause output
buffer growth on the server.

```bash
# Check pub/sub clients
CLIENT LIST TYPE pubsub

# Set buffer limits
CONFIG SET client-output-buffer-limit "pubsub 32mb 8mb 60"
```

## Resolution

### 1. Lower Commandlog Threshold for Investigation

```bash
# Temporarily capture commands slower than 1ms
CONFIG SET commandlog-execution-slower-than 1000

# Increase buffer for more history
CONFIG SET commandlog-slow-execution-max-len 512

# After investigation, restore defaults
CONFIG SET commandlog-execution-slower-than 10000
CONFIG SET commandlog-slow-execution-max-len 128
```

### 2. Rename or Disable Dangerous Commands

```
# In valkey.conf (cannot be set at runtime)
rename-command KEYS ""
rename-command FLUSHALL ""
rename-command FLUSHDB ""
```

### 3. Use OBJECT ENCODING to Check Data Structure Efficiency

```bash
# Check if a key has been promoted to a less efficient encoding
OBJECT ENCODING mykey

# If a hash shows "hashtable" instead of "listpack", it has exceeded
# encoding thresholds - consider splitting the data
```

### 4. Pipeline Instead of Individual Commands

Client-side optimization. Instead of N round-trips, batch commands into
pipelines of 50-100 commands to reduce network overhead.

### 5. Enable I/O Threads for Throughput

If the bottleneck is I/O (many clients, moderate command complexity):

```bash
CONFIG SET io-threads 4
```

I/O threads do not help with slow individual commands - they parallelize
the I/O path, not command execution.

## Hot Key Detection

A hot key receives disproportionate operations. In cluster mode, it means one
shard handles all the load while others idle. Five detection methods:

```bash
# Method 1: --hotkeys mode (requires LFU eviction policy)
valkey-cli CONFIG SET maxmemory-policy allkeys-lfu
valkey-cli --hotkeys
# Reports keys ranked by access frequency using OBJECT FREQ internally

# Method 2: Individual key frequency (LFU mode required)
valkey-cli OBJECT FREQ <key>

# Method 3: MONITOR sampling (brief use only - adds overhead)
timeout 10 valkey-cli MONITOR > /tmp/monitor.log
# Parse most accessed keys from the capture

# Method 4: OBJECT IDLETIME for cold key detection (LRU mode)
valkey-cli OBJECT IDLETIME <key>
# Find keys never accessed (wasted memory)

# Method 5: Big key analysis (memory, not frequency)
valkey-cli --bigkeys       # Largest key per data type
valkey-cli --memkeys       # Ranks by actual MEMORY USAGE
```

Mitigation: read replicas for hot reads, client-side caching with
`CLIENT TRACKING`, key sharding (split hot key across sub-keys), or
cluster rebalancing to move the hot slot to a less-loaded shard.

---
