# Valkey GLIDE Cache-Aside Layer

Production-grade cache-aside layer for Node.js CRUD APIs using Valkey GLIDE as the client. Implements read-through caching with configurable TTL per entity type, automatic cache invalidation on write operations, and graceful degradation when cache is unavailable.

## Features

- **Cache-aside pattern**: Check cache first, fallback to database, populate cache on miss
- **Cluster mode support**: Auto-topology discovery with configurable read preferences (primary, preferReplica, AZAffinity)
- **Entity-based TTL**: Configure different TTL values per entity type
- **Cache invalidation**: Automatic invalidation on updates/deletes plus pattern-based bulk invalidation
- **Graceful failure**: Application continues to work if cache is unavailable (degrades to database-only)
- **Connection resilience**: Exponential backoff reconnection logic on connection failures
- **TypeScript**: Full type safety with discriminated union types for cache results
- **Zero overhead when unavailable**: Cache writes are best-effort; failures don't impact request handling

## Installation

```bash
npm install @valkey/valkey-glide express
```

Requires Node.js 16+ and GLIDE 2.3.0+.

## Architecture

### Cache Layer Responsibilities

1. **Read operations** (`getWithFallback`):
   - Query cache first
   - On miss or timeout: fetch from database
   - Populate cache asynchronously on DB fetch
   - Return both data and source (cache or database)

2. **Write operations** (create, update, delete):
   - Execute database mutation
   - Invalidate related cache entries
   - Never fail the request due to cache invalidation failure

3. **Connection management**:
   - Cluster auto-discovery (seed with any node)
   - Exponential backoff reconnection (max 3 attempts)
   - Health status reporting

### Key Design Decisions

- **Promise-based async/await**: All operations are fully async, no callbacks
- **No connection pooling**: GLIDE uses a single multiplexed connection per node
- **Best-effort cache writes**: Cache populate/invalidate failures don't bubble up to requests
- **Configurable per entity type**: Different TTLs, key prefixes per entity
- **Error discrimination**: Distinguish timeouts, connection errors, and request errors

## Quick Start

### 1. Initialize Cache Layer

```typescript
import { createCacheLayer } from "./cache-layer";

const cache = await createCacheLayer({
  cacheConfig: {
    addresses: [
      { host: "valkey-1.example.com", port: 6379 },
      { host: "valkey-2.example.com", port: 6380 },
    ],
    readFrom: "preferReplica",
    requestTimeout: 5000,
    clientName: "my-api-cache",
  },
  entityConfigs: {
    user: {
      ttlSeconds: 3600,      // 1 hour
      keyPrefix: "users",
    },
    profile: {
      ttlSeconds: 1800,      // 30 minutes
      keyPrefix: "profiles",
    },
  },
  enableErrorReporting: true,
});
```

### 2. Use Cache-Aside in Routes

```typescript
app.get("/users/:id", async (req, res) => {
  try {
    const result = await cache.getWithFallback(
      "user",
      req.params.id,
      async () => {
        const user = await db.getUserById(req.params.id);
        if (!user) throw new Error("User not found");
        return user;
      },
    );

    res.json({
      data: result.data,
      source: result.source,  // "cache" or "database"
    });
  } catch (error) {
    res.status(error.message.includes("not found") ? 404 : 500).json({ error: error.message });
  }
});
```

### 3. Invalidate on Write

```typescript
app.put("/users/:id", async (req, res) => {
  const updated = await db.updateUser(req.params.id, req.body);

  // Invalidate cache - best effort, won't fail the request
  if (cache.isHealthy()) {
    await cache.invalidate("user", req.params.id).catch((err) => {
      console.warn("Cache invalidation failed:", err);
    });
  }

  res.json(updated);
});
```

## Configuration

### CacheConfig

```typescript
interface CacheConfig {
  // Cluster addresses (only need 1-2 seed nodes)
  addresses: Array<{ host: string; port: number }>;

  // Read preference: "primary", "preferReplica", "AZAffinity", "AZAffinityReplicasAndPrimary"
  readFrom?: "primary" | "preferReplica" | "AZAffinity" | "AZAffinityReplicasAndPrimary";

  // AZ affinity (required if readFrom is AZAffinity variant)
  clientAz?: string;

  // Request timeout in milliseconds
  requestTimeout?: number;

  // Enable TLS
  useTLS?: boolean;

  // Authentication
  credentials?: {
    username: string;
    password: string;
  };

  // Client identification for monitoring
  clientName?: string;
}
```

### EntityConfig

```typescript
interface EntityConfig {
  ttlSeconds: number;    // Cache lifetime for this entity type
  keyPrefix: string;     // Redis key prefix (e.g., "users" -> "users:user-123")
}
```

## API Reference

### getWithFallback(entityType, id, fetchFromDb)

Cache-aside read operation.

```typescript
const result = await cache.getWithFallback(
  "user",
  "user-123",
  async () => db.getUserById("user-123"),
);

// result.data: T (the entity)
// result.source: "cache" | "database"
```

Returns immediately on cache hit. On miss, fetches from database and populates cache asynchronously.

**Error behavior**: Timeouts and connection errors are caught and trigger database fallback. Other errors propagate.

### setWithTtl(entityType, id, value)

Manually set a value in cache with configured TTL.

```typescript
const newUser = { id: "user-456", name: "Alice" };
await cache.setWithTtl("user", "user-456", newUser);
```

**Error behavior**: Throws `CacheLayerError` if entity type is not configured. Connection errors are logged (if enabled) but don't propagate.

### invalidate(entityType, id)

Delete a single cache entry by ID.

```typescript
await cache.invalidate("user", "user-123");
```

**Error behavior**: Errors are logged but don't propagate (best-effort invalidation).

### invalidatePattern(entityType)

Delete all cache entries matching an entity type pattern.

```typescript
const deleted = await cache.invalidatePattern("user");
console.log(`Deleted ${deleted} user cache entries`);
```

Useful for bulk cache clears. Returns number of entries deleted.

### isHealthy()

Check current cache health status.

```typescript
if (cache.isHealthy()) {
  console.log("Cache is available");
} else {
  console.log("Cache unavailable, will use database fallback");
}
```

### getStats()

Get cache statistics for monitoring.

```typescript
const stats = await cache.getStats();
console.log({
  isHealthy: stats.isHealthy,
  reconnectAttempts: stats.reconnectAttempts,
});
```

### close()

Close the Valkey connection.

```typescript
await cache.close();
```

## Cluster Mode Examples

### Basic Cluster

```typescript
const cache = await createCacheLayer({
  cacheConfig: {
    addresses: [
      { host: "node1.valkey.local", port: 6379 },
      { host: "node2.valkey.local", port: 6379 },
    ],
    readFrom: "preferReplica",
  },
  entityConfigs: { user: { ttlSeconds: 3600, keyPrefix: "users" } },
});
```

### AZ-Affinity for Multi-AZ Clusters

```typescript
const cache = await createCacheLayer({
  cacheConfig: {
    addresses: [
      { host: "valkey-us-east-1a.local", port: 6379 },
      { host: "valkey-us-east-1b.local", port: 6379 },
      { host: "valkey-us-east-1c.local", port: 6379 },
    ],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",  // Prefer reads from same AZ
  },
  entityConfigs: { user: { ttlSeconds: 3600, keyPrefix: "users" } },
});
```

### TLS + Authentication

```typescript
const cache = await createCacheLayer({
  cacheConfig: {
    addresses: [{ host: "valkey.prod.example.com", port: 6380 }],
    useTLS: true,
    credentials: {
      username: "app-user",
      password: process.env.VALKEY_PASSWORD,
    },
    readFrom: "preferReplica",
  },
  entityConfigs: { user: { ttlSeconds: 3600, keyPrefix: "users" } },
});
```

## Error Handling

### CacheLayerError

All cache layer errors throw `CacheLayerError` with a `code` field:

```typescript
try {
  await cache.invalidate("unknown", "id");
} catch (error) {
  if (error instanceof CacheLayerError) {
    console.error(`[${error.code}] ${error.message}`);
    if (error.originalError) {
      console.error("Caused by:", error.originalError);
    }
  }
}
```

Error codes:
- `INIT_FAILED` - Connection initialization failed
- `CONFIG_NOT_FOUND` - Entity type not configured
- `GET_WITH_FALLBACK_FAILED` - Cache-aside operation failed
- `SET_FAILED` - Cache write failed

### Handling Cache Unavailability

The cache layer degrades gracefully when Valkey is unavailable:

```typescript
// Option 1: Check health before operations
if (cache.isHealthy()) {
  await cache.setWithTtl("user", id, data);
} else {
  console.log("Cache unavailable, data persisted to DB only");
}

// Option 2: Catch errors and continue
try {
  await cache.invalidate("user", id);
} catch (error) {
  console.warn("Cache invalidation failed, continuing:", error.message);
}

// Option 3: getWithFallback handles it automatically
const result = await cache.getWithFallback("user", id, fetchFromDb);
// Works even if cache is down - falls back to DB
```

## Performance Considerations

### TTL Tuning

- **Hot data** (user profiles, settings): 3600 seconds (1 hour)
- **Reference data** (lookup tables): 86400 seconds (24 hours)
- **Volatile data** (inventory, counters): 60-300 seconds (1-5 minutes)

### Connection Pooling

GLIDE uses a single multiplexed connection per cluster node. No pool configuration needed. For high-concurrency workloads, GLIDE automatically queues requests on the single connection.

### Monitoring

```typescript
// Health endpoint for load balancers
app.get("/health/cache", async (req, res) => {
  const stats = await cache.getStats();
  res.status(stats.isHealthy ? 200 : 503).json(stats);
});

// Metrics endpoint
app.get("/metrics/cache", async (req, res) => {
  const stats = await cache.getStats();
  res.json({
    healthy: stats.isHealthy,
    reconnectAttempts: stats.reconnectAttempts,
  });
});
```

## Testing

Run tests:

```bash
npm test
```

Test coverage includes cache hits/misses, invalidation patterns, error handling, and cluster configuration.

See `cache-layer.test.ts` for comprehensive test examples.

## TypeScript Types

All types are exported from the main module:

```typescript
import {
  CacheLayer,
  CacheLayerError,
  CacheResult,
  CacheConfig,
  EntityConfig,
  CacheEntityConfig,
  CacheLayerOptions,
} from "./cache-layer";
```

Full generic support for CRUD entity types:

```typescript
interface User {
  id: string;
  name: string;
  email: string;
}

const result: CacheResult<User> = await cache.getWithFallback(
  "user",
  "123",
  async () => db.getUserById("123"),
);
```

## Production Checklist

- [ ] Configure appropriate TTLs for each entity type
- [ ] Set `enableErrorReporting: true` in production
- [ ] Add health check endpoint at `/cache/health`
- [ ] Monitor reconnect attempts and alert if `reconnectAttempts > 0`
- [ ] Test failure scenarios: cache down, timeout, authentication failure
- [ ] Configure TLS and authentication credentials
- [ ] Use seed addresses pointing to cluster nodes in different AZs
- [ ] Set `readFrom: "preferReplica"` to distribute read load
- [ ] Implement graceful shutdown to close cache connection
- [ ] Log cache hit/miss rates for optimization

## References

- [Valkey GLIDE Documentation](https://github.com/valkey-io/valkey-glide)
- [Cache-Aside Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cache-aside)
- [Valkey Cluster Specification](https://valkey.io/topics/cluster-tutorial)
