I need to build a message queue system in Node.js/TypeScript using Valkey via `@valkey/valkey-glide`. This will run against an ElastiCache Valkey cluster with TLS enabled in production, so keep that in mind for connection setup. This is a greenfield build - no migration, no wrappers around existing libraries. Performance and durability matter - we can't lose jobs.

I need three things in `src/mq.ts`:

## 1. WorkQueue

A reliable work queue backed by Valkey Streams with consumer group support.

**Methods:**
- `enqueue(job: Job): Promise<string>` - Add a job to the stream. Returns the stream entry ID.
- `dequeue(consumer: string, count: number, blockMs: number): Promise<QueueMessage[]>` - Read messages from the consumer group with optional blocking. Returns decoded messages.
- `ack(jobId: string): Promise<void>` - Acknowledge a processed job (remove from pending).
- `retry(maxRetries: number): Promise<number>` - Inspect pending messages. Move any that have exceeded `maxRetries` delivery attempts to a dead-letter stream. Returns the count moved to dead-letter.

The queue must:
- Create the consumer group automatically on first use (handle the case where the group already exists)
- Use stream auto-generated IDs
- Support multiple concurrent consumers in the same group

## 2. DistributedLock

A single-instance distributed lock using the SET NX pattern (NOT Redlock).

**Methods:**
- `acquire(resource: string, ttlMs: number): Promise<boolean>` - Acquire a lock with a random token and TTL. Returns true if acquired.
- `release(resource: string): Promise<boolean>` - Release the lock only if the caller still holds it. Returns true if released.
- `extend(resource: string, ttlMs: number): Promise<boolean>` - Extend the lock TTL if the caller still holds it.

Critical safety stuff:
- Lock values must be unique per acquisition (use UUID or random token)
- Release MUST atomically verify ownership before deleting - use a Lua script that checks the stored value matches before calling DEL. A plain GET-then-DEL is NOT safe (race condition between the two commands).
- Extend must also verify ownership before setting new TTL

## 3. RateLimiter

A sliding window rate limiter using sorted sets.

**Methods:**
- `isAllowed(key: string, maxRequests: number, windowMs: number): Promise<boolean>` - Returns true if the request is within the rate limit.

The implementation must:
- Use a sorted set with timestamps as scores
- Remove expired entries (outside the window) before counting
- Add the new entry and check the count atomically (use a pipeline or Lua script to prevent race conditions)
- Set a TTL on the sorted set key to auto-cleanup

## Types

```typescript
interface Job {
  name: string;
  data: Record<string, string>;
}

interface QueueMessage {
  id: string;
  fields: Record<string, string>;
}
```

## Constraints

- Use `@valkey/valkey-glide` - do NOT use `ioredis`, `redis`, or any other client library
- Use `GlideClient` or `GlideClusterClient` (whichever is appropriate for cluster mode)
- For local testing, Valkey is on `localhost:6507` (no TLS). But the code should support TLS configuration for production.
- All classes should accept a `GlideClient` instance in their constructor
- Export all classes and types from `src/mq.ts`

## What I need delivered

1. `src/mq.ts` - Complete implementation of all three classes
2. All existing tests in `src/mq.test.ts` must pass
3. The code must compile with `npm run build`

## Performance

The queue should handle 1000+ enqueue/dequeue operations per second on a single Valkey instance. Use efficient patterns - minimize round trips, use pipelines where appropriate, prefer blocking reads over polling.
