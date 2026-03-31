# Valkey Streams

Use when you need durable, ordered message processing with consumer groups, replay capability, or event sourcing in Node.js/TypeScript. For fire-and-forget messaging, see [Pub/Sub](pubsub.md).

## Contents

- XADD - Adding Entries (line 21)
- XREAD - Reading Without Consumer Groups (line 45)
- XGROUP CREATE (line 58)
- XREADGROUP - Reading With Consumer Groups (line 69)
- XACK - Acknowledging Messages (line 87)
- XLEN, XRANGE, XINFO (line 96)
- Group Management (line 129)
- XPENDING - Inspecting Pending Messages (line 140)
- XCLAIM - Changing Message Ownership (line 165)
- XAUTOCLAIM - Automatic Pending Transfer (6.2+) (line 184)
- Complete Example: Producer/Consumer With Consumer Group (line 205)
- Blocking Commands Warning (line 257)
- Related Features (line 268)

## XADD - Adding Entries

```typescript
import { GlideClient } from "@valkey/valkey-glide";

const id = await client.xadd("mystream", [["sensor", "temp"], ["value", "23.5"]]);
// id: "1234567890123-0"

// Explicit ID
await client.xadd("mystream", [["event", "click"]], { id: "1000-0" });

// With approximate MAXLEN trim
await client.xadd("mystream", [["data", "v"]], {
    trim: { method: "maxlen", threshold: 1000, exact: false },
});

// NOMKSTREAM - returns null if stream does not exist
await client.xadd("mystream", [["k", "v"]], { makeStream: false });
```

**Signature:** `xadd(key, values: [GlideString, GlideString][], options?) => Promise<string | null>`
- `options.id`: explicit entry ID; `options.makeStream`: false for NOMKSTREAM
- `options.trim`: `{ method: "maxlen"|"minid", threshold, exact, limit? }`

## XREAD - Reading Without Consumer Groups

```typescript
const result = await client.xread({ mystream: "0-0" });
// [{ key: "mystream", value: { "1234-0": [["sensor", "temp"], ["value", "23.5"]] } }]

// Multiple streams, count limit, blocking
const result2 = await client.xread({ s1: "0-0", s2: "0-0" }, { count: 10, block: 5000 });
```

**Signature:** `xread(keys_and_ids: Record<string, string>, options?) => Promise<GlideRecord<StreamEntryDataType> | null>`
- `options.count`: max entries per stream; `options.block`: ms to block (0 = indefinite)

## XGROUP CREATE

```typescript
await client.xgroupCreate("mystream", "mygroup", "0");           // from beginning
await client.xgroupCreate("mystream", "mygroup", "$");           // new entries only
await client.xgroupCreate("mystream", "mygroup", "0", { mkStream: true }); // create stream
```

**Signature:** `xgroupCreate(key, groupName, id, options?) => Promise<"OK">`
- `options.mkStream`: create stream if absent; `options.entriesRead`: logical counter (7.0+)

## XREADGROUP - Reading With Consumer Groups

```typescript
// Read new messages
const msgs = await client.xreadgroup("mygroup", "consumer1", { mystream: ">" });
// [{ key: "mystream", value: { "1234-0": [["sensor", "temp"]] } }]

// With count, block, noAck
await client.xreadgroup("mygroup", "c1", { mystream: ">" }, { count: 10, block: 5000, noAck: true });

// Re-read pending messages (use "0" instead of ">")
await client.xreadgroup("mygroup", "c1", { mystream: "0" });
```

**Signature:** `xreadgroup(group, consumer, keys_and_ids, options?) => Promise<...| null>`
- `">"` = only new messages; `"0"` = re-read pending
- `options.noAck`: skip PEL (auto-acknowledge on read)

## XACK - Acknowledging Messages

```typescript
const acked = await client.xack("mystream", "mygroup", ["1234567890123-0"]);
// acked: 1
```

**Signature:** `xack(key, group, ids: string[]) => Promise<number>`

## XLEN, XRANGE, XINFO

```typescript
import { InfBoundary } from "@valkey/valkey-glide";

// Length
const len = await client.xlen("mystream"); // 42

// Forward range - all entries
const entries = await client.xrange("mystream", InfBoundary.NegativeInfinity, InfBoundary.PositiveInfinity);
// { "0-1": [["f", "v"]], "0-2": [["f2", "v2"]] }

// With count limit and specific ID range
await client.xrange("mystream", { value: "1000-0" }, { value: "2000-0" }, { count: 10 });

// Exclusive boundary (Valkey 6.2+)
await client.xrange("mystream", { value: "1000-0", isInclusive: false }, InfBoundary.PositiveInfinity);

// Reverse range
await client.xrevrange("mystream", InfBoundary.PositiveInfinity, InfBoundary.NegativeInfinity);

// Stream info
const info = await client.xinfoStream("mystream");
// { length: 2, "first-entry": [...], "last-entry": [...], groups: 1, ... }

// Verbose with PEL
await client.xinfoStream("mystream", { fullOptions: true });

// Group and consumer info
const groups = await client.xinfoGroups("mystream");
const consumers = await client.xinfoConsumers("mystream", "mygroup");
```

## Group Management

```typescript
await client.xgroupCreateConsumer("mystream", "mygroup", "c1");   // true
await client.xgroupDelConsumer("mystream", "mygroup", "c1");      // pending count
await client.xgroupDestroy("mystream", "mygroup");                // true
await client.xgroupSetId("mystream", "mygroup", "0");             // "OK"
await client.xdel("mystream", ["1234-0", "1234-1"]);             // deleted count
await client.xtrim("mystream", { method: "maxlen", threshold: 1000, exact: false }); // trimmed count
```

## XPENDING - Inspecting Pending Messages

```typescript
// Summary: total pending, min/max ID, per-consumer counts
const summary = await client.xpending("mystream", "mygroup");
// [42, "1722643465939-0", "1722643484626-0", [["consumer1", 10], ["consumer2", 32]]]

// Detailed: filter by range, count, and optionally consumer
import { InfBoundary } from "@valkey/valkey-glide";

const detailed = await client.xpendingWithOptions("mystream", "mygroup", {
    start: InfBoundary.NegativeInfinity,
    end: InfBoundary.PositiveInfinity,
    count: 10,
    consumer: "consumer1",       // optional filter
    minIdleTime: 60000,          // optional, ms idle threshold (6.2+)
});
// [["1722643465939-0", "consumer1", 174431, 1], ...]
// Each tuple: [entryId, consumer, idleTimeMs, deliveryCount]
```

**Signatures:**
- `xpending(key, group) => Promise<[number, GlideString, GlideString, [GlideString, number][]]>`
- `xpendingWithOptions(key, group, options: StreamPendingOptions) => Promise<[GlideString, GlideString, number, number][]>`

## XCLAIM - Changing Message Ownership

```typescript
// Claim entries idle for at least 60000ms, reassign to "consumer2"
const claimed = await client.xclaim("mystream", "mygroup", "consumer2", 60000,
    ["1-0", "2-0"], { idle: 500, retryCount: 3, isForce: true });
// { "2-0": [["field", "value"]] }

// JUSTID variant - returns only IDs, no entry data
const ids = await client.xclaimJustId("mystream", "mygroup", "consumer2", 60000,
    ["1-0", "2-0"]);
// ["2-0"]
```

**Signatures:**
- `xclaim(key, group, consumer, minIdleTime, ids, options?) => Promise<StreamEntryDataType>`
- `xclaimJustId(key, group, consumer, minIdleTime, ids, options?) => Promise<string[]>`
- `options`: `{ idle?, idleUnixTime?, retryCount?, isForce? }`

## XAUTOCLAIM - Automatic Pending Transfer (6.2+)

```typescript
// Automatically claim entries idle > 60000ms, scanning from "0-0"
const [nextStart, entries, deleted] = await client.xautoclaim(
    "mystream", "mygroup", "consumer2", 60000, "0-0", { count: 25 });
// nextStart: "1609338788321-0" (use as start for next call)
// entries: { "1609338752495-0": [["field", "value"]] }
// deleted: ["1594324506465-0"] (IDs no longer in stream, 7.0+ only)

// JUSTID variant - returns only IDs
const [nextId, claimedIds, deletedIds] = await client.xautoclaimJustId(
    "mystream", "mygroup", "consumer2", 60000, "0-0", { count: 25 });
// claimedIds: ["1609338752495-0", "1609338752495-1"]
```

**Signatures:**
- `xautoclaim(key, group, consumer, minIdleTime, start, options?) => Promise<[GlideString, StreamEntryDataType, GlideString[]?]>`
- `xautoclaimJustId(key, group, consumer, minIdleTime, start, options?) => Promise<[string, string[], string[]?]>`
- `options`: `{ count?: number }` (default 100)

## Complete Example: Producer/Consumer With Consumer Group

```typescript
import { GlideClient } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({ addresses: [{ host: "localhost", port: 6379 }] });
const STREAM = "orders";
const GROUP = "order-processors";

// Setup
await client.xgroupCreate(STREAM, GROUP, "0", { mkStream: true });

// Producer
async function produce() {
    for (let i = 0; i < 5; i++) {
        const id = await client.xadd(STREAM, [
            ["order_id", `ORD-${i}`],
            ["item", `widget-${i}`],
            ["qty", String(i + 1)],
        ]);
        console.log(`Produced: ${id}`);
    }
}

// Consumer - each entry delivered to exactly one consumer in the group
async function consume(name: string) {
    while (true) {
        const result = await client.xreadgroup(GROUP, name, { [STREAM]: ">" }, { count: 2, block: 5000 });
        if (!result) continue;

        for (const stream of result) {
            for (const [entryId, fields] of Object.entries(stream.value)) {
                if (!fields) continue;
                console.log(`[${name}] Processing ${entryId}:`, fields);
                await client.xack(STREAM, GROUP, [entryId]);
            }
        }
    }
}

await produce();
await Promise.all([consume("worker-1"), consume("worker-2")]);

// Inspect
console.log(`Length: ${await client.xlen(STREAM)}`);
console.log("Groups:", await client.xinfoGroups(STREAM));

// Cleanup
await client.xgroupDestroy(STREAM, GROUP);
client.close();
```

## Blocking Commands Warning

`xread` and `xreadgroup` with `block` hold the multiplexed connection. Use a dedicated client for blocking reads so other commands are not stalled.

```typescript
const blockingClient = await GlideClient.createClient(config);
const commandClient = await GlideClient.createClient(config);
await blockingClient.xreadgroup(GROUP, "c1", { [STREAM]: ">" }, { block: 5000 });
await commandClient.set("key", "value"); // unaffected
```

## Related Features

- [Pub/Sub](pubsub.md) - fire-and-forget broadcast without durability
- [Batching](batching.md) - stream commands work in Batch and ClusterBatch
- [Scripting](scripting.md) - Lua scripts can call stream commands atomically
