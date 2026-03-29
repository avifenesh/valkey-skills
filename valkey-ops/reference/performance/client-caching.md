# Client-Side Caching

Use when reducing read latency, offloading read traffic from the server, or
implementing a local cache in application code with server-assisted invalidation.

---

## What It Is

Client-side caching (also called tracking) lets clients keep a local copy of
frequently accessed keys. The server tracks which keys each client has read
and sends invalidation messages when those keys are modified. This eliminates
network round-trips for hot data and reduces server load.

The feature is implemented in `src/tracking.c`. The server maintains a radix
tree (`TrackingTable`) mapping keys to sets of client IDs that have cached them.

## Configuration

Source-verified from `src/config.c`:

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `tracking-table-max-keys` | `1000000` | 0-LONG_MAX | Maximum number of keys tracked server-side. When exceeded, the server evicts keys from the tracking table and sends invalidation to affected clients. 0 means unlimited. |

This is the only server-side configuration for client tracking. The feature is
activated per-client using the `CLIENT TRACKING` command, not via config file.

### Setting the Tracking Table Size

```bash
# Check current setting
valkey-cli CONFIG GET tracking-table-max-keys

# Increase for workloads with many distinct cached keys
valkey-cli CONFIG SET tracking-table-max-keys 5000000

# Reduce if tracking memory overhead is too high
valkey-cli CONFIG SET tracking-table-max-keys 500000
```

Each tracked key entry consumes memory for the radix tree node and the set of
client IDs. Monitor `tracking_total_items` to gauge memory impact.

## Protocol Requirement

Client-side caching invalidation messages are delivered via RESP3 push
notifications. Clients must either:

1. Use RESP3 (`HELLO 3`) to receive push invalidation messages directly
2. Use RESP2 with redirect mode - invalidations are sent to a separate Pub/Sub
   connection via the `__redis__:invalidate` channel

The invalidation channel name is `__redis__:invalidate` (source-verified from
`src/tracking.c` line 197 - the legacy `__redis__` prefix is retained).

## Two Tracking Modes

### Default Mode (Key-Based)

The server remembers every key served to the client and sends invalidation
when any of those specific keys are modified.

```bash
# Enable default tracking
CLIENT TRACKING ON

# With redirect to another client (for RESP2 clients)
CLIENT TRACKING ON REDIRECT <client-id>
```

- Precise invalidation - only keys the client actually read
- Higher server memory usage (one entry per key per client)
- Best for: read-heavy workloads with moderate key diversity

### Broadcasting Mode (Prefix-Based)

Clients subscribe to key prefixes. The server sends invalidation for any key
matching the prefix when modified, regardless of whether the client read it.

```bash
# Track all keys starting with "user:"
CLIENT TRACKING ON BCAST PREFIX user:

# Track all keys (empty prefix)
CLIENT TRACKING ON BCAST
```

- Less precise - may invalidate keys the client never cached
- Lower server memory usage (tracks prefixes, not individual keys)
- Server maintains `PrefixTable` radix tree for prefix matching
- Best for: high-cardinality keyspaces where key-level tracking is too expensive

## OPTIN / OPTOUT Modes

These modes give fine-grained control over which keys are tracked within a
client connection.

### OPTIN Mode

Tracking is off by default. The client must explicitly opt in before each
read using `CLIENT CACHING YES`.

```bash
CLIENT TRACKING ON OPTIN

# Only this next read will be tracked
CLIENT CACHING YES
GET user:1000
```

Source-verified from `src/tracking.c` (`trackingRememberKeys`): when `optin`
is set and `caching_given` is false, the key is not remembered.

### OPTOUT Mode

Tracking is on by default. The client can opt out before specific reads
using `CLIENT CACHING NO`.

```bash
CLIENT TRACKING ON OPTOUT

# This read will NOT be tracked
CLIENT CACHING NO
GET volatile:counter
```

### NOLOOP Option

Prevents a client from receiving invalidation messages for keys that the
same client modified:

```bash
CLIENT TRACKING ON NOLOOP
```

## Monitoring

From `INFO clients` and `INFO stats` (source-verified from `src/server.c`):

| Metric | Section | Meaning |
|--------|---------|---------|
| `tracking_clients` | clients | Number of clients with tracking enabled. |
| `tracking_total_keys` | stats | Total distinct keys in the tracking table. |
| `tracking_total_items` | stats | Total client-key associations (sum across all keys). |
| `tracking_total_prefixes` | stats | Total prefixes registered for broadcasting mode. |

### Checking Tracking State

```bash
# Server-side tracking stats
valkey-cli INFO clients | grep tracking
valkey-cli INFO stats | grep tracking

# Check if a specific client has tracking enabled
valkey-cli CLIENT LIST | grep -i tracking
```

### Capacity Planning

When `tracking_total_keys` approaches `tracking-table-max-keys`, the server
starts evicting tracked keys (sending invalidation to affected clients). This
is normal but causes extra invalidation traffic. If you see frequent evictions,
either:

- Increase `tracking-table-max-keys`
- Switch hot-path clients to broadcasting mode with specific prefixes
- Use OPTIN mode to track only the most valuable keys

## Performance Impact

- Local memory access is orders of magnitude faster than a network round-trip
- Most beneficial for read-heavy workloads with power-law access patterns
  (a small percentage of keys are accessed frequently)
- Particularly effective for immutable or rarely-changed data (user profiles,
  posts, configuration)
- Broadcasting mode has zero server memory cost but generates more invalidation
  messages than default mode
- When the tracking table fills (`tracking-table-max-keys`), evicted entries
  generate "phantom" invalidation messages - this is normal but increases traffic

## Operational Considerations

- Tracking adds memory overhead on the server proportional to the number of
  tracked keys multiplied by the number of tracking clients
- When a client disconnects, its entries are cleaned lazily (the client ID
  is removed from tracking entries as those keys are next accessed)
- The `tracking-table-max-keys` limit applies globally, not per-client
- In cluster mode, tracking works per-node - each node tracks its own keys
- Broadcasting mode with empty prefix (`BCAST` with no `PREFIX`) will send
  invalidation for every write, which can generate significant traffic

## See Also

- [Latency Diagnosis](latency.md) - latency optimization strategies
- [Memory Optimization](memory.md) - memory impact of tracking table overhead
- [Slow Command Investigation](../troubleshooting/slow-commands.md) - hot key detection and mitigation
- [Configuration Essentials](../configuration/essentials.md) - client connection tuning
- [Monitoring Metrics](../monitoring/metrics.md) - `tracking_clients`, `tracking_total_keys` metrics
- [See valkey-dev: tracking](../../../valkey-dev/reference/monitoring/tracking.md) - radix tree structure, invalidation dispatch internals
