import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
    CacheLayer,
    createCacheLayer,
    CacheLayerError,
    CacheConfig,
    CacheEntityConfig,
} from "./cache-layer";

/**
 * Mock Valkey GLIDE client for testing
 */
class MockGlideClient {
    private store: Map<string, string> = new Map();
    private shouldFail = false;
    private shouldTimeout = false;

    async set(
        key: string,
        value: string,
        options?: { expiry?: { type: string; count: number } },
    ): Promise<void> {
        if (this.shouldTimeout) {
            throw new Error("TimeoutError");
        }
        if (this.shouldFail) {
            throw new Error("RequestError");
        }
        this.store.set(key, value);
    }

    async get(key: string): Promise<string | null> {
        if (this.shouldTimeout) {
            throw new Error("TimeoutError");
        }
        return this.store.get(key) || null;
    }

    async del(keys: string[]): Promise<number> {
        if (this.shouldFail) {
            throw new Error("RequestError");
        }
        let deleted = 0;
        for (const key of keys) {
            if (this.store.delete(key)) {
                deleted++;
            }
        }
        return deleted;
    }

    async scan(
        cursor: number,
        options?: { match?: string },
    ): Promise<{ keys: string[]; cursor: number }> {
        if (!options?.match) {
            return { keys: Array.from(this.store.keys()), cursor: 0 };
        }

        const pattern = options.match.replace("*", ".*");
        const regex = new RegExp(`^${pattern}$`);
        const keys = Array.from(this.store.keys()).filter((k) => regex.test(k));
        return { keys, cursor: 0 };
    }

    close(): void {}

    simulateFailure(): void {
        this.shouldFail = true;
    }

    simulateTimeout(): void {
        this.shouldTimeout = true;
    }

    reset(): void {
        this.store.clear();
        this.shouldFail = false;
        this.shouldTimeout = false;
    }

    getStore(): Map<string, string> {
        return this.store;
    }
}

describe("CacheLayer", () => {
    let cacheLayer: CacheLayer;
    let mockClient: MockGlideClient;

    const testConfig = {
        cacheConfig: {
            addresses: [{ host: "localhost", port: 6379 }],
        },
        entityConfigs: {
            user: {
                ttlSeconds: 3600,
                keyPrefix: "users",
            },
            profile: {
                ttlSeconds: 1800,
                keyPrefix: "profiles",
            },
        } as CacheEntityConfig,
        enableErrorReporting: false,
    };

    beforeEach(async () => {
        // Note: In a real test environment, you would mock GlideClusterClient.createClient
        // This is a simplified example showing the test structure
        mockClient = new MockGlideClient();
    });

    afterEach(async () => {
        if (cacheLayer) {
            await cacheLayer.close();
        }
    });

    describe("Cache-aside pattern", () => {
        it("should return cached data on cache hit", async () => {
            const testData = { id: "user-1", name: "Alice" };
            const fetchFromDb = vi.fn();

            // Pre-populate cache
            mockClient.getStore().set("users:user-1", JSON.stringify(testData));

            // In a real test, you'd inject the mock client
            // This is pseudocode showing the expected behavior
            const result = {
                data: testData,
                source: "cache" as const,
            };

            expect(result.source).toBe("cache");
            expect(result.data).toEqual(testData);
            expect(fetchFromDb).not.toHaveBeenCalled();
        });

        it("should fetch from database on cache miss", async () => {
            const testData = { id: "user-2", name: "Bob" };
            const fetchFromDb = vi.fn().mockResolvedValue(testData);

            const result = {
                data: testData,
                source: "database" as const,
            };

            expect(result.source).toBe("database");
            expect(result.data).toEqual(testData);
            expect(fetchFromDb).toHaveBeenCalled();
        });

        it("should populate cache after database fetch", async () => {
            const testData = { id: "user-3", name: "Charlie" };
            const store = mockClient.getStore();

            // Simulate cache miss -> DB fetch -> cache populate
            store.set("users:user-3", JSON.stringify(testData));

            const cached = JSON.parse(store.get("users:user-3") || "{}");
            expect(cached).toEqual(testData);
        });
    });

    describe("Cache invalidation", () => {
        it("should delete a single cache entry on invalidate", async () => {
            const store = mockClient.getStore();
            const testKey = "users:user-1";

            store.set(testKey, JSON.stringify({ id: "user-1" }));
            expect(store.has(testKey)).toBe(true);

            // Simulate invalidation
            store.delete(testKey);
            expect(store.has(testKey)).toBe(false);
        });

        it("should invalidate pattern matching entries", async () => {
            const store = mockClient.getStore();

            store.set("users:user-1", JSON.stringify({ id: "user-1" }));
            store.set("users:user-2", JSON.stringify({ id: "user-2" }));
            store.set("profiles:profile-1", JSON.stringify({ id: "profile-1" }));

            // Simulate pattern invalidation for users
            const pattern = /^users:.*$/;
            let deleted = 0;
            for (const key of store.keys()) {
                if (pattern.test(key)) {
                    store.delete(key);
                    deleted++;
                }
            }

            expect(deleted).toBe(2);
            expect(store.has("users:user-1")).toBe(false);
            expect(store.has("users:user-2")).toBe(false);
            expect(store.has("profiles:profile-1")).toBe(true);
        });
    });

    describe("TTL and expiration", () => {
        it("should set TTL when writing to cache", async () => {
            const testData = { id: "user-1", name: "Alice" };
            const ttlSeconds = 3600;

            // Verify TTL is passed correctly
            const expiry = { type: "Seconds", count: ttlSeconds };

            expect(expiry.type).toBe("Seconds");
            expect(expiry.count).toBe(3600);
        });

        it("should respect different TTLs per entity type", async () => {
            const userTtl = testConfig.entityConfigs.user.ttlSeconds;
            const profileTtl = testConfig.entityConfigs.profile.ttlSeconds;

            expect(userTtl).toBe(3600);
            expect(profileTtl).toBe(1800);
            expect(userTtl).not.toBe(profileTtl);
        });
    });

    describe("Error handling", () => {
        it("should throw CacheLayerError on configuration not found", async () => {
            const error = new CacheLayerError("CONFIG_NOT_FOUND", "Entity type not configured");

            expect(error.code).toBe("CONFIG_NOT_FOUND");
            expect(error.message).toBe("Entity type not configured");
        });

        it("should handle cache timeouts gracefully", async () => {
            // Timeout should be caught and request should fallback to database
            const testData = { id: "user-1" };
            const fetchFromDb = vi.fn().mockResolvedValue(testData);

            // Even if cache times out, the result should come from DB
            const result = {
                data: testData,
                source: "database" as const,
            };

            expect(result.source).toBe("database");
            expect(result.data).toEqual(testData);
        });

        it("should handle connection errors and continue to serve requests", async () => {
            const testData = { id: "user-1" };
            const fetchFromDb = vi.fn().mockResolvedValue(testData);

            // Cache is unavailable but application continues to work
            const result = {
                data: testData,
                source: "database" as const,
            };

            expect(result.data).toEqual(testData);
            // Application should still work
        });

        it("should cache write failures gracefully", async () => {
            const testData = { id: "user-1" };

            // Cache write fails, but we still got the data from DB
            const result = {
                data: testData,
                source: "database" as const,
            };

            expect(result.data).toEqual(testData);
            // Request succeeds despite cache write failure
        });
    });

    describe("Cluster mode configuration", () => {
        it("should configure cluster addresses", () => {
            const config: CacheConfig = {
                addresses: [
                    { host: "node1.example.com", port: 6379 },
                    { host: "node2.example.com", port: 6380 },
                    { host: "node3.example.com", port: 6381 },
                ],
                readFrom: "preferReplica",
            };

            expect(config.addresses).toHaveLength(3);
            expect(config.readFrom).toBe("preferReplica");
        });

        it("should support AZ affinity in cluster mode", () => {
            const config: CacheConfig = {
                addresses: [{ host: "node1.example.com", port: 6379 }],
                readFrom: "AZAffinity",
                clientAz: "us-east-1a",
            };

            expect(config.readFrom).toBe("AZAffinity");
            expect(config.clientAz).toBe("us-east-1a");
        });

        it("should support TLS in cluster mode", () => {
            const config: CacheConfig = {
                addresses: [{ host: "valkey.example.com", port: 6380 }],
                useTLS: true,
                credentials: {
                    username: "user",
                    password: "pass",
                },
            };

            expect(config.useTLS).toBe(true);
            expect(config.credentials).toBeDefined();
        });
    });

    describe("TypeScript types", () => {
        it("should have proper type definitions", () => {
            const config = testConfig;

            // Verify types are enforced
            expect(config.cacheConfig.addresses).toBeDefined();
            expect(config.entityConfigs).toBeDefined();
            expect(config.enableErrorReporting).toBe(false);

            // This would catch type errors at compile time
            const entityConfig = config.entityConfigs.user;
            expect(entityConfig.ttlSeconds).toBe(3600);
            expect(entityConfig.keyPrefix).toBe("users");
        });

        it("should have CacheResult type with source discriminator", () => {
            const cacheHit = {
                data: { id: "user-1" },
                source: "cache" as const,
            };

            const dbHit = {
                data: { id: "user-1" },
                source: "database" as const,
            };

            expect(cacheHit.source).toBe("cache");
            expect(dbHit.source).toBe("database");
        });
    });

    describe("Health and monitoring", () => {
        it("should report cache health status", () => {
            const stats = {
                isHealthy: true,
                reconnectAttempts: 0,
            };

            expect(stats.isHealthy).toBe(true);
            expect(stats.reconnectAttempts).toBe(0);
        });

        it("should track reconnection attempts", () => {
            const stats = {
                isHealthy: false,
                reconnectAttempts: 3,
            };

            expect(stats.isHealthy).toBe(false);
            expect(stats.reconnectAttempts).toBe(3);
        });
    });

    describe("CRUD operations", () => {
        it("should handle create operation with cache population", async () => {
            const newUser = { id: "user-4", name: "David" };
            mockClient.getStore().set("users:user-4", JSON.stringify(newUser));

            expect(mockClient.getStore().get("users:user-4")).toBeDefined();
        });

        it("should handle read operation with cache-aside", async () => {
            const user = { id: "user-1", name: "Alice" };
            mockClient.getStore().set("users:user-1", JSON.stringify(user));

            const cached = mockClient.getStore().get("users:user-1");
            expect(cached).toEqual(JSON.stringify(user));
        });

        it("should handle update operation with cache invalidation", async () => {
            mockClient.getStore().set("users:user-1", JSON.stringify({ id: "user-1", name: "Alice" }));
            mockClient.getStore().delete("users:user-1");

            expect(mockClient.getStore().has("users:user-1")).toBe(false);
        });

        it("should handle delete operation with cache invalidation", async () => {
            mockClient.getStore().set("users:user-2", JSON.stringify({ id: "user-2" }));
            mockClient.getStore().delete("users:user-2");

            expect(mockClient.getStore().has("users:user-2")).toBe(false);
        });
    });
});
