import express, { Request, Response, NextFunction } from "express";
import { createCacheLayer, CacheLayer, CacheLayerError } from "./cache-layer";

/**
 * User profile data model
 */
interface UserProfile {
    id: string;
    name: string;
    email: string;
    age: number;
    createdAt: Date;
    updatedAt: Date;
}

/**
 * Mock database layer (replace with actual DB calls)
 */
class UserDatabase {
    private users: Map<string, UserProfile> = new Map();

    async getUserById(id: string): Promise<UserProfile | null> {
        // Simulate DB latency
        await new Promise((resolve) => setTimeout(resolve, 50));

        const user = this.users.get(id);
        return user || null;
    }

    async createUser(user: UserProfile): Promise<UserProfile> {
        await new Promise((resolve) => setTimeout(resolve, 100));
        this.users.set(user.id, user);
        return user;
    }

    async updateUser(id: string, updates: Partial<UserProfile>): Promise<UserProfile | null> {
        await new Promise((resolve) => setTimeout(resolve, 75));

        const user = this.users.get(id);
        if (!user) return null;

        const updated = { ...user, ...updates, updatedAt: new Date() };
        this.users.set(id, updated);
        return updated;
    }

    async deleteUser(id: string): Promise<boolean> {
        await new Promise((resolve) => setTimeout(resolve, 50));
        return this.users.delete(id);
    }
}

/**
 * Initialize cache layer with entity configurations
 */
async function initializeCacheLayer(): Promise<CacheLayer> {
    return createCacheLayer({
        cacheConfig: {
            addresses: [
                { host: "localhost", port: 6379 },
                { host: "localhost", port: 6380 },
            ],
            readFrom: "preferReplica",
            requestTimeout: 5000,
            clientName: "user-api-cache",
        },
        entityConfigs: {
            user: {
                ttlSeconds: 3600, // 1 hour
                keyPrefix: "users",
            },
            userProfile: {
                ttlSeconds: 1800, // 30 minutes
                keyPrefix: "user:profile",
            },
        },
        enableErrorReporting: true,
    });
}

/**
 * Express app setup with cache-aside route handlers
 */
async function setupExpressApp(): Promise<express.Application> {
    const app = express();
    const db = new UserDatabase();

    // Initialize cache before registering routes. createCacheLayer never throws -
    // on Valkey failure it returns a degraded instance and the app starts anyway.
    const cache = await initializeCacheLayer();
    if (cache.isHealthy()) {
        console.log("[OK] Cache layer initialized");
    } else {
        console.warn("[WARN] Cache layer started in degraded mode - operating without cache");
    }

    // Middleware
    app.use(express.json());

    /**
     * GET /users/:id - Retrieve a user with cache-aside pattern
     */
    app.get("/users/:id", async (req: Request, res: Response, next: NextFunction) => {
        try {
            const { id } = req.params;

            // Cache-aside: getWithFallback checks isHealthy() internally and bypasses
            // cache when Valkey is unavailable, so no explicit guard needed here.
            const result = await cache.getWithFallback(
                "user",
                id,
                async () => {
                    const user = await db.getUserById(id);
                    if (!user) {
                        throw new Error(`User ${id} not found`);
                    }
                    return user;
                },
            );

            res.json({
                data: result.data,
                source: result.source,
            });
        } catch (error) {
            if (error instanceof Error && error.message.includes("not found")) {
                res.status(404).json({ error: error.message });
            } else {
                next(error);
            }
        }
    });

    /**
     * POST /users - Create a new user
     */
    app.post("/users", async (req: Request, res: Response, next: NextFunction) => {
        try {
            const user: UserProfile = {
                id: `user-${Date.now()}`,
                name: req.body.name,
                email: req.body.email,
                age: req.body.age,
                createdAt: new Date(),
                updatedAt: new Date(),
            };

            const created = await db.createUser(user);

            // Warm cache with new user (setWithTtl is a no-op if cache is degraded)
            await cache.setWithTtl("user", created.id, created);

            res.status(201).json({
                data: created,
                message: "User created successfully",
            });
        } catch (error) {
            next(error);
        }
    });

    /**
     * PUT /users/:id - Update a user (invalidate cache on write)
     */
    app.put("/users/:id", async (req: Request, res: Response, next: NextFunction) => {
        try {
            const { id } = req.params;

            const updated = await db.updateUser(id, {
                name: req.body.name,
                email: req.body.email,
                age: req.body.age,
            });

            if (!updated) {
                return res.status(404).json({ error: `User ${id} not found` });
            }

            // Invalidate stale cache entry (no-op if cache is degraded)
            await cache.invalidate("user", id);

            res.json({
                data: updated,
                message: "User updated successfully",
            });
        } catch (error) {
            next(error);
        }
    });

    /**
     * DELETE /users/:id - Delete a user (invalidate cache on delete)
     */
    app.delete("/users/:id", async (req: Request, res: Response, next: NextFunction) => {
        try {
            const { id } = req.params;

            const deleted = await db.deleteUser(id);

            if (!deleted) {
                return res.status(404).json({ error: `User ${id} not found` });
            }

            // Invalidate cache entry (no-op if cache is degraded)
            await cache.invalidate("user", id);

            res.json({
                message: "User deleted successfully",
            });
        } catch (error) {
            next(error);
        }
    });

    /**
     * DELETE /cache/invalidate/:entityType - Manual cache invalidation (pattern)
     */
    app.delete(
        "/cache/invalidate/:entityType",
        async (req: Request, res: Response, next: NextFunction) => {
            try {
                const { entityType } = req.params;

                if (!cache.isHealthy()) {
                    return res.status(503).json({ error: "Cache unavailable" });
                }

                const invalidated = await cache.invalidatePattern(entityType);

                res.json({
                    message: `Invalidated ${invalidated} entries of type ${entityType}`,
                    count: invalidated,
                });
            } catch (error) {
                if (error instanceof CacheLayerError) {
                    res.status(400).json({ error: error.message });
                } else {
                    next(error);
                }
            }
        },
    );

    /**
     * GET /cache/health - Cache health check endpoint
     */
    app.get("/cache/health", async (_req: Request, res: Response) => {
        const stats = await cache.getStats();
        res.status(stats.isHealthy ? 200 : 503).json({
            status: stats.isHealthy ? "healthy" : "degraded",
            ...stats,
        });
    });

    /**
     * Error handling middleware
     */
    app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
        console.error("[ERROR]", err.message);

        if (err instanceof CacheLayerError) {
            return res.status(500).json({
                error: err.code,
                message: err.message,
            });
        }

        res.status(500).json({
            error: "Internal Server Error",
            message: err.message,
        });
    });

    /**
     * Graceful shutdown
     */
    process.on("SIGTERM", async () => {
        console.log("[OK] SIGTERM received, shutting down gracefully");
        await cache.close();
        process.exit(0);
    });

    return app;
}

/**
 * Example usage and testing
 */
async function main(): Promise<void> {
    const app = await setupExpressApp();
    const PORT = 3000;

    const server = app.listen(PORT, () => {
        console.log(`[OK] Server listening on port ${PORT}`);
        console.log(`[OK] Example endpoints:`);
        console.log(`  GET    http://localhost:${PORT}/users/:id`);
        console.log(`  POST   http://localhost:${PORT}/users`);
        console.log(`  PUT    http://localhost:${PORT}/users/:id`);
        console.log(`  DELETE http://localhost:${PORT}/users/:id`);
        console.log(`  GET    http://localhost:${PORT}/cache/health`);
        console.log(`  DELETE http://localhost:${PORT}/cache/invalidate/:entityType`);
    });

    // Graceful shutdown
    process.on("SIGINT", () => {
        console.log("[OK] SIGINT received, closing server");
        server.close(() => {
            console.log("[OK] Server closed");
            process.exit(0);
        });
    });
}

// Run if this is the main module
if (require.main === module) {
    main().catch((error) => {
        console.error("[CRITICAL]", error);
        process.exit(1);
    });
}

export { setupExpressApp, UserDatabase };
