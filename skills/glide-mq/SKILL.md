---
name: glide-mq
description: "Use when building message queues with glide-mq. Covers queue setup, producer/consumer patterns, job scheduling, workflows, batch processing, AI/LLM job metadata, streaming, suspend/resume, budget middleware, and greenfield glide-mq development."
version: 1.1.0
argument-hint: "[task description]"
---

# glide-mq

Provides guidance for greenfield glide-mq message queue development - queues, workers, producers, job scheduling, and workflows.

> This is a thin wrapper. For full API reference, advanced patterns, and deep documentation, see https://glidemq.dev/

## Install

```bash
npm install glide-mq
```

Requires Node.js 20+ and Valkey 7.0+ (or Redis 7.0+).

## Connection

All glide-mq classes use the addresses array format:

```typescript
const connection = { addresses: [{ host: 'localhost', port: 6379 }] };
```

With TLS and authentication:

```typescript
const connection = {
  addresses: [{ host: 'my-cluster.cache.amazonaws.com', port: 6379 }],
  useTLS: true,
  credentials: { password: 'secret' },
  clusterMode: true,
};
```

## Quick Start

```typescript
import { Queue, Worker } from 'glide-mq';

const connection = { addresses: [{ host: 'localhost', port: 6379 }] };

// Producer
const queue = new Queue('tasks', { connection });
await queue.add('send-email', { to: 'user@example.com' }, {
  attempts: 3,
  backoff: { type: 'exponential', delay: 1000 },
  priority: 1,
});

// Consumer
const worker = new Worker('tasks', async (job) => {
  console.log(`Processing ${job.name}:`, job.data);
  return { sent: true };
}, { connection, concurrency: 10 });

worker.on('completed', (job) => console.log(`Job ${job.id} done`));
worker.on('failed', (job, err) => console.error(`Job ${job.id} failed:`, err.message));
```

## Core API

| Class | Purpose | Key Methods |
|-------|---------|-------------|
| `Queue` | Enqueue and manage jobs | `add()`, `addBulk()`, `addAndWait()`, `pause()`, `resume()`, `drain()`, `rateLimitGroup()`, `signal()`, `readStream()`, `getFlowUsage()`, `search()` |
| `Worker` | Process jobs | Constructor takes `(name, processor, opts)`. Events: `completed`, `failed`, `active` |
| `Producer` | Lightweight enqueue (serverless) | `add()` - no EventEmitter overhead |
| `FlowProducer` | Parent-child job trees | `add()` for DAG workflows |
| `QueueEvents` | Monitor queue events | `on('completed')`, `on('failed')`, `on('delayed')` |
| `Broadcast` | Durable pub/sub | Fan-out with subject filtering |
| `Scheduler` | Cron-based job scheduling | `upsertJobScheduler()`, cron patterns with timezone |

## Job Options

| Option | Type | Description |
|--------|------|-------------|
| `attempts` | number | Retry count on failure |
| `backoff` | object | `{ type: 'exponential' \| 'fixed', delay: ms }` |
| `delay` | number | Delay before processing (ms) |
| `priority` | number | Lower number = higher priority (0 is highest) |
| `ttl` | number | Auto-expire after time-to-live (ms) |
| `jobId` | string | Custom deduplication ID |
| `ordering.key` | string | Per-key ordering group |
| `ordering.concurrency` | number | Max parallel jobs per group (default 1) |
| `ordering.rateLimit` | object | `{ max, duration }` - static sliding window per group |
| `ordering.tokenBucket` | object | `{ capacity, refillRate }` - cost-based rate limiting per group |

**Runtime group rate limiting:**
- `job.rateLimitGroup(duration, opts?)` - pause group from inside processor (e.g., on 429)
- `throw new GroupRateLimitError(duration, opts?)` - throw-style sugar
- `queue.rateLimitGroup(key, duration, opts?)` - pause group from outside (webhook, health check)
- Options: `currentJob` ('requeue'|'fail'), `requeuePosition` ('front'|'back'), `extend` ('max'|'replace')

**Note:** Compression (`compression: 'gzip'`) is a Queue-level option passed to the Queue constructor, not a per-job option.

## AI/LLM Features (v0.13+)

### Usage Tracking

Report LLM token and cost data per job, aggregate across flows:

```typescript
// Inside processor
await job.reportUsage({
  model: 'claude-sonnet-4-20250514',
  tokens: { input: 1200, output: 340, reasoning: 500 },
  costs: { total: 0.0043 },
});

// Aggregate across a flow
const usage = await queue.getFlowUsage(flowId);
// { tokens: { input, output, reasoning }, costs: { total }, totalTokens, totalCost }
```

### Per-Job Streaming

Publish incremental data (LLM tokens, progress events) from inside a processor:

```typescript
// Producer side
await job.stream({ type: 'content', content: 'partial response...' });
await job.streamChunk('reasoning', 'thinking step...');

// Consumer side
for await (const chunk of queue.readStream(jobId)) {
  process.stdout.write(chunk.content);
}
```

### Suspend / Resume

Pause a job mid-processor and resume with an external signal (human-in-the-loop, webhook callback):

```typescript
// Inside processor - suspends until signal arrives
await job.suspend({ reason: 'awaiting-approval', timeout: 300_000 });

// External trigger (API route, webhook)
await queue.signal(jobId, 'approved', { reviewer: 'alice' });
```

### Fallback Chains

Ordered list of model/provider alternatives. On processor failure, the job retries with the next fallback:

```typescript
await queue.add('generate', { prompt: '...' }, {
  fallbacks: [
    { data: { model: 'claude-sonnet-4-20250514' } },
    { data: { model: 'gpt-4o' } },
  ],
});
```

### Budget Middleware

Flow-level token and cost caps. Jobs exceeding the budget are failed before execution:

```typescript
await flowProducer.add({
  name: 'orchestrator',
  data: {},
  opts: {
    budget: { maxTotalCost: 1.00, maxTokens: { reasoning: 50000 }, costUnit: 'USD' },
  },
  children: [/* ... */],
});
```

### Dual-Axis Rate Limiting (RPM + TPM)

Enforce both requests-per-minute and tokens-per-minute limits on a queue - designed for LLM API compliance:

```typescript
const worker = new Worker('llm-tasks', processor, {
  connection,
  rateLimit: { rpm: 60, tpm: 100_000 },
});
```

### Valkey Search Integration

Vector search over jobs using the Valkey Search module:

```typescript
await queue.createIndex(schema, opts);
const results = await queue.search(query, opts);
```

## Worker Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `concurrency` | number | 1 | Parallel job limit |
| `lockDuration` | number | 30000 | Lock timeout (ms) - overridable per job |
| `stalledInterval` | number | 30000 | Recovery check frequency (ms) |

## Connection Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `addresses` | array | required | `[{ host, port }]` |
| `useTLS` | boolean | false | Enable TLS |
| `credentials` | object | - | `{ password }` or `{ username, password }` |
| `clusterMode` | boolean | false | Connect to cluster |
| `requestTimeout` | number | 500 | Command timeout (ms) |

## Scheduling and Testing

```typescript
// Cron scheduling
await queue.upsertJobScheduler('daily-report',
  { pattern: '0 9 * * *', tz: 'America/New_York' },
  { name: 'daily-report', data: { v: 1 } },
);

// In-memory testing (no Valkey/Redis required)
import { TestQueue, TestWorker } from 'glide-mq/testing';
const queue = new TestQueue('tasks');
const worker = new TestWorker(queue, async (job) => ({ sent: true }));
```

## Critical Notes

- Connection uses `{ addresses: [{ host, port }] }` - NOT `{ host, port }` directly
- Priority: lower number = higher priority (0 is highest)
- Keys are hash-tagged (`glide:{queueName}:*`) for native cluster support
- Single FCALL per operation - no Lua EVAL overhead

## Deep Dive

For complete API reference, workflows, observability, and serverless guides:
- `node_modules/glide-mq/skills/` | https://glidemq.dev/
