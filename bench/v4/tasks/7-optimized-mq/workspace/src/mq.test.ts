import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import { GlideClient } from "@valkey/valkey-glide";
import { WorkQueue, DistributedLock, RateLimiter } from "./mq.js";

const PORT = 6507;
let client: GlideClient;

beforeAll(async () => {
  client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: PORT }],
  });
});

afterAll(async () => {
  client.close();
});

beforeEach(async () => {
  await client.customCommand(["FLUSHDB"]);
});

// ============================================================
// DistributedLock
// ============================================================

describe("DistributedLock", () => {
  it("acquire and release a lock", async () => {
    const lock = new DistributedLock(client);

    const acquired = await lock.acquire("test-resource", 5000);
    expect(acquired).toBe(true);

    const released = await lock.release("test-resource");
    expect(released).toBe(true);

    // Key should be gone after release
    const val = await client.get("lock:test-resource");
    expect(val).toBeNull();
  });

  it("release is atomic - uses Lua check-and-delete", async () => {
    const lock1 = new DistributedLock(client);
    const lock2 = new DistributedLock(client);

    // lock1 acquires
    await lock1.acquire("shared", 5000);

    // lock1's lock expires, lock2 acquires
    await client.del(["lock:shared"]);
    await lock2.acquire("shared", 5000);

    // lock1 tries to release - should fail because lock2 now owns it
    const released = await lock1.release("shared");
    expect(released).toBe(false);

    // lock2's lock should still be held
    const val = await client.get("lock:shared");
    expect(val).not.toBeNull();

    // lock2 can release
    const released2 = await lock2.release("shared");
    expect(released2).toBe(true);
  });

  it("prevents double-acquire", async () => {
    const lock1 = new DistributedLock(client);
    const lock2 = new DistributedLock(client);

    const first = await lock1.acquire("exclusive", 5000);
    expect(first).toBe(true);

    const second = await lock2.acquire("exclusive", 5000);
    expect(second).toBe(false);

    await lock1.release("exclusive");
  });

  it("extend refreshes TTL", async () => {
    const lock = new DistributedLock(client);

    await lock.acquire("extend-test", 1000);

    const extended = await lock.extend("extend-test", 10000);
    expect(extended).toBe(true);

    // TTL should be refreshed (close to 10000ms)
    const ttl = await client.pttl("lock:extend-test");
    expect(ttl).toBeGreaterThan(5000);

    await lock.release("extend-test");
  });

  it("extend fails if lock not held", async () => {
    const lock = new DistributedLock(client);
    const extended = await lock.extend("not-held", 5000);
    expect(extended).toBe(false);
  });
});

// ============================================================
// WorkQueue
// ============================================================

describe("WorkQueue", () => {
  it("enqueue and dequeue round-trip", async () => {
    const queue = new WorkQueue(client, "test:jobs", "workers");

    const jobId = await queue.enqueue({
      name: "send-email",
      data: { to: "user@example.com", subject: "Hello" },
    });
    expect(jobId).toBeTruthy();
    expect(typeof jobId).toBe("string");

    const messages = await queue.dequeue("consumer1", 10, 1000);
    expect(messages.length).toBe(1);
    expect(messages[0].id).toBe(jobId);
    expect(messages[0].fields["name"]).toBe("send-email");
    expect(messages[0].fields["to"]).toBe("user@example.com");
  });

  it("consumer groups distribute work", async () => {
    const queue = new WorkQueue(client, "test:distributed", "workers");

    // Enqueue 4 jobs
    for (let i = 0; i < 4; i++) {
      await queue.enqueue({ name: `job-${i}`, data: { index: String(i) } });
    }

    // Two consumers each read 2
    const batch1 = await queue.dequeue("consumer-a", 2, 1000);
    const batch2 = await queue.dequeue("consumer-b", 2, 1000);

    expect(batch1.length).toBe(2);
    expect(batch2.length).toBe(2);

    // No overlap
    const ids1 = batch1.map((m) => m.id);
    const ids2 = batch2.map((m) => m.id);
    for (const id of ids1) {
      expect(ids2).not.toContain(id);
    }
  });

  it("ack removes from pending", async () => {
    const queue = new WorkQueue(client, "test:ack", "workers");

    const jobId = await queue.enqueue({
      name: "ack-test",
      data: { value: "1" },
    });
    await queue.dequeue("consumer1", 1, 1000);

    // Before ack - should be in pending
    const pendingBefore = await client.xpending("test:ack", "workers");
    expect(Number(pendingBefore[0])).toBe(1);

    await queue.ack(jobId);

    // After ack - should not be in pending
    const pendingAfter = await client.xpending("test:ack", "workers");
    expect(Number(pendingAfter[0])).toBe(0);
  });

  it("retry moves failed jobs to dead-letter", async () => {
    const queue = new WorkQueue(client, "test:retry", "workers");

    const jobId = await queue.enqueue({
      name: "failing-job",
      data: { value: "x" },
    });

    // Read the message multiple times to simulate retries (increment delivery count)
    // First read delivers the message
    await queue.dequeue("consumer1", 1, 1000);

    // Claim and re-deliver to increment the delivery counter
    for (let i = 0; i < 3; i++) {
      await client.xclaim("test:retry", "workers", "consumer1", 0, [jobId], {
        retryCount: i + 2,
        isForce: true,
      });
    }

    // Now delivery count should be >= 4, retry with maxRetries=3 should move it
    const moved = await queue.retry(3);
    expect(moved).toBeGreaterThanOrEqual(1);

    // Check dead-letter stream has the job
    const dlLen = await client.xlen("test:retry:dead-letter");
    expect(dlLen).toBeGreaterThanOrEqual(1);
  });
});

// ============================================================
// RateLimiter
// ============================================================

describe("RateLimiter", () => {
  it("allows up to max requests", async () => {
    const limiter = new RateLimiter(client);

    for (let i = 0; i < 5; i++) {
      const allowed = await limiter.isAllowed("api:user1", 5, 10000);
      expect(allowed).toBe(true);
    }
  });

  it("blocks after max requests", async () => {
    const limiter = new RateLimiter(client);

    // Use up the limit
    for (let i = 0; i < 3; i++) {
      await limiter.isAllowed("api:user2", 3, 10000);
    }

    // Next request should be blocked
    const blocked = await limiter.isAllowed("api:user2", 3, 10000);
    expect(blocked).toBe(false);
  });

  it("window slides - old requests expire", async () => {
    const limiter = new RateLimiter(client);
    const windowMs = 500;

    // Use up the limit
    for (let i = 0; i < 3; i++) {
      await limiter.isAllowed("api:user3", 3, windowMs);
    }

    // Should be blocked
    const blocked = await limiter.isAllowed("api:user3", 3, windowMs);
    expect(blocked).toBe(false);

    // Wait for window to slide
    await new Promise((resolve) => setTimeout(resolve, windowMs + 100));

    // Should be allowed again
    const allowed = await limiter.isAllowed("api:user3", 3, windowMs);
    expect(allowed).toBe(true);
  });
});
