# redis-py to GLIDE: migration patterns

Use when translating redis-py Pub/Sub loops, pipelines, or handling platform-specific migration concerns.

## Pub/Sub: the whole mental model changes

redis-py's pattern is a runtime `p = r.pubsub()` object with a `listen()` generator. GLIDE replaces this with two different approaches.

### Path A - static subscriptions (any GLIDE version)

Subscriptions are part of the client config - declared up front, applied at connect:

```python
from glide import GlideClient, GlideClientConfiguration, NodeAddress, PubSubMsg

def on_message(msg: PubSubMsg, context):
    print(f"[{msg.channel}] {msg.message}")

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    pubsub_subscriptions=GlideClientConfiguration.PubSubSubscriptions(
        channels_and_patterns={
            GlideClientConfiguration.PubSubChannelModes.Exact:   {"channel"},
            GlideClientConfiguration.PubSubChannelModes.Pattern: {"events:*"},
        },
        callback=on_message,
    ),
)
subscriber = await GlideClient.create(config)
```

To skip the callback and poll instead, omit `callback` and use `await subscriber.get_pubsub_message()` (blocking) or `subscriber.try_get_pubsub_message()` (non-blocking, returns `None` when empty). Callback and polling are mutually exclusive on the same client.

**Static subscriptions require RESP3.** Using `protocol=ProtocolVersion.RESP2` raises `ConfigurationError`.

### Path B - dynamic subscriptions (GLIDE 2.3+)

Runtime subscribe / unsubscribe closer to redis-py's shape, with a lazy variant that returns immediately:

```python
await subscriber.subscribe({"channel"}, timeout_ms=5000)       # waits for server ack
await subscriber.subscribe_lazy({"channel"})                    # returns; reconciles async

await subscriber.psubscribe({"events:*"}, timeout_ms=5000)
await subscriber.psubscribe_lazy({"events:*"})

await subscriber.unsubscribe({"channel"})     # or unsubscribe() for all
await subscriber.unsubscribe_lazy()
```

Sharded pub/sub on cluster: `ssubscribe` / `ssubscribe_lazy` / `sunsubscribe` (Valkey 7.0+).

### Key divergences from redis-py's pubsub

- The subscribing client does NOT enter a special mode - GLIDE multiplexes subscriptions alongside regular commands on the same client. A dedicated client is still recommended for high-throughput subscribers to avoid head-of-line effects.
- GLIDE resubscribes automatically on reconnection and topology change via the synchronizer. No manual reconnect handling.
- Inspect desired-vs-actual with `await client.get_subscriptions()`, track sync health via `get_statistics()` keys `subscription_out_of_sync_count` and `subscription_last_sync_timestamp`.

---

## Pipelines and transactions

Same two concepts, one class, different verb on execution:

| redis-py | GLIDE |
|----------|-------|
| `pipe = r.pipeline(transaction=False)` | `pipe = Batch(is_atomic=False)` |
| `tx = r.pipeline(transaction=True)` | `tx = Batch(is_atomic=True)` |
| `pipe.execute()` | `await client.exec(pipe, raise_on_error=...)` - verb is a client method |
| Error behavior implicit per-command | Explicit `raise_on_error=True` raises on first error; `False` puts `RequestError` inline in the result list |
| Cluster: you split by slot manually | `ClusterBatch(is_atomic=False)` splits per-slot automatically |
| WATCH before `pipe.multi()` | WATCH needs a dedicated client (multiplexer leakage); atomic execution returns `None` on WATCH conflict |

Cluster-only option: `ClusterBatchOptions(retry_strategy=BatchRetryStrategy(retry_server_error=..., retry_connection_error=...))`. Only applies to NON-atomic cluster batches.

---

## Migration strategy

GLIDE is not a drop-in. Plan for incremental migration:

1. Install `valkey-glide` alongside `redis-py` - both import, both work.
2. Build a thin adapter interface that covers every `r.*` call your app makes. Implement the redis-py side first (trivial passthrough).
3. Implement the GLIDE side of the adapter command-by-command, starting with the hottest paths.
4. Swap the adapter to GLIDE behind a feature flag per service.
5. Remove `redis-py` only after every call site has been migrated and canaried.

Big-bang migrations fail on divergences - bytes-vs-str tripping code paths, blocking-command exceptions, WATCH semantics. The adapter pattern lets you translate incrementally while keeping the app runnable.

---

## Platform and packaging notes

- **Protobuf pin**: `protobuf>=3.20` required. Conflicts with other packages pinning older protobuf will surface as import errors. Both `valkey-glide` (async) and `valkey-glide-sync` require this.
- **Alpine not supported**: glibc 2.17+ required. Use Debian / Ubuntu / RHEL-based container images.
- **Proxies**: connection setup sends `INFO REPLICATION`, `CLIENT SETINFO`, `CLIENT SETNAME`. Proxies that don't support these break connection.
- **asyncio / anyio / trio**: transparently supported from GLIDE 2.0.1 onward. No special config.
- **sync package**: from GLIDE 2.1, `pip install valkey-glide-sync` and `from glide_sync import GlideClient, ...` for synchronous code paths.
