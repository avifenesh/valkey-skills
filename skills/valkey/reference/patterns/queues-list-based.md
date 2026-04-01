# List-Based Queue Patterns

Use when implementing simple task queues with LPUSH/BRPOP or reliable queues with LMOVE for at-least-once delivery guarantees.

## Contents

- Simple Queue (LPUSH/BRPOP) (line 12)
- Reliable Queue (LMOVE) (line 71)

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
