import { GlideClient } from "@valkey/valkey-glide";

/**
 * Reliable Message Queue using Valkey Streams + GLIDE Node.js
 *
 * This file has the skeleton. You need to implement:
 *
 * 1. TaskQueue class - produces tasks to a stream
 * 2. Worker class - consumes tasks from a consumer group with:
 *    - Consumer group creation (XGROUP CREATE)
 *    - Blocking read (XREADGROUP with BLOCK)
 *    - Acknowledgment (XACK after processing)
 *    - Dead letter queue: claim stale pending messages (XPENDING + XCLAIM)
 *      after 30 seconds, move to "deadletter" stream after 3 failed claims
 *    - Graceful shutdown (stop reading, finish current task, disconnect)
 * 3. Batch producer - add 100 tasks with different priorities
 * 4. Multiple workers - run 3 concurrent workers in the same process
 * 5. Dashboard - periodic status showing:
 *    - Stream length (XLEN)
 *    - Pending messages per consumer (XPENDING)
 *    - Dead letter count
 *    - Processed count
 *
 * All must use @valkey/valkey-glide APIs. Not ioredis, not node-redis.
 * Must run via: docker compose up (see docker-compose.yml)
 *
 * The queue must handle:
 * - Worker crash recovery (pending messages get reclaimed)
 * - At-least-once delivery
 * - Backpressure (workers pause when busy)
 * - Proper cleanup on shutdown (SIGTERM/SIGINT)
 */

const STREAM_KEY = "tasks:queue";
const GROUP_NAME = "workers";
const DL_STREAM = "tasks:deadletter";
const CLAIM_TIMEOUT_MS = 30000;
const MAX_CLAIM_RETRIES = 3;

// TODO: Implement TaskQueue class
// - constructor(client): store GlideClient instance
// - async addTask(task): XADD to stream with task data fields
// - async addBatch(tasks): add multiple tasks efficiently

// TODO: Implement Worker class
// - constructor(client, name): store client and consumer name
// - async start(): create group if needed, loop reading messages
// - async processMessage(id, fields): simulate work (random 50-200ms)
// - async claimStale(): find and reclaim pending messages older than CLAIM_TIMEOUT_MS
// - async moveToDLQ(id, fields): XADD to dead letter stream, XACK original
// - async stop(): graceful shutdown

// TODO: Implement Dashboard
// - async printStatus(client): show stream length, pending, DLQ count, processed

async function main() {
  const host = process.env.VALKEY_HOST || "localhost";
  const port = parseInt(process.env.VALKEY_PORT || "6379");

  console.log(`Connecting to ${host}:${port}...`);

  // TODO: Create GlideClient connection

  // TODO: Create TaskQueue, add 100 tasks with priorities (high/medium/low)

  // TODO: Start 3 workers concurrently

  // TODO: Print dashboard every 5 seconds

  // TODO: Handle SIGTERM/SIGINT for graceful shutdown

  console.log("Queue system not yet implemented");
  process.exit(1);
}

main().catch(console.error);
