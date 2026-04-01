# Valkey Streams (Java)

Use when working with Valkey Streams in GLIDE Java - adding entries, reading, consumer groups, acknowledging messages, or trimming.

## Contents

- Adding Entries (XADD) (line 23)
- Reading Entries (XREAD) (line 41)
- Consumer Groups (line 72)
- Acknowledging Messages (XACK) (line 140)
- Pending Messages (XPENDING) (line 151)
- Stream Length (XLEN) (line 159)
- Range Queries (XRANGE / XREVRANGE) (line 165)
- Delete Entries (XDEL) (line 187)
- Claiming Messages (XCLAIM / XAUTOCLAIM) (line 193)
- Stream Info (XINFO) (line 219)
- Trimming Streams (XTRIM) (line 238)
- Delete Consumer / Destroy Group (line 251)
- Set Group Last-Delivered ID (line 262)
- Cluster Mode (line 268)
- Full Consumer Group Pattern (line 276)

## Adding Entries (XADD)

```java
// Basic - auto-generated ID
String id = client.xadd("mystream", Map.of("sensor", "temp", "value", "22.5")).get();

// With options - custom ID, conditional stream creation
StreamAddOptions options = StreamAddOptions.builder()
    .id("1-0")
    .makeStream(Boolean.FALSE)  // null if stream doesn't exist
    .build();
String id = client.xadd("mystream", Map.of("sensor", "temp"), options).get();

// Duplicate field names via String[][] overload
String id = client.xadd("mystream",
    new String[][]{{"tag", "a"}, {"tag", "b"}}).get();
```

## Reading Entries (XREAD)

```java
// Read all entries from ID "0-0"
Map<String, Map<String, String[][]>> result =
    client.xread(Map.of("mystream", "0-0")).get();

for (var streamEntry : result.entrySet()) {
    String streamKey = streamEntry.getKey();
    for (var entry : streamEntry.getValue().entrySet()) {
        String entryId = entry.getKey();
        for (String[] fieldValue : entry.getValue()) {
            System.out.println(entryId + " -> " + fieldValue[0] + "=" + fieldValue[1]);
        }
    }
}
```

### Blocking Read

```java
StreamReadOptions options = StreamReadOptions.builder()
    .block(1000L)  // block up to 1 second
    .count(10L)    // return at most 10 entries
    .build();

Map<String, Map<String, String[][]>> result =
    client.xread(Map.of("mystream", "$"), options).get();
// Returns null if timeout expires with no new data
```

## Consumer Groups

### Create a Group

```java
// From beginning of stream
client.xgroupCreate("mystream", "mygroup", "0-0").get();

// From latest entry
client.xgroupCreate("mystream", "mygroup", "$").get();

// Create stream if it doesn't exist
client.xgroupCreate("mystream", "mygroup", "$",
    StreamGroupOptions.builder().makeStream().build()).get();
```

### Create a Consumer

```java
boolean created = client.xgroupCreateConsumer(
    "mystream", "mygroup", "consumer1").get();
```

### Read with Consumer Group (XREADGROUP)

Use `">"` as the ID to receive only new (undelivered) messages:

```java
Map<String, Map<String, String[][]>> result = client.xreadgroup(
    Map.of("mystream", ">"),
    "mygroup",
    "consumer1"
).get();

if (result != null) {
    for (var streamEntry : result.entrySet()) {
        for (var entry : streamEntry.getValue().entrySet()) {
            String entryId = entry.getKey();
            for (String[] fv : entry.getValue()) {
                System.out.println(entryId + ": " + fv[0] + "=" + fv[1]);
            }
        }
    }
}
```

### Read with Options

```java
StreamReadGroupOptions options = StreamReadGroupOptions.builder()
    .count(10L)    // max entries per stream
    .block(5000L)  // block up to 5 seconds
    .noack()       // don't add to pending list
    .build();

Map<String, Map<String, String[][]>> result = client.xreadgroup(
    Map.of("mystream", ">"), "mygroup", "consumer1", options).get();
```

### Re-read Pending Messages

Pass `"0"` instead of `">"` to re-read messages already delivered but not yet acknowledged:

```java
Map<String, Map<String, String[][]>> pending = client.xreadgroup(
    Map.of("mystream", "0"), "mygroup", "consumer1").get();
```

## Acknowledging Messages (XACK)

```java
String entryId = client.xadd("mystream", Map.of("data", "value")).get();

// After processing, acknowledge
Long acked = client.xack("mystream", "mygroup",
    new String[]{entryId}).get();
// acked == 1L
```

## Pending Messages (XPENDING)

```java
// Summary of all pending messages
Object[] summary = client.xpending("mystream", "mygroup").get();
// [totalPending, startId, endId, [[consumer, count], ...]]
```

## Stream Length (XLEN)

```java
Long length = client.xlen("mystream").get();
```

## Range Queries (XRANGE / XREVRANGE)

```java
import glide.api.models.commands.stream.StreamRange.*;

// All entries
Map<String, String[][]> entries = client.xrange("mystream",
    InfRangeBound.MIN, InfRangeBound.MAX).get();

// Bounded range
Map<String, String[][]> entries = client.xrange("mystream",
    IdBound.of("1-0"), IdBound.of("5-0")).get();

// With count limit
Map<String, String[][]> entries = client.xrange("mystream",
    InfRangeBound.MIN, InfRangeBound.MAX, 10L).get();

// Reverse order
Map<String, String[][]> entries = client.xrevrange("mystream",
    InfRangeBound.MAX, InfRangeBound.MIN).get();
```

## Delete Entries (XDEL)

```java
Long deleted = client.xdel("mystream", new String[]{"1-1", "1-2"}).get();
```

## Claiming Messages (XCLAIM / XAUTOCLAIM)

Transfer ownership of pending messages to a different consumer:

```java
// Claim specific entries idle for at least 60 seconds
Map<String, String[][]> claimed = client.xclaim(
    "mystream", "mygroup", "consumer2", 60000L,
    new String[]{entryId}).get();

// Claim returning only IDs (no field data)
String[] claimedIds = client.xclaimJustId(
    "mystream", "mygroup", "consumer2", 60000L,
    new String[]{entryId}).get();

// Auto-claim: scan and claim idle messages in one call (Valkey 6.2+)
Object[] result = client.xautoclaim(
    "mystream", "mygroup", "consumer2", 3_600_000L, "0-0").get();
// result[0] = next start ID for subsequent calls
// result[1] = Map of claimed entry ID -> fields
// result[2] = array of deleted entry IDs (Valkey 7.0+)

Object[] justIds = client.xautoclaimJustId(
    "mystream", "mygroup", "consumer2", 3_600_000L, "0-0").get();
```

## Stream Info (XINFO)

```java
// Stream overview
Map<String, Object> info = client.xinfoStream("mystream").get();
// Keys: length, radix-tree-keys, radix-tree-nodes, last-generated-id, ...

// Full stream info including entries and groups
Map<String, Object> full = client.xinfoStreamFull("mystream").get();
Map<String, Object> fullLimited = client.xinfoStreamFull("mystream", 10).get();

// Group info
Map<String, Object>[] groups = client.xinfoGroups("mystream").get();

// Consumer info within a group
Map<String, Object>[] consumers = client.xinfoConsumers(
    "mystream", "mygroup").get();
```

## Trimming Streams (XTRIM)

```java
import glide.api.models.commands.stream.StreamTrimOptions.MaxLen;
import glide.api.models.commands.stream.StreamTrimOptions.MinId;

// Trim to approximately 1000 entries (nearly exact)
Long trimmed = client.xtrim("mystream", new MaxLen(false, 1000L)).get();

// Exact trim by minimum ID
Long trimmed = client.xtrim("mystream", new MinId(true, "0-3")).get();
```

## Delete Consumer / Destroy Group

```java
// Delete a consumer - returns count of pending messages it had
Long pendingCount = client.xgroupDelConsumer(
    "mystream", "mygroup", "consumer1").get();

// Destroy the entire group
boolean destroyed = client.xgroupDestroy("mystream", "mygroup").get();
```

## Set Group Last-Delivered ID

```java
client.xgroupSetId("mystream", "mygroup", "0").get();
```

## Cluster Mode

In cluster mode, all keys in a single `xread` or `xreadgroup` call must map to the same hash slot. Use hash tags if needed:

```java
client.xread(Map.of("{app}.stream1", "0-0", "{app}.stream2", "0-0")).get();
```

## Full Consumer Group Pattern

```java
// Setup
client.xgroupCreate("tasks", "workers", "0-0",
    StreamGroupOptions.builder().makeStream().build()).get();

// Producer
client.xadd("tasks", Map.of("job", "process-image", "url", "img.png")).get();

// Consumer loop
while (true) {
    var messages = client.xreadgroup(
        Map.of("tasks", ">"), "workers", "worker-1",
        StreamReadGroupOptions.builder().count(5L).block(2000L).build()).get();
    if (messages == null) continue;
    for (var stream : messages.values()) {
        for (var entry : stream.entrySet()) {
            // process entry.getValue() fields, then acknowledge
            client.xack("tasks", "workers", new String[]{entry.getKey()}).get();
        }
    }
}
```
