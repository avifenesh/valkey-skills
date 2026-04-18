# Streams

Use when working with Valkey streams (XADD / XREAD / consumer groups). The command names and semantics are identical to Valkey/redis-py - the divergence is the typed option classes, response bytes, and a couple of API shape choices.

## Divergence from redis-py

| redis-py | GLIDE Python |
|----------|--------------|
| `r.xadd(stream, {"f": "v"}, maxlen=1000, approximate=True)` | `client.xadd(stream, [("f", "v")], StreamAddOptions(trim=TrimByMaxLen(exact=False, threshold=1000)))` |
| kwargs for MAXLEN / MINID trim | typed `TrimByMaxLen(exact, threshold, limit)` / `TrimByMinId(exact, threshold)` |
| `start="-"`, `end="+"` strings | typed `MinId()`, `MaxId()`, `IdBound("1-0")`, `ExclusiveIdBound("1-0")` |
| `block=5000` kwarg on xread | `StreamReadOptions(block_ms=5000, count=10)` |
| `r.xclaim(..., justid=True)` flag | Separate methods: `xclaim` vs `xclaim_just_id`, `xautoclaim` vs `xautoclaim_just_id` |
| `r.xpending(...)` one call covers both summary and detail | `xpending(stream, group)` summary vs `xpending_range(stream, group, min, max, count, options=StreamPendingOptions(...))` |
| `decode_responses=True` returns str | Always bytes: IDs are `b"1-0"`, field names and values are `bytes` |
| Cluster pipelining of multi-stream reads | Multi-key xread / xreadgroup must hash to one slot (use hash tags) |

## Typed option classes (GLIDE-specific)

These replace redis-py's kwargs and string sentinels:

| Class | Replaces |
|-------|----------|
| `StreamAddOptions(id, make_stream, trim)` | xadd kwargs (`id=`, `nomkstream`, `maxlen`, `minid`) |
| `StreamReadOptions(block_ms, count)` | xread kwargs |
| `StreamReadGroupOptions(block_ms, count, no_ack)` | xreadgroup kwargs |
| `StreamGroupOptions(make_stream, entries_read)` | xgroup CREATE kwargs (`mkstream`) |
| `StreamPendingOptions(consumer_name, min_idle_time_ms)` | XPENDING detail filters |
| `StreamClaimOptions(idle_ms, time_ms, retry_count, is_force)` | XCLAIM kwargs |
| `TrimByMaxLen(exact, threshold, limit)`, `TrimByMinId(exact, threshold)` | MAXLEN/MINID trim args |
| `MinId()`, `MaxId()`, `IdBound("1-0")`, `ExclusiveIdBound("1-0")` | `-`, `+`, and `(` prefix strings |

Example using the divergence:

```python
from glide import (
    StreamAddOptions, StreamReadOptions, StreamReadGroupOptions,
    TrimByMaxLen, MinId, MaxId,
)

await client.xadd(
    "mystream",
    [("sensor", "temp"), ("value", "22.5")],
    StreamAddOptions(trim=TrimByMaxLen(exact=False, threshold=1000, limit=100)),
)

entries = await client.xread(
    {"mystream": "$"},
    StreamReadOptions(block_ms=5000, count=10),
)

# Re-read pending owned by this consumer (use "0-0" instead of ">")
pending = await client.xreadgroup(
    {"mystream": "0-0"}, "mygroup", "consumer-1",
    StreamReadGroupOptions(count=10),
)
```

## Split xclaim / xautoclaim

`xclaim` returns the full entries; `xclaim_just_id` returns only IDs. Same split for `xautoclaim` / `xautoclaim_just_id`. redis-py combines these under a `justid=True` flag.

`xautoclaim*` (Valkey 6.2+) returns `[next_cursor, entries_or_ids, deleted_ids]`.

## Cluster: multi-stream reads must share a slot

`xread` / `xreadgroup` over multiple stream keys goes to a single node - the keys must all hash to the same slot. Use hash tags:

```python
await client.xadd("{app}.events", [("type", "click")])
await client.xadd("{app}.logs",   [("level", "info")])
await client.xread({"{app}.events": "0-0", "{app}.logs": "0-0"})
```
