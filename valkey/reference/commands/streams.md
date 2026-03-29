# Stream Commands

Use when you need an append-only log with consumer groups - event sourcing, reliable messaging, activity feeds, change data capture, or task distribution across multiple consumers. Streams provide at-least-once delivery, automatic redelivery, and load balancing.

---

## Writing

### XADD

```
XADD key [NOMKSTREAM] [MAXLEN | MINID [= | ~] threshold [LIMIT count]] * | id field value [field value ...]
```

Appends a new entry to the stream. The `*` ID auto-generates a timestamp-based unique ID. Creates the key if it does not exist (unless NOMKSTREAM is specified). Returns the entry ID.

**Complexity**: O(1) for adding, O(N) when trimming

**Trimming options** (applied atomically with the add):

| Option | Effect |
|--------|--------|
| `MAXLEN n` | Keep at most n entries |
| `MAXLEN ~ n` | Approximately n entries (more efficient) |
| `MINID id` | Remove entries with IDs lower than id |
| `LIMIT count` | Limit trimming effort (with ~ operator) |

```
-- Auto-generated ID
XADD events:orders * type "placed" order_id "5678" amount "99.99"
-- "1711670400000-0"

-- With capped length (approximately 1000 entries)
XADD events:orders MAXLEN ~ 1000 * type "shipped" order_id "5678"

-- Custom ID
XADD mystream 1711670400000-0 field "value"

-- Don't create stream if it doesn't exist
XADD events:temp NOMKSTREAM * data "value"
-- (nil) if stream doesn't exist
```

### XDEL

```
XDEL key id [id ...]
```

Removes entries by ID. Does not reclaim memory immediately - the stream structure retains gaps. Returns the number of entries actually deleted.

**Complexity**: O(1) per entry

```
XDEL events:orders 1711670400000-0    -- 1
```

### XTRIM

```
XTRIM key MAXLEN | MINID [= | ~] threshold [LIMIT count]
```

Trims the stream to the specified length or minimum ID. The `~` operator allows approximate trimming for better performance.

**Complexity**: O(N) where N is the number of evicted entries

```
XTRIM events:orders MAXLEN 1000          -- exact cap
XTRIM events:orders MAXLEN ~ 1000        -- approximate (faster)
XTRIM events:orders MINID 1711670000000  -- remove entries older than ID
```

---

## Reading

### XRANGE

```
XRANGE key start end [COUNT count]
```

Returns entries with IDs between `start` and `end` (inclusive). Use `-` for the minimum ID and `+` for the maximum. Returns entries in ID order.

**Complexity**: O(log N + M) where M is the number of entries returned

```
-- All entries
XRANGE events:orders - +

-- Last 10 entries
XRANGE events:orders - + COUNT 10

-- Entries in a time range (IDs are timestamp-based)
XRANGE events:orders 1711670000000 1711680000000

-- Exclusive start (for pagination) - append -0 after last seen ID
XRANGE events:orders 1711670400000-1 + COUNT 10
```

### XREVRANGE

```
XREVRANGE key end start [COUNT count]
```

Same as XRANGE but returns entries in reverse ID order. Note the arguments are reversed (end, start).

**Complexity**: O(log N + M)

```
-- Last 5 entries, newest first
XREVRANGE events:orders + - COUNT 5
```

### XREAD

```
XREAD [COUNT count] [BLOCK milliseconds] STREAMS key [key ...] id [id ...]
```

Reads entries from one or more streams, starting after the specified IDs. With BLOCK, waits for new entries. Use `$` as the ID to read only new entries arriving after the command is issued.

**Complexity**: O(N) where N is the count of entries returned across all streams

```
-- Read up to 10 new entries from two streams (non-blocking)
XREAD COUNT 10 STREAMS events:orders events:payments 0-0 0-0

-- Block for up to 5 seconds waiting for new entries
XREAD COUNT 1 BLOCK 5000 STREAMS events:orders $

-- Block indefinitely
XREAD BLOCK 0 STREAMS events:orders $
```

### XLEN

```
XLEN key
```

Returns the number of entries in the stream.

**Complexity**: O(1)

```
XLEN events:orders    -- 42
```

---

## Consumer Groups

Consumer groups distribute stream entries across multiple consumers. Each entry is delivered to exactly one consumer in the group (load balancing). Unacknowledged entries are tracked and can be reclaimed.

### XGROUP CREATE

```
XGROUP CREATE key group id | $ [MKSTREAM] [ENTRIESREAD n]
```

Creates a consumer group on a stream. The `id` specifies where to start reading - use `$` for new entries only, `0` for all existing entries. MKSTREAM creates the stream if it does not exist.

**Complexity**: O(1)

```
-- Create group starting from new entries
XGROUP CREATE events:orders workers $

-- Create group reading all existing entries, create stream if needed
XGROUP CREATE events:orders processors 0 MKSTREAM
```

### XGROUP DESTROY

```
XGROUP DESTROY key group
```

Destroys a consumer group. All pending entries are discarded. Returns 1 if destroyed, 0 if group did not exist.

### XGROUP DELCONSUMER

```
XGROUP DELCONSUMER key group consumer
```

Removes a consumer from a group. Returns the number of pending entries that the consumer had (these entries become unowned).

### XGROUP SETID

```
XGROUP SETID key group id | $ [ENTRIESREAD n]
```

Sets the last-delivered ID for the group. Use to rewind or fast-forward a consumer group.

```
-- Reset group to re-read all entries
XGROUP SETID events:orders workers 0
```

---

## Consumer Group Reading

### XREADGROUP

```
XREADGROUP GROUP group consumer [COUNT count] [BLOCK milliseconds] [NOACK] STREAMS key [key ...] id [id ...]
```

Reads entries via a consumer group. Each entry is delivered to only one consumer. Use `>` as the ID to get new (undelivered) entries. Use `0` (or any other ID) to get pending entries for this consumer.

**Complexity**: O(M) where M is the number of entries returned

```
-- Read new entries (blocks up to 5 seconds)
XREADGROUP GROUP workers consumer1 COUNT 10 BLOCK 5000 STREAMS events:orders >

-- Read pending entries assigned to this consumer
XREADGROUP GROUP workers consumer1 COUNT 10 STREAMS events:orders 0

-- NOACK: auto-acknowledge (at-most-once delivery)
XREADGROUP GROUP workers consumer1 COUNT 10 NOACK STREAMS events:orders >
```

### XACK

```
XACK key group id [id ...]
```

Acknowledges that entries have been processed. Removes them from the consumer's pending entries list (PEL). Returns the number of entries acknowledged.

**Complexity**: O(1) per entry

```
XACK events:orders workers 1711670400000-0 1711670400001-0
-- 2
```

---

## Pending Entry Management

### XPENDING

```
XPENDING key group [[IDLE min-idle-time] start end count [consumer]]
```

Inspects the pending entries list (PEL). Without optional arguments, returns a summary. With range arguments, returns detailed entries.

**Complexity**: O(N) with range, O(1) for summary

```
-- Summary: total pending, min/max IDs, consumers with counts
XPENDING events:orders workers
-- 1) (integer) 5
-- 2) "1711670400000-0"
-- 3) "1711670400004-0"
-- 4) 1) 1) "consumer1" 2) "3"
--    2) 1) "consumer2" 2) "2"

-- Detailed: entries pending for consumer1
XPENDING events:orders workers - + 10 consumer1
-- For each: ID, consumer, idle time (ms), delivery count

-- Only entries idle for more than 60 seconds
XPENDING events:orders workers IDLE 60000 - + 10
```

### XCLAIM

```
XCLAIM key group consumer min-idle-time id [id ...] [IDLE ms] [TIME ms] [RETRYCOUNT n] [FORCE] [JUSTID]
```

Changes ownership of pending entries to a different consumer. Entries must be idle for at least `min-idle-time` milliseconds. Use for manual recovery of stuck entries.

**Complexity**: O(log N) per entry

```
-- Claim entries idle for more than 60 seconds
XCLAIM events:orders workers consumer2 60000 1711670400000-0 1711670400001-0
```

### XAUTOCLAIM

```
XAUTOCLAIM key group consumer min-idle-time start [COUNT count] [JUSTID]
```

Automatically claims pending entries that have been idle for at least `min-idle-time`. Combines XPENDING + XCLAIM into one command with SCAN-like cursor semantics. Use for automatic dead-consumer recovery. Available since 6.2.

**Complexity**: O(1) when COUNT is small

**Return value**: Array of three elements:
1. Next cursor ID (use as `start` in the next call; `0-0` when scan is complete)
2. Array of claimed messages (in XRANGE format - ID + field-value pairs)
3. Array of message IDs that no longer exist in the stream (cleaned from PEL)

```
-- Auto-claim entries idle for 60+ seconds, starting from beginning
XAUTOCLAIM events:orders workers consumer2 60000 0-0 COUNT 10
-- 1) "1711670400005-0"    (next cursor for subsequent call)
-- 2) [claimed entries with data]
-- 3) [IDs of entries that no longer exist in the stream]
```

**JUSTID option**: Returns only message IDs instead of full message bodies. Does not increment the delivery counter - useful for scanning without side effects.

**Cursor-based recovery pattern** (periodic sweep):
```
-- Run as a periodic task to recover from failed consumers
cursor = "0-0"
WHILE true
    result = XAUTOCLAIM mystream mygroup recovery-consumer 300000 cursor COUNT 50
    cursor = result[0]
    process(result[1])      -- process claimed messages
    if cursor == "0-0"
        SLEEP(interval)     -- wait before next full sweep
        cursor = "0-0"      -- restart scan
    end
end
```

When the cursor returns `0-0`, all pending entries have been scanned. Start a new sweep after a delay.

---

## Stream Information

### XINFO STREAM

```
XINFO STREAM key [FULL [COUNT count]]
```

Returns information about the stream: length, radix-tree details, first/last entry, consumer groups. FULL provides detailed output including all PEL entries.

```
XINFO STREAM events:orders
```

### XINFO GROUPS

```
XINFO GROUPS key
```

Returns information about all consumer groups on the stream: name, consumers, pending count, last-delivered-id.

```
XINFO GROUPS events:orders
```

### XINFO CONSUMERS

```
XINFO CONSUMERS key group
```

Returns information about consumers in a group: name, pending count, idle time, inactive time.

```
XINFO CONSUMERS events:orders workers
```

---

## Practical Patterns

**Reliable task queue with consumer groups**:
```
-- Setup
XGROUP CREATE tasks workers $ MKSTREAM

-- Producer
XADD tasks * type "email" to "user@example.com" body "Welcome"

-- Consumer (blocks for work)
entries = XREADGROUP GROUP workers consumer1 COUNT 1 BLOCK 5000 STREAMS tasks >
-- Process entry...
XACK tasks workers entry_id
```

**Dead letter recovery**:
```
-- Periodically scan for stuck entries
XAUTOCLAIM tasks workers recovery-consumer 300000 0-0 COUNT 100
-- Entries idle > 5 minutes are reassigned to recovery-consumer
```

**Event fan-out (multiple consumer groups)**:
```
-- Each service gets its own group, each sees all events
XGROUP CREATE events:orders billing 0 MKSTREAM
XGROUP CREATE events:orders shipping 0 MKSTREAM
XGROUP CREATE events:orders analytics 0 MKSTREAM

-- Single producer
XADD events:orders * type "placed" order_id "5678"

-- Each service reads independently
XREADGROUP GROUP billing biller1 COUNT 10 BLOCK 5000 STREAMS events:orders >
XREADGROUP GROUP shipping shipper1 COUNT 10 BLOCK 5000 STREAMS events:orders >
```

**Capped event log**:
```
-- Append with automatic trimming
XADD events:audit MAXLEN ~ 10000 * action "login" user "alice"
```

**Time-range queries**:
```
-- Entries from a specific time window (IDs embed timestamps)
XRANGE events:orders 1711670000000 1711680000000 COUNT 100
```

---

## See Also

- [Queue Patterns](../patterns/queues.md) - stream-based queues with consumer groups
- [Pub/Sub Patterns](../patterns/pubsub-patterns.md) - streams vs pub/sub comparison
- [Anti-Patterns](../anti-patterns/quick-reference.md) - unbounded stream growth, pub/sub for durable messaging
