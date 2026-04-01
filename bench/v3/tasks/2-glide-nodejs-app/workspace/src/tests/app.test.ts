import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import {
    GlideClusterClient,
    GlideClusterClientConfiguration,
} from "@valkey/valkey-glide";
import {
    scanAllKeys,
    atomicIncrWithExpire,
    checkRateLimit,
    setupShardedPubSub,
} from "../app.js";

const CLUSTER_ADDRESSES = [
    { host: "localhost", port: 7000 },
    { host: "localhost", port: 7001 },
    { host: "localhost", port: 7002 },
];

let client: GlideClusterClient;

beforeAll(async () => {
    client = await GlideClusterClient.createClient({
        addresses: CLUSTER_ADDRESSES,
    });
});

afterAll(async () => {
    client?.close();
});

beforeEach(async () => {
    // Flush all data between tests
    await client.customCommand(["FLUSHALL"]);
});

// -- A. Cluster-Wide Key Scanner --

describe("scanAllKeys", () => {
    it("should return all keys matching pattern across the cluster", async () => {
        // Seed keys across multiple hash slots to ensure cluster spread
        for (let i = 0; i < 20; i++) {
            await client.set(`scan-test:key:${i}`, `value-${i}`);
        }
        // Add some keys that should NOT match
        await client.set("other:key:1", "no-match");
        await client.set("other:key:2", "no-match");

        const keys = await scanAllKeys(client, "scan-test:*");

        expect(keys).toHaveLength(20);
        expect(keys.sort()).toEqual(
            Array.from({ length: 20 }, (_, i) => `scan-test:key:${i}`).sort(),
        );
    });

    it("should return empty array when no keys match", async () => {
        await client.set("existing:key", "value");

        const keys = await scanAllKeys(client, "nonexistent:*");

        expect(keys).toHaveLength(0);
    });
});

// -- B. Atomic Check-and-Increment with HEXPIRE --

describe("atomicIncrWithExpire", () => {
    it("should initialize field to 1 on first call", async () => {
        const result = await atomicIncrWithExpire(client, "hash:test1", "counter", 60);

        expect(result).toBe(1);

        // Verify the field exists with value "1"
        const value = await client.hget("hash:test1", "counter");
        expect(value).toBe("1");
    });

    it("should increment existing field", async () => {
        await atomicIncrWithExpire(client, "hash:test2", "counter", 60);
        await atomicIncrWithExpire(client, "hash:test2", "counter", 60);
        const result = await atomicIncrWithExpire(client, "hash:test2", "counter", 60);

        expect(result).toBe(3);
    });

    it("should set per-field TTL via HEXPIRE", async () => {
        await atomicIncrWithExpire(client, "hash:test3", "counter", 10);

        // Check that the field has a TTL set (HTTL returns seconds remaining)
        const ttlResult = await client.customCommand([
            "HTTL", "hash:test3", "FIELDS", "1", "counter",
        ]);

        // HTTL returns an array of TTL values; the field should have TTL > 0
        expect(Array.isArray(ttlResult)).toBe(true);
        const ttl = (ttlResult as number[])[0];
        expect(ttl).toBeGreaterThan(0);
        expect(ttl).toBeLessThanOrEqual(10);
    });
});

// -- C. Sliding Window Rate Limiter --

describe("checkRateLimit", () => {
    it("should allow requests within the limit", async () => {
        const result = await checkRateLimit(client, "rate:user:1", 60, 10);

        expect(result.allowed).toBe(true);
        expect(result.remaining).toBeGreaterThanOrEqual(0);
        expect(result.remaining).toBeLessThanOrEqual(10);
    });

    it("should deny requests exceeding the limit", async () => {
        const key = "rate:user:2";
        // Send maxRequests requests
        for (let i = 0; i < 5; i++) {
            await checkRateLimit(client, key, 60, 5);
        }

        // The next request should be denied
        const result = await checkRateLimit(client, key, 60, 5);

        expect(result.allowed).toBe(false);
        expect(result.remaining).toBe(0);
    });

    it("should report correct remaining count", async () => {
        const key = "rate:user:3";
        const maxRequests = 10;

        const first = await checkRateLimit(client, key, 60, maxRequests);
        expect(first.allowed).toBe(true);
        expect(first.remaining).toBe(maxRequests - 1);

        const second = await checkRateLimit(client, key, 60, maxRequests);
        expect(second.allowed).toBe(true);
        expect(second.remaining).toBe(maxRequests - 2);
    });
});

// -- D. Sharded Pub/Sub Notification System --

describe("setupShardedPubSub", () => {
    it("should receive messages on sharded channel", async () => {
        const received: string[] = [];
        const channel = "notifications:{shard1}";

        const subscriber = await setupShardedPubSub(
            client,
            channel,
            (msg) => received.push(msg),
        );

        try {
            // Small delay to let subscription establish
            await new Promise((r) => setTimeout(r, 500));

            // Publish to the sharded channel
            await client.publish("hello-sharded", channel, true);

            // Wait for message delivery
            await new Promise((r) => setTimeout(r, 1000));

            expect(received).toContain("hello-sharded");
        } finally {
            subscriber.close();
        }
    });
});
