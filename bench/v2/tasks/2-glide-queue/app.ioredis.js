/**
 * Working ioredis application - DO NOT MODIFY THIS FILE
 * This is the reference implementation. Migrate to GLIDE in app.js
 */
import Redis from "ioredis";

const cluster = new Redis.Cluster([
  { host: "valkey-1", port: 7101 },
  { host: "valkey-2", port: 7102 },
  { host: "valkey-3", port: 7103 },
]);

// === Feature 1: Cache with TTL ===
async function cacheOperations() {
  await cluster.set("{cache}:user:1", JSON.stringify({ name: "Alice", role: "admin" }), "EX", 3600);
  await cluster.set("{cache}:user:2", JSON.stringify({ name: "Bob", role: "user" }), "EX", 3600);

  const users = await cluster.mget("{cache}:user:1", "{cache}:user:2");
  console.log("Cached users:", users.map(u => u ? JSON.parse(u) : null));

  const wasSet = await cluster.set("{cache}:lock:resource1", "owner-abc", "NX", "EX", 30);
  console.log("Lock acquired:", wasSet === "OK");

  return users.filter(Boolean).length;
}

// === Feature 2: Pub/Sub with pattern subscriptions ===
async function pubsubOperations() {
  const subscriber = cluster.duplicate();

  return new Promise((resolve) => {
    let received = 0;

    subscriber.on("pmessage", (pattern, channel, message) => {
      console.log(`PubSub [${pattern}] ${channel}: ${message}`);
      received++;
      if (received >= 2) {
        subscriber.punsubscribe("events:*");
        subscriber.quit();
        resolve(received);
      }
    });

    subscriber.psubscribe("events:*", () => {
      setTimeout(async () => {
        await cluster.publish("events:order", JSON.stringify({ orderId: 123, status: "placed" }));
        await cluster.publish("events:inventory", JSON.stringify({ sku: "ABC", delta: -1 }));
      }, 100);
    });
  });
}

// === Feature 3: Pipeline / Batch operations ===
async function batchOperations() {
  const pipeline = cluster.pipeline();

  for (let i = 0; i < 50; i++) {
    pipeline.hset(`{product}:${i}`, {
      name: `Product ${i}`,
      price: String((i + 1) * 9.99),
      stock: String(100 - i),
    });
  }

  const results = await pipeline.exec();
  const successCount = results.filter(([err]) => !err).length;
  console.log(`Batch wrote ${successCount}/50 products`);

  const readPipeline = cluster.pipeline();
  for (let i = 0; i < 10; i++) {
    readPipeline.hgetall(`{product}:${i}`);
  }
  const products = await readPipeline.exec();
  console.log("First product:", products[0][1]);

  return successCount;
}

// === Feature 4: Streams with consumer groups ===
async function streamOperations() {
  const streamKey = "{stream}:tasks";
  const groupName = "workers";

  try {
    await cluster.xgroup("CREATE", streamKey, groupName, "$", "MKSTREAM");
  } catch (e) {
    if (!e.message.includes("BUSYGROUP")) throw e;
  }

  for (let i = 0; i < 10; i++) {
    await cluster.xadd(streamKey, "*", "task", `job-${i}`, "priority", i < 3 ? "high" : "normal");
  }

  const messages = await cluster.xreadgroup(
    "GROUP", groupName, "worker-1",
    "COUNT", 5,
    "STREAMS", streamKey, ">"
  );

  let consumed = 0;
  if (messages) {
    for (const [stream, entries] of messages) {
      for (const [id, fields] of entries) {
        console.log(`Stream consumed: ${id} -> ${fields}`);
        await cluster.xack(streamKey, groupName, id);
        consumed++;
      }
    }
  }

  const info = await cluster.xinfo("STREAM", streamKey);
  console.log("Stream length:", info[1]);

  return consumed;
}

// === Feature 5: Sorted set operations ===
async function sortedSetOperations() {
  const members = [];
  for (let i = 0; i < 20; i++) {
    members.push(Math.random() * 1000, `player:${i}`);
  }
  await cluster.zadd("leaderboard:daily", ...members);

  const top5 = await cluster.zrevrange("leaderboard:daily", 0, 4, "WITHSCORES");
  console.log("Top 5:", top5);

  const rank = await cluster.zrevrank("leaderboard:daily", "player:5");
  console.log("Player 5 rank:", rank);

  const highScorers = await cluster.zrangebyscore("leaderboard:daily", 500, "+inf", "WITHSCORES");
  console.log("High scorers:", highScorers.length / 2);

  return top5.length / 2;
}

// === Main ===
async function main() {
  console.log("=== ioredis Reference Implementation ===\n");

  const results = {};

  results.cache = await cacheOperations();
  console.log(`\nCache: ${results.cache} users cached\n`);

  results.pubsub = await pubsubOperations();
  console.log(`\nPubSub: ${results.pubsub} messages received\n`);

  results.batch = await batchOperations();
  console.log(`\nBatch: ${results.batch} products written\n`);

  results.streams = await streamOperations();
  console.log(`\nStreams: ${results.streams} messages consumed\n`);

  results.sortedSets = await sortedSetOperations();
  console.log(`\nSorted sets: ${results.sortedSets} top players\n`);

  console.log("\n=== Results ===");
  console.log(JSON.stringify(results, null, 2));

  await cluster.quit();
  process.exit(0);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
