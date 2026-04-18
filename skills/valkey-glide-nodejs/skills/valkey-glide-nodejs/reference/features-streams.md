# Streams (Node.js)

Use when working with Valkey streams. Command names match Valkey's XADD/XREAD/consumer-group set and are similar to ioredis - the divergence is in argument shape (tuple lists, typed range bounds, option objects) and a couple of API-split choices.

## Divergence from ioredis

| ioredis | GLIDE |
|---------|-------|
| `r.xadd(key, "*", "f", "v")` (flat varargs) | `client.xadd(key, [["f", "v"]])` (array of `[field, value]` tuples) |
| `r.xadd(key, "MAXLEN", "~", 1000, "*", ...)` | `client.xadd(key, entries, { trim: { method: "maxlen", threshold: 1000, exact: false, limit? } })` |
| `start="-"`, `end="+"` sentinel strings | `InfBoundary.NegativeInfinity` / `InfBoundary.PositiveInfinity`, or `{ value: "1-0", isInclusive?: false }` bounds |
| `r.xread("COUNT", 10, "BLOCK", 5000, "STREAMS", "s1", "s2", "0-0", "0-0")` | `client.xread({ s1: "0-0", s2: "0-0" }, { count: 10, block: 5000 })` |
| `r.xgroup("CREATE", key, group, id, "MKSTREAM")` | `client.xgroupCreate(key, group, id, { mkStream: true, entriesRead? })` |
| `r.xclaim(..., "JUSTID")` flag | Separate methods: `xclaim` vs `xclaimJustId`, `xautoclaim` vs `xautoclaimJustId` |
| `r.xpending(key, group)` / `r.xpending(key, group, "-", "+", 10)` | Two methods: `xpending(key, group)` (summary) vs `xpendingWithOptions(key, group, { start, end, count, consumer?, minIdleTime? })` |
| `r.xreadgroup(..., "NOACK")` flag | `client.xreadgroup(group, consumer, { stream: ">" }, { count?, block?, noAck?: true })` |
| `decode_responses`-like bytes-vs-str control | `Decoder.String` default; switch to `Decoder.Bytes` globally via `defaultDecoder` or per-command |
| Cluster multi-stream read: manual slot split | Multi-key `xread` / `xreadgroup` must hash to one slot; use hash tags |

## Key GLIDE types

- `InfBoundary.NegativeInfinity`, `InfBoundary.PositiveInfinity` - replace `"-"` / `"+"`
- `{ value: "1-0" }` - inclusive bound
- `{ value: "1-0", isInclusive: false }` - exclusive bound (Valkey 6.2+)
- Trim option: `{ method: "maxlen" | "minid", threshold, exact, limit? }`

## Split xclaim / xautoclaim

`xclaim` returns `{ "1-0": [[field, value], ...] }`; `xclaimJustId` returns `string[]` of IDs only. Same split for `xautoclaim` / `xautoclaimJustId`. Matches Python's split; replaces ioredis's `JUSTID` flag.

`xautoclaim*` (Valkey 6.2+) returns `[nextStart, entriesOrIds, deletedIds?]` (deletedIds populated on 7.0+).

## Split xpending / xpendingWithOptions

`xpending(key, group)` returns the summary tuple `[count, minId, maxId, [[consumer, count], ...]]`.
`xpendingWithOptions(key, group, { start, end, count, consumer?, minIdleTime? })` returns per-entry detail `[[entryId, consumer, idleMs, deliveryCount], ...]`.

Replaces ioredis's overloaded `r.xpending(...)` where argument count determined summary vs detail.

## Cluster: multi-stream reads must share a slot

`xread` / `xreadgroup` over multiple stream keys goes to a single node - all keys must hash to the same slot. Use hash tags:

```typescript
await client.xadd("{app}.events", [["type", "click"]]);
await client.xadd("{app}.logs",   [["level", "info"]]);
await client.xread({ "{app}.events": "0-0", "{app}.logs": "0-0" });
```

## Blocking reads need a dedicated client

`xread` / `xreadgroup` with `block` occupies the multiplexed connection for the block duration. Use a dedicated client so other coroutines are not stalled. Same rule as `BLPOP` etc. - see [performance](best-practices-performance.md).
