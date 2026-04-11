# Valkey Streams

Use when you need durable, ordered message processing with consumer groups, replay capability, or event sourcing in Go. For fire-and-forget broadcast messaging, see [Pub/Sub](features-pubsub.md). Stream commands can be included in [batches](features-batching.md).

Packages: `github.com/valkey-io/valkey-glide/go/v2/options`, `github.com/valkey-io/valkey-glide/go/v2/models`.

## Contents

- Adding Entries (line 21)
- Reading Entries (line 49)
- Range Queries (line 73)
- Consumer Groups (line 87)
- Pending Entries (line 126)
- Claiming Entries (line 143)
- Group Management (line 172)
- Stream Metadata (line 184)
- Introspection (line 207)
- Blocking Commands (line 219)
- Cluster Mode (line 223)

## Adding Entries

```go
// Auto-generated ID
entryId, err := client.XAdd(ctx, "mystream", []models.FieldValue{
    {Field: "sensor", Value: "temp"},
    {Field: "value", Value: "23.5"},
})
// entryId: "1234567890123-0"

// With options: custom ID, trim, don't create stream
opts := options.NewXAddOptions().
    SetId("1234567890123-1").
    SetTrimOptions(options.NewXTrimOptionsWithMaxLen(1000).SetNearlyExactTrimming())

result, err := client.XAddWithOptions(ctx, "mystream",
    []models.FieldValue{{Field: "data", Value: "value"}}, *opts)
// result is Result[string] - check result.IsNil() if SetDontMakeNewStream was used
```

### XAddOptions

| Method | Description |
|--------|-------------|
| `SetId(id)` | Custom entry ID (default: `*` for auto-generate) |
| `SetDontMakeNewStream()` | Return nil instead of creating stream if key missing |
| `SetTrimOptions(opts)` | Trim on add (MAXLEN or MINID) |

## Reading Entries

```go
// Read from one or more streams (entries after given ID, "0" = from beginning)
entries, err := client.XRead(ctx, map[string]string{"mystream": "0"})

// With options: count and block
opts := options.NewXReadOptions().SetCount(10).SetBlock(5 * time.Second)
entries, err := client.XReadWithOptions(ctx, map[string]string{"mystream": "$"}, *opts)
```

Return type: `map[string]models.StreamResponse`

```go
for streamName, response := range entries {
    for _, entry := range response.Entries {
        fmt.Printf("Stream: %s, ID: %s\n", streamName, entry.ID)
        for _, fv := range entry.Fields {
            fmt.Printf("  %s = %s\n", fv.Field, fv.Value)
        }
    }
}
```

## Range Queries

```go
start := options.NewInfiniteStreamBoundary(constants.NegativeInfinity) // "-"
end := options.NewInfiniteStreamBoundary(constants.PositiveInfinity)   // "+"
entries, err := client.XRange(ctx, "mystream", start, end)

rangeOpts := options.NewXRangeOptions().SetCount(100)
entries, err := client.XRangeWithOptions(ctx, "mystream", start, end, *rangeOpts)
entries, err = client.XRevRange(ctx, "mystream", end, start) // newest to oldest

// Boundaries: NewStreamBoundary(id, inclusive bool), NewInfiniteStreamBoundary(bound)
```

## Consumer Groups

### Create Group

```go
// From beginning
_, err := client.XGroupCreate(ctx, "mystream", "mygroup", "0")

// From new entries only
_, err = client.XGroupCreate(ctx, "mystream", "mygroup", "$")

// Create stream if it doesn't exist
opts := options.NewXGroupCreateOptions().SetMakeStream()
_, err = client.XGroupCreateWithOptions(ctx, "mystream", "mygroup", "0", *opts)
```

### Read as Consumer

```go
// Read new entries (use ">" for undelivered entries)
messages, err := client.XReadGroup(ctx, "mygroup", "consumer1",
    map[string]string{"mystream": ">"})

// With options: count, block, noack
opts := options.NewXReadGroupOptions().
    SetCount(10).
    SetBlock(5 * time.Second).
    SetNoAck()  // skip PEL, auto-acknowledge on read
messages, err = client.XReadGroupWithOptions(ctx, "mygroup", "consumer1",
    map[string]string{"mystream": ">"}, *opts)
```

### Acknowledge

```go
ackCount, err := client.XAck(ctx, "mystream", "mygroup",
    []string{"1234567890123-0", "1234567890124-0"})
```

## Pending Entries

```go
// Summary: total pending, ID range, per-consumer counts
summary, err := client.XPending(ctx, "mystream", "mygroup")
// summary.NumOfMessages, summary.StartId, summary.EndId, summary.ConsumerMessages

// Detailed: filter by range, count, consumer, idle time
opts := options.NewXPendingOptions("-", "+", 10).
    SetConsumer("consumer1").
    SetMinIdleTime(60000)
details, err := client.XPendingWithOptions(ctx, "mystream", "mygroup", *opts)
// Each detail: .Id, .ConsumerName, .IdleTime, .DeliveryCount
```

XPendingSummary fields: `NumOfMessages` (int64), `StartId` / `EndId` (Result[string]), `ConsumerMessages` ([]ConsumerPendingMessage).

## Claiming Entries

```go
// XClaim: transfer specific entries
claimed, err := client.XClaim(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, []string{"1234567890123-0"})

// XClaim with options
opts := options.NewXClaimOptions().SetIdleTime(10000).SetRetryCount(3).SetForce()
claimed, err = client.XClaimWithOptions(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, []string{"1234567890123-0"}, *opts)

// XAutoClaim: auto-claim idle entries (returns NextEntry cursor, ClaimedEntries, DeletedMessages)
result, err := client.XAutoClaim(ctx, "mystream", "mygroup", "consumer2", 60*time.Second, "0")
autoOpts := options.NewXAutoClaimOptions().SetCount(50)
result, err = client.XAutoClaimWithOptions(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, "0", *autoOpts)

// Just IDs variants (return only entry IDs, not full entries)
ids, err := client.XClaimJustId(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, []string{"1234567890123-0"})
ids, err = client.XClaimJustIdWithOptions(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, []string{"1234567890123-0"}, *opts)
justIdResult, err := client.XAutoClaimJustId(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, "0")
justIdResult, err = client.XAutoClaimJustIdWithOptions(ctx, "mystream", "mygroup", "consumer2",
    60*time.Second, "0", *autoOpts)
```

## Group Management

```go
created, err := client.XGroupCreateConsumer(ctx, "mystream", "mygroup", "consumer1")
pending, err := client.XGroupDelConsumer(ctx, "mystream", "mygroup", "consumer1")
destroyed, err := client.XGroupDestroy(ctx, "mystream", "mygroup")
_, err = client.XGroupSetId(ctx, "mystream", "mygroup", "0")
// XGroupSetIdWithOptions accepts XGroupSetIdOptions for the entriesRead parameter
setIdOpts := options.NewXGroupSetIdOptionsOptions().SetEntriesRead(100)
_, err = client.XGroupSetIdWithOptions(ctx, "mystream", "mygroup", "0", *setIdOpts)
```

## Stream Metadata

```go
// Length
length, err := client.XLen(ctx, "mystream")

// Delete entries
deletedCount, err := client.XDel(ctx, "mystream", []string{"1234567890123-0"})

// Trim
trimOpts := options.NewXTrimOptionsWithMaxLen(1000).SetNearlyExactTrimming()
trimmed, err := client.XTrim(ctx, "mystream", *trimOpts)
```

### Trim Options

| Constructor | Strategy |
|-------------|----------|
| `NewXTrimOptionsWithMaxLen(n)` | Trim to at most N entries |
| `NewXTrimOptionsWithMinId(id)` | Trim entries with IDs less than threshold |

Both support `.SetExactTrimming()`, `.SetNearlyExactTrimming()`, and `.SetNearlyExactTrimmingAndLimit(limit)`.

## Introspection

```go
info, err := client.XInfoStream(ctx, "mystream")       // .Length, .RadixTreeKeys, etc.
groups, err := client.XInfoGroups(ctx, "mystream")      // .Name, .Consumers, .Pending
consumers, err := client.XInfoConsumers(ctx, "mystream", "mygroup") // .Name, .Pending, .IdleTime

// Full info with PEL details
fullOpts := options.NewXInfoStreamOptions().SetCount(10)
fullInfo, err := client.XInfoStreamFullWithOptions(ctx, "mystream", *fullOpts)
```

## Blocking Commands

XREAD/XREADGROUP with `SetBlock()` block the multiplexed connection. Create a dedicated client for blocking reads - use a separate client for regular commands.

## Cluster Mode

Stream keys route by hash slot. Consumer groups reside on the same node as the stream. For multi-stream `XRead`/`XReadGroup`, GLIDE splits across nodes if streams map to different slots.
