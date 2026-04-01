Use when running Pub/Sub workloads, managing subscriber memory, configuring

# Pub/Sub Operational Configuration
keyspace notifications, or operating sharded Pub/Sub in cluster mode. All
defaults verified against `src/config.c` and `src/server.h` in valkey-io/valkey.

## Contents

- Client Output Buffer Limits for Pub/Sub (line 20)
- Subscriber Memory Management (line 68)
- Keyspace Notifications (line 112)
- Sharded Pub/Sub (Cluster Mode) (line 181)
- Pattern Subscription Performance (line 221)
- Scaling Pub/Sub (line 246)
- Monitoring Subscriber Count and Memory (line 253)
- See Also (line 293)

---

## Client Output Buffer Limits for Pub/Sub

Pub/Sub subscribers receive messages asynchronously. If a subscriber cannot
consume messages fast enough, Valkey buffers them in the client output buffer.
Without limits, a slow subscriber can exhaust server memory.

### Default Values

```
client-output-buffer-limit pubsub 32mb 8mb 60
```

| Component | Default | Description |
|-----------|---------|-------------|
| Hard limit | `32mb` | Connection killed immediately when buffer exceeds this. |
| Soft limit | `8mb` | Soft threshold - connection killed if exceeded for `soft-seconds`. |
| Soft seconds | `60` | Seconds the soft limit must be exceeded before disconnect. |

Source reference: `clientBufferLimitsDefaults` at line 184 in config.c:
`{1024*1024*32, 1024*1024*8, 60}` for pubsub class.

For comparison, the other client classes:

| Class | Hard | Soft | Seconds |
|-------|------|------|---------|
| normal | `0` (unlimited) | `0` | `0` |
| replica | `256mb` | `64mb` | `60` |
| pubsub | `32mb` | `8mb` | `60` |

### When to Adjust

- **High-throughput pub/sub**: Increase hard limit if legitimate subscribers
  occasionally lag (e.g., during GC pauses). Try `64mb 16mb 60`.
- **Memory-constrained servers**: Lower limits to protect against slow
  subscribers. Try `8mb 2mb 30`.
- **Many subscribers**: With 1000 subscribers at 32mb each, worst case is 32GB
  of buffer memory. Factor this into `maxmemory` planning.

### Setting at Runtime

```
CONFIG SET client-output-buffer-limit "pubsub 64mb 16mb 60"
```

This sets all three values for the pubsub class in a single command.

---

## Subscriber Memory Management

### Monitoring Subscriber Memory

```
# Total output buffer memory across all clients
INFO clients
# Look for: client_recent_max_output_buffer (peak output buffer size)

# Per-client detail
CLIENT LIST TYPE pubsub
# Key fields:
#   omem  - output buffer memory usage
#   obl   - output buffer length (replies queued)
#   oll   - output list length (objects queued)
#   sub   - number of channel subscriptions
#   psub  - number of pattern subscriptions
```

### Warning Signs

| Metric | Threshold | Action |
|--------|-----------|--------|
| `omem` on any client | > soft limit | Subscriber falling behind - check consumer health |
| `client_recent_max_output_buffer` | > 50% of hard limit | Approaching disconnect threshold |
| Frequent disconnects in logs | `"Client ... output buffer limit reached"` | Increase limits or fix slow consumer |

### Interaction with maxmemory-clients

When `maxmemory-clients` is set (e.g., `5%` of maxmemory), client eviction kicks in before output buffer limits. Client eviction disconnects the client using the most memory first, regardless of class. A slow Pub/Sub subscriber may be disconnected by client eviction before hitting the pubsub buffer hard limit. Use `CLIENT NO-EVICT on` for critical monitoring or control-plane subscribers.

### Anti-Pattern: Unlimited Pub/Sub Buffers

Setting the pubsub hard limit to `0` (unlimited) is dangerous. A single slow subscriber can consume all available memory, leading to OOM or eviction of data keys. Always set explicit hard limits.

### Mitigation Strategies

1. **Right-size buffer limits** - match to your subscriber's processing speed
2. **Use dedicated instances** for heavy Pub/Sub workloads
3. **Monitor `omem`** per client and alert before hard limit
4. **Prefer SUBSCRIBE over PSUBSCRIBE** when possible (see pattern performance below)

---

## Keyspace Notifications

Keyspace notifications publish events when keys are modified. Disabled by
default because they consume CPU even with no subscribers.

### Configuration

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `notify-keyspace-events` | `""` (disabled) | yes | Event flags string. Empty = disabled. |

Source reference: line 3495 in config.c (special config). Default is `0`
(no flags) per `server.notify_keyspace_events` initialization.

### Event Type Flags

Compose the flag string from these characters (source: server.h lines 687-704):

| Flag | Event Type | Description |
|------|-----------|-------------|
| `K` | Keyspace | Publish to `__keyspace@<db>__:<key>` channel |
| `E` | Keyevent | Publish to `__keyevent@<db>__:<event>` channel |
| `g` | Generic | Non-type-specific commands: DEL, EXPIRE, RENAME, etc. |
| `$` | String | String commands: SET, APPEND, INCR, etc. |
| `l` | List | List commands: LPUSH, RPOP, LINSERT, etc. |
| `s` | Set | Set commands: SADD, SREM, SMOVE, etc. |
| `h` | Hash | Hash commands: HSET, HDEL, HINCRBY, etc. |
| `z` | Sorted set | Sorted set commands: ZADD, ZREM, ZINCRBY, etc. |
| `x` | Expired | Key expired events (TTL reached) |
| `e` | Evicted | Key evicted events (maxmemory policy) |
| `t` | Stream | Stream commands: XADD, XTRIM, etc. |
| `m` | Key miss | Key miss events (command on non-existing key) |
| `d` | Module | Module-generated key space notifications |
| `n` | New key | New key creation events |
| `A` | Alias | Equivalent to `g$lshzxetd` - all event types except `m` and `n` |

At least one of `K` or `E` must be present, plus one or more event type flags.

### Common Configurations

```
# Expired key events only (cache invalidation use case)
CONFIG SET notify-keyspace-events Ex

# All events on keyspace channel
CONFIG SET notify-keyspace-events KA

# Expired + evicted events
CONFIG SET notify-keyspace-events Exe

# String SET operations only
CONFIG SET notify-keyspace-events K$

# Disable notifications
CONFIG SET notify-keyspace-events ""
```

### Performance Impact

Keyspace notifications add overhead per matching operation:
- Each notification generates a Pub/Sub message internally
- Cost scales with number of subscribers
- `A` (all events) on a high-throughput instance can be significant
- Enable only the specific flags you need

**Anti-pattern**: Enabling `notify-keyspace-events "AKE"` (all events) on a high-write instance generates a Pub/Sub message for every write operation, consuming significant CPU and memory even with zero subscribers.

---

## Sharded Pub/Sub (Cluster Mode)

Standard Pub/Sub in cluster mode broadcasts messages to all nodes. Sharded
Pub/Sub (available since Valkey 7.0) routes messages through hash slots,
so they only reach the node that owns the channel's slot.

### Commands

| Command | Scope | Description |
|---------|-------|-------------|
| `SUBSCRIBE` | Global | Messages broadcast to all cluster nodes |
| `SSUBSCRIBE` | Sharded | Messages routed by channel hash slot |
| `PUBLISH` | Global | Broadcast to all nodes |
| `SPUBLISH` | Sharded | Route to slot owner only |

### When to Use Sharded Pub/Sub

- **High-throughput channels**: Sharded avoids broadcasting, reducing cross-node
  traffic
- **Many channels**: Distributes load across cluster nodes
- **Channel-per-entity patterns**: e.g., `user:{12345}:events` - naturally maps
  to hash slots

### Cluster Pub/Sub Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `cluster-allow-pubsubshard-when-down` | `yes` | Allow sharded Pub/Sub when cluster is not fully covered. |
| `acl-pubsub-default` | `resetchannels` | Default Pub/Sub channel permissions for new ACL users. |

Source references:
- `cluster-allow-pubsubshard-when-down`: verified in essentials.md
- `acl-pubsub-default`: line 3342, default `0` which maps to `resetchannels`

`acl-pubsub-default resetchannels` means new users have NO Pub/Sub
channel access by default. Grant explicitly with `&pattern` or `allchannels`.

---

## Pattern Subscription Performance

`PSUBSCRIBE` matches every published message against each pattern subscription.
This has O(N) cost per message where N is the total number of active pattern
subscriptions across all clients.

### Impact

| Pattern count | Messages/sec | Approximate overhead |
|---------------|-------------|---------------------|
| < 100 | Any | Negligible |
| 1,000 | 10,000 | Measurable - monitor CPU |
| 10,000+ | 10,000+ | Significant - consider alternatives |

### Recommendations

1. **Prefer exact SUBSCRIBE** when the channel name is known
2. **Use sharded Pub/Sub** (SSUBSCRIBE) in cluster mode
3. **Consolidate patterns** - fewer broad patterns beat many narrow ones
4. **Monitor** with `CLIENT LIST TYPE pubsub` and check `psub` count
5. **Consider keyspace notifications** as alternative to pattern-matching
   application events

---

## Scaling Pub/Sub

- **Horizontal**: Use sharded Pub/Sub (`SSUBSCRIBE`/`SPUBLISH`) in cluster mode to distribute load across nodes instead of broadcasting to all
- **Vertical**: Raise `client-output-buffer-limit pubsub` and ensure `maxmemory-clients` accommodates subscriber buffer memory
- **Subscriber health**: Monitor `omem` (output buffer memory) in `CLIENT LIST` output to identify slow subscribers before they hit buffer limits


## Monitoring Subscriber Count and Memory

### Key INFO Metrics

```
INFO clients
```

| Metric | Description |
|--------|-------------|
| `connected_clients` | Total connected clients (all types) |
| `pubsub_channels` | Number of channels with at least one subscriber |
| `pubsub_patterns` | Number of active pattern subscriptions |

```
INFO stats
```

| Metric | Description |
|--------|-------------|
| `pubsub_channels` | Active channels |
| `pubsub_patterns` | Active patterns |

### Per-Client Monitoring

```
CLIENT LIST TYPE pubsub
```

Fields to watch: `omem` (output memory), `sub` (subscriptions), `psub`
(pattern subscriptions), `idle` (seconds since last activity).

### Alerting Thresholds

| Metric | Warning | Critical |
|--------|---------|----------|
| `pubsub_patterns` | > 500 | > 5,000 |
| Max `omem` across pubsub clients | > 50% of hard limit | > 75% of hard limit |
| Subscriber disconnects/min | > 1 | > 10 |
