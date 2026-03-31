# Streams

Use when you need durable, ordered message processing with consumer groups, message acknowledgment, and replay capability. For ephemeral real-time broadcasting, see [Pub/Sub](pubsub.md) instead.

## Adding Entries

```python
from glide import StreamAddOptions, TrimByMaxLen

# Auto-generated ID
entry_id = await client.xadd("mystream", [("sensor", "temperature"), ("value", "22.5")])
# entry_id: b"1615957011958-0"

# Explicit ID
entry_id = await client.xadd(
    "mystream",
    [("field", "value")],
    StreamAddOptions(id="0-1"),
)

# Don't create stream if it doesn't exist
entry_id = await client.xadd(
    "mystream",
    [("field", "value")],
    StreamAddOptions(make_stream=False),
)
# Returns None if stream doesn't exist

# Add with trimming
entry_id = await client.xadd(
    "mystream",
    [("field", "value")],
    StreamAddOptions(trim=TrimByMaxLen(exact=False, threshold=1000, limit=100)),
)
```

## Trimming

```python
from glide import TrimByMaxLen, TrimByMinId

deleted = await client.xtrim("mystream", TrimByMaxLen(exact=False, threshold=1000))
deleted = await client.xtrim("mystream", TrimByMinId(exact=True, threshold="1526985054069-0"))
```

## Reading Entries

### Range Queries

```python
from glide import MinId, MaxId, IdBound, ExclusiveIdBound

entries = await client.xrange("mystream", MinId(), MaxId())
# {b"0-1": [[b"field1", b"value1"]], b"0-2": [[b"field2", b"value2"]]}

entries = await client.xrange("mystream", MinId(), MaxId(), count=10)
entries = await client.xrange("mystream", IdBound("1526985054069-0"), MaxId())
entries = await client.xrange("mystream", ExclusiveIdBound("1526985054069-0"), MaxId())
entries = await client.xrevrange("mystream", MaxId(), MinId(), count=5)
```

### XREAD - Multi-Stream Reading

```python
from glide import StreamReadOptions

entries = await client.xread({"stream1": "0-0", "stream2": "0-0"})
# {b"stream1": {b"1-0": [[b"f", b"v"]]}, ...}

# Blocking read with timeout (returns None on timeout)
entries = await client.xread(
    {"mystream": "$"}, StreamReadOptions(block_ms=5000, count=10),
)
```

## Consumer Groups

### Create Group

```python
from glide import StreamGroupOptions

await client.xgroup_create("mystream", "mygroup", "$")       # from latest
await client.xgroup_create("mystream", "mygroup", "0-0")     # from beginning
await client.xgroup_create(                                   # auto-create stream
    "mystream", "mygroup", "$", StreamGroupOptions(make_stream=True),
)
```

### Read with Consumer Group

```python
from glide import StreamReadGroupOptions

# Read new messages
entries = await client.xreadgroup(
    {"mystream": ">"}, "mygroup", "consumer-1", StreamReadGroupOptions(count=10),
)
# {b"mystream": {b"1-0": [[b"field1", b"value1"]]}}

# Re-read pending messages (use "0-0" instead of ">")
pending = await client.xreadgroup({"mystream": "0-0"}, "mygroup", "consumer-1")

# Blocking read
entries = await client.xreadgroup(
    {"mystream": ">"}, "mygroup", "consumer-1",
    StreamReadGroupOptions(block_ms=5000, count=10),
)
```

### Acknowledge Messages

```python
acked = await client.xack("mystream", "mygroup", ["1615957011958-0", "1615957011959-0"])
# acked: 2
```

### Pending Messages

```python
# Summary of pending messages
summary = await client.xpending("mystream", "mygroup")
# [4, b"1-0", b"1-3", [[b"consumer-1", b"3"], [b"consumer-2", b"1"]]]

# Detailed pending range
from glide import StreamPendingOptions

pending = await client.xpending_range(
    "mystream", "mygroup",
    MinId(), MaxId(),
    count=10,
    options=StreamPendingOptions(consumer_name="consumer-1"),
)
# [[b"1-0", b"consumer-1", 1234, 1], [b"1-1", b"consumer-1", 1123, 1]]
# Format: [id, consumer, idle_ms, delivery_count]
```

### Claim Messages

```python
from glide import StreamClaimOptions

# Claim messages idle for > 60 seconds
claimed = await client.xclaim(
    "mystream", "mygroup", "consumer-2",
    min_idle_time_ms=60000,
    ids=["1-0", "1-1"],
)
# Returns: {b"1-0": [[b"field", b"value"]], ...}

# Claim and return only IDs
claimed_ids = await client.xclaim_just_id(
    "mystream", "mygroup", "consumer-2",
    min_idle_time_ms=60000,
    ids=["1-0", "1-1"],
)
```

### Auto-Claim (Valkey 6.2+)

```python
result = await client.xautoclaim(
    "mystream", "mygroup", "consumer-2",
    min_idle_time_ms=60000, start="0-0", count=10,
)
# [next_cursor, {b"1-0": [[b"field", b"value"]]}, [b"deleted-id"]]
```

### Auto-Claim IDs Only (Valkey 6.2+)

```python
result = await client.xautoclaim_just_id(
    "mystream", "mygroup", "consumer-2",
    min_idle_time_ms=60000, start="0-0", count=10,
)
# [next_cursor, [b"1-0", b"1-1"], [b"deleted-id"]]
```

## Group Management

```python
# Set group's last-delivered-ID
await client.xgroup_set_id("mystream", "mygroup", "0-0")
await client.xgroup_set_id("mystream", "mygroup", "$", entries_read=100)

# Create a consumer explicitly
await client.xgroup_create_consumer("mystream", "mygroup", "new-consumer")

# Delete a consumer (returns number of pending messages that were owned by the consumer)
pending_count = await client.xgroup_del_consumer("mystream", "mygroup", "old-consumer")

# Destroy the entire group
await client.xgroup_destroy("mystream", "mygroup")
```

## Info, Length, and Deletion

```python
groups = await client.xinfo_groups("mystream")
consumers = await client.xinfo_consumers("mystream", "mygroup")
info = await client.xinfo_stream("mystream")
full_info = await client.xinfo_stream_full("mystream", count=10)

length = await client.xlen("mystream")
deleted = await client.xdel("mystream", ["1-0", "1-1"])
```

## Cluster Mode

In cluster mode, all keys in a multi-stream `xread` or `xreadgroup` call must map to the same hash slot. Use hash tags to colocate streams:

```python
await client.xadd("{app}.events", [("type", "click")])
await client.xadd("{app}.logs", [("level", "info")])

entries = await client.xread({"{app}.events": "0-0", "{app}.logs": "0-0"})
```
