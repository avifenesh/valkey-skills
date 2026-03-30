# Valkey Streams

Use when you need durable, ordered message processing with consumer groups, replay capability, or event sourcing. For fire-and-forget broadcast messaging, see [Pub/Sub](pubsub.md) instead. Stream commands can be included in [batches](batching.md) for pipelined or transactional usage.

GLIDE supports the full Valkey Streams API for append-only log data structures with consumer groups, range queries, and introspection commands.

## Supported Stream Commands

All stream commands from the Rust core `request_type.rs`:

| Command | RequestType | Description |
|---------|-------------|-------------|
| XADD | `XAdd` | Append entry to a stream |
| XDEL | `XDel` | Delete entries by ID |
| XTRIM | `XTrim` | Trim stream to a maximum length or minimum ID |
| XLEN | `XLen` | Get the number of entries in a stream |
| XRANGE | `XRange` | Get entries in a forward ID range |
| XREVRANGE | `XRevRange` | Get entries in a reverse ID range |
| XREAD | `XRead` | Read entries from one or more streams |
| XGROUP CREATE | `XGroupCreate` | Create a consumer group |
| XGROUP CREATECONSUMER | `XGroupCreateConsumer` | Create a consumer in a group |
| XGROUP DELCONSUMER | `XGroupDelConsumer` | Delete a consumer from a group |
| XGROUP DESTROY | `XGroupDestroy` | Destroy a consumer group |
| XGROUP SETID | `XGroupSetId` | Set the last-delivered ID for a group |
| XREADGROUP | `XReadGroup` | Read entries as a consumer in a group |
| XACK | `XAck` | Acknowledge processed entries |
| XPENDING | `XPending` | Inspect pending entries for a group |
| XINFO STREAM | `XInfoStream` | Get stream metadata |
| XINFO GROUPS | `XInfoGroups` | Get consumer group info |
| XINFO CONSUMERS | `XInfoConsumers` | Get consumer info within a group |
| XCLAIM | `XClaim` | Transfer ownership of pending entries |
| XAUTOCLAIM | `XAutoClaim` | Automatically claim idle pending entries |

## Basic Operations (Python)

### Adding Entries

```python
# Add an entry with auto-generated ID
entry_id = await client.xadd("mystream", {"sensor": "temp", "value": "23.5"})
# entry_id: b'1234567890123-0'

# Add with trimming
from glide import TrimByMaxLen
entry_id = await client.xadd(
    "mystream",
    {"data": "value"},
    options=TrimByMaxLen(exact=False, threshold=1000),
)
```

### Reading Entries

```python
# Read from one or more streams (entries after the given ID)
entries = await client.xread({"mystream": "0"})
# {b'mystream': {b'1234567890123-0': {b'sensor': b'temp', b'value': b'23.5'}}}

# Read with options (block, count)
from glide import StreamReadOptions
entries = await client.xread(
    {"mystream": "0"},
    options=StreamReadOptions(count=10, block_ms=5000),
)
```

### Range Queries

```python
# Forward range (oldest to newest)
entries = await client.xrange("mystream", start="-", end="+")

# With count limit
entries = await client.xrange("mystream", start="-", end="+", count=100)

# Reverse range (newest to oldest)
entries = await client.xrevrange("mystream", end="+", start="-")
```

### Stream Metadata

```python
# Get stream length
length = await client.xlen("mystream")

# Get stream info
info = await client.xinfo_stream("mystream")

# Delete entries
deleted_count = await client.xdel("mystream", ["1234567890123-0"])

# Trim stream
trimmed = await client.xtrim("mystream", TrimByMaxLen(exact=True, threshold=1000))
```

## Consumer Groups (Python)

Consumer groups allow multiple consumers to cooperatively process stream entries, with each entry delivered to exactly one consumer in the group.

### Creating Groups

```python
# Create a group starting from the beginning
await client.xgroup_create("mystream", "mygroup", "0")

# Create starting from new entries only
await client.xgroup_create("mystream", "mygroup", "$")

# Create with MKSTREAM (create stream if it does not exist)
await client.xgroup_create("mystream", "mygroup", "0", mkstream=True)
```

### Reading as a Consumer

```python
# Read new entries for this consumer
messages = await client.xreadgroup("mygroup", "consumer1", {"mystream": ">"})
# {b'mystream': {b'1234567890123-0': {b'sensor': b'temp', b'value': b'23.5'}}}

# Read with options
from glide import StreamReadGroupOptions
messages = await client.xreadgroup(
    "mygroup",
    "consumer1",
    {"mystream": ">"},
    options=StreamReadGroupOptions(count=10, block_ms=5000),
)
```

### Acknowledging Entries

```python
# Acknowledge processed entries
ack_count = await client.xack("mystream", "mygroup", ["1234567890123-0"])
# ack_count: 1
```

### Pending Entry Inspection

```python
# Get pending summary for a group
pending = await client.xpending("mystream", "mygroup")
# [num_pending, smallest_id, greatest_id, [[consumer_name, num_pending], ...]]

# Get detailed pending entries with range
from glide import StreamPendingOptions
pending_detail = await client.xpending_range(
    "mystream",
    "mygroup",
    start="-",
    end="+",
    count=10,
    options=StreamPendingOptions(min_idle_time_ms=60000),
)
```

### Claiming Entries

```python
# Claim idle entries from another consumer
from glide import StreamClaimOptions

claimed = await client.xclaim(
    "mystream",
    "mygroup",
    "consumer2",
    min_idle_time_ms=60000,
    ids=["1234567890123-0"],
)

# Auto-claim idle entries (Valkey 6.2+)
result = await client.xautoclaim(
    "mystream",
    "mygroup",
    "consumer2",
    min_idle_time_ms=60000,
    start="0",
)
```

### Group Management

```python
# Create a consumer explicitly
created = await client.xgroup_create_consumer("mystream", "mygroup", "consumer1")

# Delete a consumer (returns pending count for that consumer)
pending = await client.xgroup_del_consumer("mystream", "mygroup", "consumer1")

# Destroy a group entirely
destroyed = await client.xgroup_destroy("mystream", "mygroup")

# Set the last-delivered ID for a group
await client.xgroup_set_id("mystream", "mygroup", "0")
```

## Introspection

```python
# Stream info
info = await client.xinfo_stream("mystream")
# Returns: stream length, radix-tree info, first/last entry, etc.

# Consumer group info
groups = await client.xinfo_groups("mystream")
# Returns: list of groups with name, consumers, pending, last-delivered-id

# Consumer info within a group
consumers = await client.xinfo_consumers("mystream", "mygroup")
# Returns: list of consumers with name, pending count, idle time
```

## Trim Options

Two trimming strategies are available via Python classes in `glide_shared.commands.stream`:

| Class | Strategy | Description |
|-------|----------|-------------|
| `TrimByMaxLen` | MAXLEN | Trim to at most N entries |
| `TrimByMinId` | MINID | Trim entries with IDs less than the threshold |

Both support exact and approximate (near-exact) trimming. Approximate trimming is more efficient:

```python
from glide import TrimByMaxLen, TrimByMinId

# Approximate MAXLEN trim (more efficient)
TrimByMaxLen(exact=False, threshold=1000)

# Exact MINID trim
TrimByMinId(exact=True, threshold="1234567890000-0")

# With limit on entries trimmed (only with approximate)
TrimByMaxLen(exact=False, threshold=1000, limit=100)
```

Note: If `exact` is set to `True`, `limit` cannot be specified - this raises `ValueError`.

## Stream Range Boundaries

The `StreamRangeBound` classes control range query boundaries:

- `MinId` / `MaxId` - special `-` and `+` bounds for minimum/maximum IDs
- `IdBound` - inclusive bound at a specific ID
- `ExclusiveIdBound` - exclusive bound at a specific ID

## Read Options

### StreamReadOptions

Used with `xread`:
- `count` (int) - maximum number of entries per stream
- `block_ms` (int) - block for N milliseconds waiting for new entries

### StreamReadGroupOptions

Used with `xreadgroup`:
- `count` (int) - maximum number of entries per stream
- `block_ms` (int) - block for N milliseconds waiting for new entries
- `noack` (bool) - skip adding entries to the PEL (pending entries list)

### StreamClaimOptions

Used with `xclaim`:
- `idle_ms` (int) - set the idle time of the claimed entry
- `idle_unix_time_ms` (int) - set idle time to a specific Unix timestamp
- `retry_count` (int) - set the retry counter
- `is_force` (bool) - force claim even if entry does not exist in PEL

### StreamPendingOptions

Used with `xpending` range queries:
- `min_idle_time_ms` (int) - filter by minimum idle time
- `consumer` (str) - filter by consumer name

## Batch Support

All stream commands are available in `Batch` and `ClusterBatch` objects for pipelined or transactional usage:

```python
from glide import Batch

batch = Batch(is_atomic=False)
batch.xadd("stream1", {"key": "val1"})
batch.xadd("stream1", {"key": "val2"})
batch.xlen("stream1")
batch.xrange("stream1", start="-", end="+")
result = await client.exec(batch)
```

## Blocking Commands Warning

XREAD and XREADGROUP with `block_ms` are blocking commands. GLIDE recommends creating a separate client instance for blocking commands since they block the multiplexed connection:

> "Blocking commands, such as BLPOP, block the connection until a condition is met. Using a blocking command will prevent all subsequent commands from executing until the block is lifted. Therefore, opening a new client for each blocking command is required to avoid undesired blocking of other commands."

```python
# Dedicated client for blocking stream reads
blocking_client = await GlideClient.create(config)
messages = await blocking_client.xreadgroup(
    "mygroup", "consumer1", {"mystream": ">"},
    options=StreamReadGroupOptions(block_ms=5000),
)

# Separate client for regular commands
command_client = await GlideClient.create(config)
await command_client.set("key", "value")
```

## Exactly-Once Processing

Valkey streams provide at-least-once semantics with consumer groups. Exactly-once can be approximated by:

1. Using `XREADGROUP` with consumer ID for automatic pending entry list (PEL) tracking
2. Processing message and ACKing in application logic
3. Using `XPENDING` + `XCLAIM` for recovering from consumer failures
4. Implementing idempotent consumers using message IDs as deduplication keys

## Cluster Mode

In cluster mode, stream keys are routed by hash slot like any other key. Consumer groups operate per-stream, so the group, its consumers, and the stream itself all reside on the same node.

For multi-stream `xread` or `xreadgroup` calls, GLIDE handles per-slot routing automatically - splitting the request across nodes if the stream keys map to different slots.

## Related Features

- [Pub/Sub](pubsub.md) - fire-and-forget broadcast messaging; use Pub/Sub for real-time notifications where message durability is not required
- [Batching](batching.md) - all stream commands are available in Batch and ClusterBatch for pipelined or transactional usage
- [Scripting](scripting.md) - Lua scripts can call stream commands for atomic read-process-write patterns
