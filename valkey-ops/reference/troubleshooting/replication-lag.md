# Replication Lag Diagnosis

Use when replicas fall behind the primary, replication breaks are frequent,
or replica data staleness is unacceptable.

---

## Symptoms

- `master_last_io_seconds_ago` increasing beyond expected values
- Growing offset delta between primary and replica replication offsets
- `master_link_status` is `down`
- Application reads from replicas return stale data
- Replicas frequently trigger full resync instead of partial resync
- Valkey logs show: `Disconnected from MASTER... Retrying...`

## Diagnosis

### Step 1: Check Replication Status

On the primary:

```bash
valkey-cli INFO replication
```

Key fields:

| Field | What to check |
|-------|--------------|
| `connected_slaves` | Number of replicas connected |
| `slave0:...offset=N` | Replica's replication offset |
| `master_repl_offset` | Primary's current offset |
| `repl_backlog_active` | Whether backlog is enabled (should be 1) |
| `repl_backlog_size` | Size of the replication backlog |
| `repl_backlog_first_byte_offset` | Oldest offset in the backlog |

Calculate lag: `master_repl_offset - slave_offset = bytes behind`

On the replica:

```bash
valkey-cli INFO replication
```

| Field | What to check |
|-------|--------------|
| `master_link_status` | `up` or `down` |
| `master_last_io_seconds_ago` | Seconds since last data from primary |
| `master_link_down_since_seconds` | How long link has been down |
| `master_sync_in_progress` | Whether full sync is happening |
| `slave_repl_offset` | Replica's current offset |
| `slave_read_repl_offset` | How far the replica has read |

### Step 2: Check Network

```bash
# Test latency between primary and replica
valkey-cli -h <primary-host> --latency

# Check bandwidth
iperf3 -c <primary-host>

# Check for packet loss
ping -c 100 <primary-host> | tail -3
```

### Step 3: Check Replica Load

```bash
# On the replica - check if expensive commands are running
valkey-cli SLOWLOG GET 10
valkey-cli CLIENT LIST

# Check disk I/O (if replica is doing RDB loads)
iostat -x 1 5
```

### Step 4: Check Output Buffer

```bash
# On the primary - check replica output buffer usage
valkey-cli CLIENT LIST | grep "flags=S"

# Look for omem (output memory) values
# High omem means the primary is buffering data the replica can't consume
```

## Resolution

### 1. Increase Replication Backlog

The backlog must be large enough to hold all writes during the longest expected
disconnection. If the replica reconnects and its offset is still in the backlog,
it can do a partial resync instead of a full resync.

```bash
# Formula: backlog_size >= write_rate_bytes_per_sec * max_disconnect_seconds
# Example: 10MB/s writes * 60s disconnect = 600MB backlog

valkey-cli CONFIG SET repl-backlog-size 600mb
valkey-cli CONFIG REWRITE
```

Default is 10MB, which is almost always too small for production.

### 2. Enable Diskless Replication

Full resyncs normally write an RDB file to disk, then send it. Diskless
replication streams the RDB directly to the replica over the socket, avoiding
disk I/O on both sides.

```bash
# On the primary
valkey-cli CONFIG SET repl-diskless-sync yes

# Delay before starting sync (to batch multiple replica syncs)
valkey-cli CONFIG SET repl-diskless-sync-delay 5
```

### 3. Fix Network Issues

- Ensure sufficient bandwidth between primary and replica
- Place replicas in the same datacenter or availability zone
- Check for network-level throttling or QoS policies
- Verify firewall rules are not causing intermittent drops

### 4. Reduce Replica Load

```bash
# Check if replica is running expensive read commands
# KEYS, SORT on large datasets, SMEMBERS on huge sets

# Disable replica AOF if not needed
valkey-cli CONFIG SET appendonly no

# Point read traffic to dedicated read replicas, not all replicas
```

### 5. Adjust Client Output Buffer Limits

```bash
# Increase replica output buffer limits
valkey-cli CONFIG SET client-output-buffer-limit "replica 512mb 128mb 60"
```

Format: `replica <hard-limit> <soft-limit> <soft-seconds>`

If the replica can't keep up and the output buffer exceeds the hard limit,
the primary disconnects the replica, forcing a full resync. Increasing the
limit gives more room but uses more memory on the primary.

### 6. Tune Replication Timeout

```bash
# Default is 60 seconds - increase if network is lossy
valkey-cli CONFIG SET repl-timeout 120
```

Source-verified: `repl-timeout` defaults to 60 in `src/config.c` line 3391.

## Monitoring

Set up alerts for:

```bash
# Replication offset delta (bytes behind)
# WARN: > 1MB
# CRITICAL: > 100MB

# master_last_io_seconds_ago
# WARN: > 10s
# CRITICAL: > 30s

# master_link_status
# CRITICAL: down for > 60s

# Full resync count (should be rare)
# WARN: any full resync after initial setup
```

---

## See Also

- [Replication Setup](../replication/setup.md) - primary-replica configuration
- [Replication Tuning](../replication/tuning.md) - backlog sizing, diskless sync
- [Replication Safety](../replication/safety.md) - min-replicas write safety
- [Troubleshooting OOM](oom.md) - OOM on primary can cause replica disconnection
- [Monitoring Alerting](../monitoring/alerting.md) - replication lag alert rules
- [See valkey-dev: replication overview](../valkey-dev/reference/replication/overview.md) - replication protocol internals
