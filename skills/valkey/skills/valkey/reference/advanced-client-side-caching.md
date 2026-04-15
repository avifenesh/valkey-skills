# Client-Side Caching with CLIENT TRACKING

Use when implementing server-assisted client-side caching, choosing between tracking modes, wiring invalidation in RESP2 libraries, or understanding what cache consistency tracking provides.

## Contents

- Protocol Basics: RESP3 vs RESP2 (line 13)
- Tracking Modes (line 46)
- Tracking Table Limits (line 84)
- Implementation with GLIDE (line 100)
- Implementation with redis-py and ioredis (line 117)
- Cache Consistency Guarantees (line 158)
- Memory Impact (line 175)
- Connection Management (line 187)
- Best Practices (line 205)
- Valkey Version Notes (line 228)

---

## Protocol Basics: RESP3 vs RESP2

Server-assisted client-side caching lets an application store key values locally and receive server push messages when those keys change, eliminating round-trips for repeated hot reads.

### RESP3 (Single-Connection)

RESP3 supports server push on the same connection used for commands:

```
Client -> Server: HELLO 3
Client -> Server: CLIENT TRACKING ON [NOLOOP]
Client -> Server: GET user:1000:profile
Server -> Client: <bulk string value>

-- When any client modifies user:1000:profile:
Server -> Client: <push frame> INVALIDATE ["user:1000:profile"]
```

The client's read loop must handle push frames and evict the local entry on `INVALIDATE`.

### RESP2 (Two-Connection Redirect)

RESP2 does not support push messages. Invalidation is delivered via a dedicated Pub/Sub connection:

```
-- Connection A (invalidation only - enters Pub/Sub mode):
CLIENT ID
:7
SUBSCRIBE __redis__:invalidate

-- Connection B (data commands):
CLIENT TRACKING ON REDIRECT 7 [NOLOOP]
GET user:1000:profile

-- When any client modifies user:1000:profile:
-- Connection A receives Pub/Sub message on __redis__:invalidate
-- Payload: array of invalidated key names, or nil for full flush
```

`__redis__:invalidate` is the fixed channel name used by both Redis and Valkey.

### NOLOOP Option

Suppresses self-invalidation: when a client that tracking is ON modifies a key it previously read, Valkey will not send an invalidation back to that same client.

```
CLIENT TRACKING ON NOLOOP
```

Usually the right choice for write-through applications that update their own cache on write.

---

## Tracking Modes

| Mode | Command | Server Memory | Precision | Use When |
|------|---------|--------------|-----------|----------|
| Default | `CLIENT TRACKING ON` | Per (key, client) entry | Precise - only keys client read | Bounded hot key sets |
| BCAST | `CLIENT TRACKING ON BCAST PREFIX user:` | Per prefix subscription | Imprecise - all matching keys | High-cardinality keyspaces, cluster setups |
| OPTIN | `CLIENT TRACKING ON OPTIN` + `CLIENT CACHING YES` before each hot read | Per opted-in key | Precise | Most reads are cold; only a few benefit from caching |
| OPTOUT | `CLIENT TRACKING ON OPTOUT` + `CLIENT CACHING NO` before excluded reads | Per tracked key | Precise | Most reads should be tracked; exclude high-churn keys |

BCAST example:
```
CLIENT TRACKING ON BCAST PREFIX user: PREFIX session:
```

OPTIN/OPTOUT example:
```
CLIENT TRACKING ON OPTIN
GET user:preferences        # NOT tracked
CLIENT CACHING YES
GET user:profile            # tracked
```

---

## Tracking Table Limits

In default mode, the server maintains a table mapping tracked keys to client sets.

```
# Default: 1,000,000 entries across all clients
CONFIG SET tracking-table-max-keys 1000000
```

**When the table is full**, Valkey evicts random entries and sends invalidations to affected clients even though the keys have not changed. This causes unnecessary cache misses - not errors.

Detect saturation:

```
127.0.0.1:6379> INFO stats
tracking_table_entries:1000000    # at the limit - spurious invalidations are occurring
```

**Sizing rule of thumb**: `clients * average_tracked_keys_per_client`. For 100 clients tracking 5,000 keys each, that is 500,000 entries - well under the default. For 1,000 clients at the same rate, you need 5,000,000 - increase the config or switch to BCAST mode.

---

## Implementation with GLIDE

GLIDE (Valkey's official multi-language client) has built-in client-side caching via `CacheConfig`. It handles the tracking protocol, push message parsing, connection management, and local cache eviction automatically.

```python
# Python example
from glide import GlideClient, GlideClientConfiguration, CacheConfig

config = GlideClientConfiguration(
    addresses=[...],
    client_cache_config=CacheConfig(max_size=1000)
)
client = await GlideClient.create(config)

# Reads are transparently cached; invalidations handled internally
value = await client.get("user:1000:profile")
```

GLIDE abstracts RESP3 vs RESP2 differences and manages the dedicated invalidation connection when needed. The `max_size` parameter bounds local memory. See the per-language GLIDE skills (valkey-glide-python, valkey-glide-java, valkey-glide-nodejs) for language-specific API details and Java/Node.js examples.

---

## Implementation with redis-py and ioredis

These libraries do not include built-in tracking support. Use the RESP2 two-connection model manually. The pattern is the same for both:

1. Subscribe to `__redis__:invalidate` on a dedicated Pub/Sub connection.
2. Get that connection's client ID.
3. Enable tracking on the data connection with `CLIENT TRACKING ON REDIRECT <id> NOLOOP`.
4. On each Pub/Sub message: if payload is `nil`, flush entire local cache (server reset); otherwise evict each key in the array.

```python
# redis-py sketch
async def setup_tracking(data_conn, inval_conn):
    client_id = await inval_conn.client_id()
    pubsub = inval_conn.pubsub()
    await pubsub.subscribe("__redis__:invalidate")
    await data_conn.execute_command("CLIENT", "TRACKING", "ON", "REDIRECT", client_id, "NOLOOP")

    async def handle():
        async for msg in pubsub.listen():
            if msg["type"] == "message":
                keys = msg["data"]
                if keys is None:
                    local_cache.clear()
                else:
                    for k in (keys if isinstance(keys, list) else [keys]):
                        local_cache.pop(k.decode(), None)
    asyncio.create_task(handle())
```

```javascript
// ioredis sketch
async function setupTracking(dataConn, invalConn) {
  await invalConn.subscribe('__redis__:invalidate');
  const clientId = await invalConn.client('ID');
  await dataConn.call('CLIENT', 'TRACKING', 'ON', 'REDIRECT', clientId, 'NOLOOP');
  invalConn.on('message', (ch, msg) => {
    if (msg === null) localCache.clear();
    else (Array.isArray(msg) ? msg : [msg]).forEach(k => localCache.delete(k));
  });
}
```

---

## Cache Consistency Guarantees

**What tracking guarantees**: When a tracked key is modified, an invalidation is sent to all clients that read it before the write response returns to the writer. Stale reads cannot persist indefinitely.

**What tracking does NOT guarantee**:

- **Zero stale window**: There is a network delay between write and invalidation arrival. Brief stale reads during this window are possible.
- **Multi-key atomicity**: Two keys updated in sequence generate two independent invalidations with no ordering guarantee.
- **Delivery across reconnects**: Pending invalidations are dropped on disconnect. Always flush the local cache on reconnect.
- **Persistence across restarts/failover**: The tracking table is in-memory. After a restart or primary failover, all tracking state is gone - flush local cache on reconnect.

```python
async def on_reconnect():
    local_cache.clear()    # always flush on reconnect
    await setup_tracking(data_conn, inval_conn)
```

---

## Memory and Connection Management

**Server memory (default mode)**: ~64-128 bytes per (key, client) entry. At 1,000,000 entries: 64-128 MB. Check `tracking_table_entries` in `INFO stats`.

**Server memory (BCAST mode)**: minimal - only prefix subscriptions per client, not per-key entries.

**Client memory**: entirely application-managed. Set a size cap with LRU eviction to avoid unbounded growth. GLIDE's `CacheConfig.max_size` does this automatically.

**Invalidation connection lifecycle**: the RESP2 Pub/Sub connection must stay alive continuously. If it drops, invalidations stop arriving and the local cache silently goes stale. Use `CLIENT NO-EVICT ON` on it if the server is under memory pressure. Never reuse it for data commands.

**Connection pools**: standard interchangeable pools do not work with default tracking mode - tracking state is per-connection. Options: dedicate one long-lived connection per application instance, switch to BCAST mode, or use GLIDE (which manages this automatically).

---

## Best Practices

### Keys to Track (High Benefit)

| Key Type | Reason |
|----------|--------|
| Hot reads (thousands/sec) | Each local hit saves a round-trip |
| Stable / slowly-changing data | Low invalidation rate, high hit ratio |
| Large serialized values | Saves network and deserialization cost |
| Config / feature flags | Read constantly, changed rarely |

### Keys to Skip (Low Benefit or High Risk)

| Key Type | Reason |
|----------|--------|
| Write-heavy keys | High invalidation rate, poor hit ratio |
| Keys with TTL < 1 second | Expire before the cache benefits |
| High-cardinality volatile keys | Pollutes tracking table, causes eviction |
| Locks or coordination keys | Correctness requires real-time state, never cache |

### Testing Correctness

- Modify a tracked key from a second connection and verify the first connection evicts it.
- Kill and reconnect the data connection - local cache should be cleared on reconnect.
- Fill the tracking table past `tracking-table-max-keys` and verify graceful handling of spurious invalidations.

---

## Valkey Version Notes

Valkey 8.0 through 9.0 make no changes to CLIENT TRACKING semantics, protocol, or configuration relative to Redis 7. RESP3 push, RESP2 redirect, BCAST, OPTIN, and OPTOUT all behave identically.

The `__redis__:invalidate` channel name is preserved - Valkey does not rename it.

GLIDE built-in caching (CacheConfig) was introduced in GLIDE 2.x. Client libraries built for Redis work without changes - the tracking protocol is unchanged.

---
