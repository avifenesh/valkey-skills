# Queue Patterns

Use when implementing task queues, job processing, or message passing between services using Valkey as the message broker.

## Contents

- Simple Queue (LPUSH/BRPOP) (line 16)
- Reliable Queue (LMOVE) (line 75)
- Stream-Based Queue (XADD/XREADGROUP) (line 132)
- Comparison Table (line 306)
- Priority Queue (line 348)
- See Also (line 368)

---

## Simple Queue (LPUSH/BRPOP)

The simplest queue pattern: producers push to one end, consumers pop from the other.

### How It Works

```
# Producer: push tasks to the left
LPUSH queue:tasks '{"type":"email","to":"user@example.com"}'

# Consumer: blocking pop from the right (FIFO order)
BRPOP queue:tasks 30
# Blocks up to 30 seconds waiting for a message
# Returns: ["queue:tasks", "{\"type\":\"email\",...}"]
```

### Code Examples

**Node.js (Producer)**:
```javascript
async function enqueue(redis, queueName, payload) {
  await redis.lpush(`queue:${queueName}`, JSON.stringify(payload));
}
```

**Node.js (Consumer)**:
```javascript
async function processQueue(redis, queueName, handler) {
  while (true) {
    const result = await redis.brpop(`queue:${queueName}`, 30);
    if (result) {
      const [, message] = result;
      await handler(JSON.parse(message));
    }
  }
}
```

**Python (Consumer)**:
```python
async def process_queue(redis, queue_name: str, handler):
    while True:
        result = await redis.brpop(f"queue:{queue_name}", timeout=30)
        if result:
            _, message = result
            await handler(json.loads(message))
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| Simple, minimal code | At-most-once delivery (message lost if consumer crashes after pop) |
| O(1) push and pop | No acknowledgment mechanism |
| Blocking pop avoids polling | No redelivery for failed processing |
| Multiple consumers for load balancing | No message history or replay |

---

## Reliable Queue (LMOVE)

Adds reliability by moving messages to a processing list instead of removing them. If the consumer crashes, messages can be recovered.

### How It Works

```
# Producer: same as simple queue
LPUSH queue:tasks '{"type":"email","to":"user@example.com"}'

# Consumer: atomically move from queue to processing list
LMOVE queue:tasks queue:tasks:processing RIGHT LEFT
# Returns the message AND moves it to the processing list

# After successful processing, remove from processing list
LREM queue:tasks:processing 1 '<the message>'

# For failed messages, move back to the main queue
LMOVE queue:tasks:processing queue:tasks LEFT RIGHT
```

### Blocking Variant

```
# BLMOVE blocks until a message is available
BLMOVE queue:tasks queue:tasks:processing RIGHT LEFT 30
# Blocks up to 30 seconds
```

### Recovery Process

Periodically scan the processing list for stuck messages (consumers that crashed):

```python
async def recover_stuck_messages(redis, queue_name: str, timeout_secs: int = 300):
    processing_key = f"queue:{queue_name}:processing"
    # Check entries in the processing list
    messages = await redis.lrange(processing_key, 0, -1)
    for msg in messages:
        data = json.loads(msg)
        if time.time() - data.get('started_at', 0) > timeout_secs:
            # Move back to main queue for reprocessing
            await redis.lrem(processing_key, 1, msg)
            await redis.lpush(f"queue:{queue_name}", msg)
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| At-least-once delivery | Requires recovery process |
| Crashed consumers do not lose messages | More complex than simple queue |
| Atomic move operation | No built-in retry count or dead letter |
| Multiple consumers supported | Message must be exactly matched for LREM |

---

## Stream-Based Queue (XADD/XREADGROUP)

Streams with consumer groups provide the most robust queue implementation: at-least-once delivery, pending message tracking with explicit claim/recovery (XCLAIM/XAUTOCLAIM), consumer load balancing, and message history.

### Setup

```
# Create the stream and consumer group
XGROUP CREATE queue:tasks workers $ MKSTREAM
# $ = start from new messages only
# MKSTREAM = create the stream if it does not exist
```

### Producer

```
XADD queue:tasks * type email to user@example.com subject "Welcome"
# * = auto-generate ID (timestamp-sequence)
# Returns: "1711670400000-0"
```

### Consumer

```
# Read new messages (blocks up to 5 seconds)
XREADGROUP GROUP workers consumer1 COUNT 10 BLOCK 5000 STREAMS queue:tasks >
# > = only new messages not yet delivered to this consumer

# After successful processing, acknowledge
XACK queue:tasks workers 1711670400000-0

# Check pending (unacknowledged) messages
XPENDING queue:tasks workers - + 10
```

### Code Examples

**Node.js (Consumer)**:
```javascript
async function streamConsumer(redis, stream, group, consumer) {
  // Ensure group exists
  try {
    await redis.xgroup('CREATE', stream, group, '$', 'MKSTREAM');
  } catch (e) {
    if (!e.message.includes('BUSYGROUP')) throw e;
  }

  while (true) {
    const results = await redis.xreadgroup(
      'GROUP', group, consumer,
      'COUNT', 10, 'BLOCK', 5000,
      'STREAMS', stream, '>'
    );

    if (!results) continue;

    for (const [, messages] of results) {
      for (const [id, fields] of messages) {
        try {
          await processMessage(Object.fromEntries(
            fields.reduce((acc, v, i, arr) =>
              i % 2 === 0 ? [...acc, [v, arr[i+1]]] : acc, [])
          ));
          await redis.xack(stream, group, id);
        } catch (err) {
          console.error(`Failed to process ${id}:`, err);
          // Message stays in pending - will be reclaimed later
        }
      }
    }
  }
}
```

**Python (Consumer)**:
```python
async def stream_consumer(redis, stream: str, group: str, consumer: str):
    # Ensure group exists
    try:
        await redis.xgroup_create(stream, group, "$", mkstream=True)
    except Exception as e:
        if "BUSYGROUP" not in str(e):
            raise

    while True:
        results = await redis.xreadgroup(
            group, consumer,
            streams={stream: ">"},
            count=10, block=5000
        )
        if not results:
            continue

        for stream_name, messages in results:
            for msg_id, fields in messages:
                try:
                    await process_message(fields)
                    await redis.xack(stream, group, msg_id)
                except Exception:
                    pass  # Stays pending for reclaim
```

### Reclaiming Stuck Messages

Messages that were delivered but not acknowledged (consumer crashed) can be reclaimed:

```
# Find messages pending for more than 5 minutes
XPENDING queue:tasks workers - + 10

# Claim them for another consumer
XCLAIM queue:tasks workers consumer2 300000 1711670400000-0
# 300000 = min idle time in ms (5 minutes)

# Or auto-claim the oldest idle messages
XAUTOCLAIM queue:tasks workers consumer2 300000 0-0 COUNT 10
```

### XAUTOCLAIM Cursor-Based Recovery

XAUTOCLAIM uses SCAN-like cursor semantics for efficient recovery sweeps. It returns three values: the next cursor, claimed messages, and IDs of messages that no longer exist in the stream.

**Node.js recovery loop**:
```javascript
async function recoverStuckMessages(redis, stream, group, consumer, minIdleMs) {
  let cursor = '0-0';
  do {
    const [nextCursor, claimed, deleted] = await redis.xautoclaim(
      stream, group, consumer, minIdleMs, cursor, 'COUNT', 50
    );
    cursor = nextCursor;

    for (const [id, fields] of claimed) {
      try {
        await processMessage(fields);
        await redis.xack(stream, group, id);
      } catch (err) {
        // Will be reclaimed in next sweep
      }
    }
  } while (cursor !== '0-0');
}

// Run periodically (e.g., every 30 seconds)
setInterval(() => recoverStuckMessages(redis, 'queue:tasks', 'workers', 'recovery', 300000), 30000);
```

When the cursor returns `0-0`, all pending entries have been scanned. The JUSTID option returns only message IDs without bodies and does not increment the delivery counter - useful for inspection without side effects.

### Stream Trimming

Streams grow indefinitely. Trim old messages to bound memory:

```
# Keep at most 10,000 entries
XTRIM queue:tasks MAXLEN ~ 10000
# ~ = approximate trimming (more efficient, may keep slightly more)

# Or trim by minimum ID (time-based)
XTRIM queue:tasks MINID ~ 1711584000000-0
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| At-least-once delivery (with ACK) | More complex setup |
| Automatic load balancing across consumers | Stream grows without trimming |
| Message history and replay | Higher memory per message than lists |
| Built-in pending tracking and reclaim | Consumer group management overhead |
| Multiple consumer groups on same stream | |

---

## Comparison Table

| Feature | Simple (List) | Reliable (LMOVE) | Stream (XREADGROUP) |
|---------|--------------|-------------------|---------------------|
| Delivery guarantee | At-most-once | At-least-once | At-least-once |
| Consumer groups | No (manual) | No (manual) | Yes (built-in) |
| Message acknowledgment | No | Manual (LREM) | Yes (XACK) |
| Dead letter handling | No | Manual | Via XCLAIM |
| Message history | No (consumed = gone) | In processing list | Yes (full history) |
| Blocking read | BRPOP | BLMOVE | XREADGROUP BLOCK |
| Memory efficiency | Best | Good | Higher per message |
| Complexity | Low | Medium | Medium-High |
| Ordering | FIFO | FIFO | Per-stream ordered |

### Choosing a Pattern

- **Simple queue**: Fire-and-forget tasks where occasional loss is acceptable. Background jobs with idempotent processing.
- **Reliable queue (LMOVE)**: Tasks where loss is unacceptable but you want simplicity. Fewer consumers.
- **Stream queue**: Production workloads with multiple consumers, acknowledgment, replay, and monitoring needs. The recommended approach for non-trivial queue workloads.
- **glide-mq** (Node.js): For production job queues that need retries, scheduling, priority, dead letter queues, and per-key ordered processing out of the box - built natively on Valkey using FCALL. See the **glide-mq** skill.

```typescript
// glide-mq example - production queue with retries and scheduling
import { Queue, Worker } from 'glide-mq';

const connection = { addresses: [{ host: 'localhost', port: 6379 }] };
const queue = new Queue('tasks', { connection });

await queue.add('send-email', { to: 'user@example.com' }, {
  attempts: 3,
  backoff: { type: 'exponential', delay: 1000 },
  priority: 1,
});

const worker = new Worker('tasks', async (job) => {
  console.log(`Processing ${job.name}:`, job.data);
  return { sent: true };
}, { connection, concurrency: 10 });
```

---

## Priority Queue

Use a sorted set as a priority queue. The score represents priority (lower = higher priority):

```
# Enqueue with priority
ZADD queue:priority 1 '{"type":"critical","task":"alert"}'
ZADD queue:priority 5 '{"type":"normal","task":"report"}'
ZADD queue:priority 10 '{"type":"low","task":"cleanup"}'

# Dequeue highest priority (lowest score)
ZPOPMIN queue:priority
# Returns: ['{"type":"critical",...}', "1"]

# Blocking variant
BZPOPMIN queue:priority 30
```

---

## See Also

- [List Commands](../basics/data-types.md) - LPUSH, BRPOP, LMOVE for list-based queues
- [Stream Commands](../basics/data-types.md) - XADD, XREADGROUP, XACK for stream queues
- [Sorted Set Commands](../basics/data-types.md) - ZADD, ZPOPMIN for priority queues
- [Pub/Sub Patterns](pubsub-patterns.md) - fan-out messaging (alternative to point-to-point queues)
- [Lock Patterns](locks.md) - coordinating access to shared resources
- [Counter Patterns](counters.md) - idempotency keys for deduplicating queue messages
- [Rate Limiting Patterns](rate-limiting.md) - throttling message processing rate
- [Performance Best Practices](../best-practices/performance.md) - pipelining for batch operations
- [Memory Best Practices](../best-practices/memory.md) - stream trimming and list memory usage
- [Key Best Practices](../best-practices/keys.md) - key naming for queue keys
- [High Availability Best Practices](../best-practices/high-availability.md) - queue message safety during failover
- [Persistence Best Practices](../best-practices/persistence.md) - AOF durability for queue messages
- [Cluster Best Practices](../best-practices/cluster.md) - hash tags for queue keys in cluster mode
- [Security: Auth and ACL](../security/auth-and-acl.md) - ACL permissions for queue workers
- Clients Overview (see valkey-glide skill) - dedicated connections for blocking queue consumers
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - unbounded list/stream growth, blocking commands on shared connections
