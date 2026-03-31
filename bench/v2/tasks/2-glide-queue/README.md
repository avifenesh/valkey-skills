# Task Queue - Reliable Message Queue with Valkey Streams

Implement a reliable message queue using Valkey Streams and the GLIDE Node.js client.

## Task

Complete `queue.js` with the implementations described in the TODOs. All code must use `@valkey/valkey-glide` - not ioredis, not node-redis.

## Requirements

1. **TaskQueue** - producer that adds tasks to a stream
2. **Worker** - consumer group reader with acknowledgment and dead letter handling
3. **3 concurrent workers** in one process
4. **Dead letter queue** - reclaim stale messages after 30s, move to DLQ after 3 retries
5. **Dashboard** - periodic status display
6. **Graceful shutdown** on SIGTERM/SIGINT

## Run

```bash
docker compose up --build
```

The app container runs in Docker (GLIDE native deps require Linux). Valkey is a separate container.

## Validation

The queue should:
- Process all 100 tasks across 3 workers
- Show dashboard output with stream stats
- Handle at-least-once delivery
- Exit cleanly on interrupt
