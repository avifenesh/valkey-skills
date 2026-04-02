import { GlideClient } from "@valkey/valkey-glide";
import { WorkQueue, DistributedLock, RateLimiter } from "./mq.js";

const PORT = 6507;
const ITERATIONS = 2000;

async function main() {
  const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: PORT }],
  });

  await client.customCommand(["FLUSHDB"]);

  console.log(`Benchmark: ${ITERATIONS} iterations\n`);

  // --- WorkQueue enqueue ---
  const queue = new WorkQueue(client, "bench:queue", "bench-workers");
  const enqueueStart = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    await queue.enqueue({
      name: `job-${i}`,
      data: { index: String(i), payload: "benchmark-data" },
    });
  }
  const enqueueMs = performance.now() - enqueueStart;
  const enqueueOps = Math.round((ITERATIONS / enqueueMs) * 1000);
  console.log(
    `WorkQueue.enqueue: ${enqueueMs.toFixed(1)}ms total, ${enqueueOps} ops/sec`
  );

  // --- WorkQueue dequeue ---
  const dequeueStart = performance.now();
  let dequeued = 0;
  while (dequeued < ITERATIONS) {
    const msgs = await queue.dequeue(
      "bench-consumer",
      Math.min(100, ITERATIONS - dequeued),
      100
    );
    for (const msg of msgs) {
      await queue.ack(msg.id);
    }
    dequeued += msgs.length;
    if (msgs.length === 0) break;
  }
  const dequeueMs = performance.now() - dequeueStart;
  const dequeueOps = Math.round((dequeued / dequeueMs) * 1000);
  console.log(
    `WorkQueue.dequeue+ack: ${dequeueMs.toFixed(1)}ms total, ${dequeueOps} ops/sec (${dequeued} messages)`
  );

  // --- DistributedLock ---
  const lock = new DistributedLock(client);
  const lockStart = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    await lock.acquire(`bench-lock-${i}`, 5000);
    await lock.release(`bench-lock-${i}`);
  }
  const lockMs = performance.now() - lockStart;
  const lockOps = Math.round((ITERATIONS / lockMs) * 1000);
  console.log(
    `DistributedLock acquire+release: ${lockMs.toFixed(1)}ms total, ${lockOps} ops/sec`
  );

  // --- RateLimiter ---
  const limiter = new RateLimiter(client);
  const rlStart = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    await limiter.isAllowed(`bench-key-${i % 100}`, 1000, 60000);
  }
  const rlMs = performance.now() - rlStart;
  const rlOps = Math.round((ITERATIONS / rlMs) * 1000);
  console.log(
    `RateLimiter.isAllowed: ${rlMs.toFixed(1)}ms total, ${rlOps} ops/sec`
  );

  console.log("\n--- Summary ---");
  console.log(`Enqueue:     ${enqueueOps} ops/sec`);
  console.log(`Dequeue+Ack: ${dequeueOps} ops/sec`);
  console.log(`Lock cycle:  ${lockOps} ops/sec`);
  console.log(`Rate check:  ${rlOps} ops/sec`);

  const allAbove1k =
    enqueueOps >= 1000 &&
    dequeueOps >= 1000 &&
    lockOps >= 1000 &&
    rlOps >= 1000;
  console.log(
    `\nAll above 1000 ops/sec: ${allAbove1k ? "YES" : "NO - below target"}`
  );

  client.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
