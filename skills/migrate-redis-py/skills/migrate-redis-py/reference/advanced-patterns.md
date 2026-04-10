# redis-py to GLIDE Advanced Patterns

Use when migrating redis-py Pub/Sub, pipelines, transactions, or handling platform-specific deployment concerns.

## Contents

- Pub/Sub (line 12)
- Pipelines and Transactions (line 75)
- Platform Notes (line 109)

---

## Pub/Sub

**redis-py:**
```python
p = r.pubsub()
p.subscribe("channel")
p.psubscribe("events:*")
for message in p.listen():
    print(message["data"])
```

**GLIDE (static subscriptions - at client creation):**
```python
from glide import GlideClientConfiguration, NodeAddress, PubSubMsg

def on_message(msg: PubSubMsg, context):
    print(f"[{msg.channel}] {msg.message} (pattern={msg.pattern})")

config = GlideClientConfiguration(
    addresses=[NodeAddress("localhost", 6379)],
    pubsub_subscriptions=GlideClientConfiguration.PubSubSubscriptions(
        channels_and_patterns={
            GlideClientConfiguration.PubSubChannelModes.Exact: {"channel"},
            GlideClientConfiguration.PubSubChannelModes.Pattern: {"events:*"},
        },
        callback=on_message,
    ),
)
subscriber = await GlideClient.create(config)
```

**GLIDE (dynamic subscriptions - GLIDE 2.3+):**
```python
subscriber = await GlideClient.create(config)

# Blocking - waits for server confirmation
await subscriber.subscribe({"channel"}, timeout_ms=5000)
await subscriber.psubscribe({"events:*"}, timeout_ms=5000)

# Non-blocking - returns immediately, reconciliation happens async
await subscriber.subscribe_lazy({"channel"})
await subscriber.psubscribe_lazy({"events:*"})

# Receive messages via polling
msg = await subscriber.get_pubsub_message()       # async, blocks until message
msg = subscriber.try_get_pubsub_message()          # non-blocking, returns None if empty

# Unsubscribe
await subscriber.unsubscribe({"channel"})
await subscriber.punsubscribe({"events:*"})
await subscriber.unsubscribe()                     # all exact channels
```

GLIDE automatically resubscribes on reconnection. Use a dedicated client for subscriptions - a subscribing client enters a special mode where most regular commands are unavailable. Callback and polling modes are mutually exclusive on the same client.

---

## Pipelines and Transactions

**redis-py:**
```python
# Pipeline
pipe = r.pipeline(transaction=False)
pipe.set("k1", "v1")
pipe.set("k2", "v2")
pipe.get("k1")
results = pipe.execute()

# Transaction
tx = r.pipeline(transaction=True)
tx.set("k1", "v1")
tx.get("k1")
results = tx.execute()
```

**GLIDE:**
```python
from glide import Batch

# Pipeline (non-atomic)
pipe = Batch(is_atomic=False)
pipe.set("k1", "v1")
pipe.set("k2", "v2")
pipe.get("k1")
results = await client.exec(pipe, raise_on_error=False)

# Transaction (atomic)
tx = Batch(is_atomic=True)
tx.set("k1", "v1")
tx.get("k1")
results = await client.exec(tx, raise_on_error=True)
```

---

## Platform Notes

### Protobuf Dependency Conflict

The async package requires `protobuf>=3.20`, which can conflict with other packages (gRPC stubs, etc.). The sync package (`valkey-glide-sync`) also requires `>=3.20` but has fewer transitive conflicts. Pin protobuf versions carefully.

### Alpine Linux Not Supported

GLIDE Python requires glibc 2.17+ - MUSL-based distributions like Alpine are not supported. Use Debian-based container images instead.

### Proxy Incompatibility

GLIDE runs `INFO REPLICATION`, `CLIENT SETINFO`, and `CLIENT SETNAME` during connection setup. Proxies like Envoy that do not support these commands will fail at connect time.

### Trio and anyio Support

GLIDE transparently supports asyncio, anyio, and trio as of GLIDE 2.0.1. No special configuration needed.
