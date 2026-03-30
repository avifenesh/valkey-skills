import {
    GlideClusterClient,
    TimeUnit,
    RequestError,
    TimeoutError,
    ConnectionError,
    ClosingError,
} from "@valkey/valkey-glide";

/**
 * Type definitions for the cache layer
 */

export interface CacheConfig {
    addresses: Array<{ host: string; port: number }>;
    readFrom?: "primary" | "preferReplica" | "AZAffinity" | "AZAffinityReplicasAndPrimary";
    clientAz?: string;
    requestTimeout?: number;
    useTLS?: boolean;
    credentials?: {
        username: string;
        password: string;
    };
    clientName?: string;
}

export interface EntityConfig {
    ttlSeconds: number;
    keyPrefix: string;
}

export interface CacheEntityConfig {
    [entityType: string]: EntityConfig;
}

export interface CacheLayerOptions {
    cacheConfig: CacheConfig;
    entityConfigs: CacheEntityConfig;
    enableErrorReporting?: boolean;
}

export interface CacheResult<T> {
    data: T;
    source: "cache" | "database";
}

/**
 * Error class for cache layer operations
 */
export class CacheLayerError extends Error {
    constructor(
        public readonly code: string,
        message: string,
        public readonly originalError?: Error,
    ) {
        super(message);
        this.name = "CacheLayerError";
    }
}

/**
 * Cache-aside layer for CRUD operations with Valkey GLIDE
 */
export class CacheLayer {
    private client: GlideClusterClient | null = null;
    private config: CacheLayerOptions;
    private isConnected = false;

    constructor(options: CacheLayerOptions) {
        this.config = options;
    }

    /**
     * Initialize the cache layer and connect to Valkey
     */
    async initialize(): Promise<void> {
        try {
            this.client = await GlideClusterClient.createClient({
                addresses: this.config.cacheConfig.addresses,
                readFrom: this.config.cacheConfig.readFrom || "preferReplica",
                clientAz: this.config.cacheConfig.clientAz,
                requestTimeout: this.config.cacheConfig.requestTimeout || 5000,
                useTLS: this.config.cacheConfig.useTLS,
                credentials: this.config.cacheConfig.credentials,
                clientName: this.config.cacheConfig.clientName || "cache-layer",
            });
            this.isConnected = true;
        } catch (error) {
            this.isConnected = false;
            throw new CacheLayerError(
                "INIT_FAILED",
                `Failed to initialize cache layer: ${error instanceof Error ? error.message : String(error)}`,
                error instanceof Error ? error : undefined,
            );
        }
    }

    /**
     * Close the connection to Valkey
     */
    async close(): Promise<void> {
        if (this.client) {
            try {
                this.client.close();
                this.isConnected = false;
            } catch (error) {
                console.error("Error closing cache connection:", error);
            }
        }
    }

    /**
     * Check if cache is currently healthy
     */
    isHealthy(): boolean {
        return this.isConnected && this.client !== null;
    }

    /**
     * Get a value from cache with fallback to database fetch function
     * Implements cache-aside pattern: check cache first, fallback to DB, populate cache
     */
    async getWithFallback<T>(
        entityType: string,
        id: string,
        fetchFromDb: () => Promise<T>,
    ): Promise<CacheResult<T>> {
        const cacheKey = this.buildCacheKey(entityType, id);
        const config = this.config.entityConfigs[entityType];

        if (!config) {
            throw new CacheLayerError(
                "CONFIG_NOT_FOUND",
                `Entity type "${entityType}" not configured`,
            );
        }

        try {
            // Step 1: Try to read from cache
            if (this.isHealthy()) {
                try {
                    const cached = await this.client!.get(cacheKey);
                    if (cached !== null) {
                        return {
                            data: JSON.parse(cached as string),
                            source: "cache",
                        };
                    }
                } catch (error) {
                    if (error instanceof TimeoutError) {
                        if (this.config.enableErrorReporting) {
                            console.warn(`Cache timeout reading ${cacheKey}`);
                        }
                    } else if (error instanceof ConnectionError) {
                        this.handleConnectionError(error);
                    } else if (!(error instanceof ClosingError)) {
                        if (this.config.enableErrorReporting) {
                            console.warn(
                                `Cache read error for ${cacheKey}:`,
                                error instanceof Error ? error.message : String(error),
                            );
                        }
                    }
                }
            }

            // Step 2: Cache miss or cache unavailable - fetch from database
            const data = await fetchFromDb();

            // Step 3: Populate cache (best effort - don't fail the request if cache write fails)
            if (this.isHealthy()) {
                try {
                    await this.setWithTtl(entityType, id, data);
                } catch (error) {
                    if (this.config.enableErrorReporting) {
                        console.warn(
                            `Failed to populate cache for ${cacheKey}:`,
                            error instanceof Error ? error.message : String(error),
                        );
                    }
                }
            }

            return {
                data,
                source: "database",
            };
        } catch (error) {
            throw new CacheLayerError(
                "GET_WITH_FALLBACK_FAILED",
                `Failed to get data for ${entityType}:${id}`,
                error instanceof Error ? error : undefined,
            );
        }
    }

    /**
     * Set a value in cache with TTL
     */
    async setWithTtl<T>(entityType: string, id: string, value: T): Promise<void> {
        const cacheKey = this.buildCacheKey(entityType, id);
        const config = this.config.entityConfigs[entityType];

        if (!config) {
            throw new CacheLayerError(
                "CONFIG_NOT_FOUND",
                `Entity type "${entityType}" not configured`,
            );
        }

        if (!this.isHealthy()) {
            if (this.config.enableErrorReporting) {
                console.warn(`Cache unavailable, skipping write to ${cacheKey}`);
            }
            return;
        }

        try {
            await this.client!.set(cacheKey, JSON.stringify(value), {
                expiry: { type: TimeUnit.Seconds, count: config.ttlSeconds },
            });
        } catch (error) {
            if (error instanceof ConnectionError) {
                this.handleConnectionError(error);
            }
            throw new CacheLayerError(
                "SET_FAILED",
                `Failed to set cache for ${entityType}:${id}`,
                error instanceof Error ? error : undefined,
            );
        }
    }

    /**
     * Invalidate a cache entry (delete from cache)
     */
    async invalidate(entityType: string, id: string): Promise<void> {
        const cacheKey = this.buildCacheKey(entityType, id);

        if (!this.isHealthy()) {
            if (this.config.enableErrorReporting) {
                console.warn(`Cache unavailable, skipping invalidation of ${cacheKey}`);
            }
            return;
        }

        try {
            await this.client!.del([cacheKey]);
        } catch (error) {
            if (error instanceof ConnectionError) {
                this.handleConnectionError(error);
            }
            if (this.config.enableErrorReporting) {
                console.warn(
                    `Failed to invalidate cache for ${cacheKey}:`,
                    error instanceof Error ? error.message : String(error),
                );
            }
        }
    }

    /**
     * Invalidate all entries of an entity type.
     *
     * Note: SCAN-based pattern invalidation is intentionally not implemented for
     * cluster mode. SCAN in a GlideClusterClient only covers a single node, so a
     * naive loop would miss keys on other shards. In production, maintain a SET of
     * active IDs per entity type (e.g. "user:ids") and del them explicitly, or use
     * keyspace notifications via SUBSCRIBE. This method is a deliberate no-op.
     */
    async invalidatePattern(_entityType: string): Promise<number> {
        if (this.config.enableErrorReporting) {
            console.warn(
                "[cache] invalidatePattern is not supported in cluster mode - invalidate individual keys instead",
            );
        }
        return 0;
    }

    /**
     * Handle connection errors. GLIDE auto-reconnects internally - log and continue.
     * The failed in-flight command is surfaced as a ConnectionError; subsequent
     * commands will succeed once GLIDE re-establishes the connection.
     */
    private handleConnectionError(error: ConnectionError): void {
        if (this.config.enableErrorReporting) {
            console.warn(`[cache] Connection error (GLIDE will reconnect): ${error.message}`);
        }
    }

    /**
     * Build a cache key from entity type and ID
     */
    private buildCacheKey(entityType: string, id: string): string {
        const config = this.config.entityConfigs[entityType];
        if (!config) {
            throw new CacheLayerError(
                "CONFIG_NOT_FOUND",
                `Entity type "${entityType}" not configured`,
            );
        }
        return `${config.keyPrefix}:${id}`;
    }

    /**
     * Get cache statistics (for monitoring)
     */
    async getStats(): Promise<{ isHealthy: boolean }> {
        return { isHealthy: this.isHealthy() };
    }
}

/**
 * Factory function to create a cache layer instance.
 * If Valkey is unreachable, returns a layer in degraded (no-cache) mode so the
 * application can start and operate without caching until Valkey recovers.
 */
export async function createCacheLayer(options: CacheLayerOptions): Promise<CacheLayer> {
    const layer = new CacheLayer(options);
    try {
        await layer.initialize();
    } catch (error) {
        console.warn(
            "[cache] Starting in degraded mode (Valkey unreachable):",
            error instanceof Error ? error.message : String(error),
        );
    }
    return layer;
}
