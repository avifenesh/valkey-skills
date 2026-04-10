---
name: migrate-ioredis
description: "Use when migrating Node.js from ioredis to Valkey GLIDE. Covers API mapping, creation-time PubSub, reversed publish args, Batch API, TypeScript types. Not for greenfield Node.js apps - use valkey-glide-nodejs instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from ioredis to Valkey GLIDE (Node.js)

Use when migrating a Node.js application from ioredis to the GLIDE client library.

## Routing

- String, hash, list, set, sorted set, delete, exists, cluster -> API Mapping
- Pipeline, transaction, Batch API, multi -> Advanced Patterns
- PubSub, subscribe, publish, reversed args -> Advanced Patterns
- Lua scripting, defineCommand, evalsha -> Advanced Patterns
- Event handling, TypeScript -> Advanced Patterns

## Key Differences

| Area | ioredis | GLIDE |
|------|---------|-------|
| Hash args | Spread pairs: hset("h", "k1", "v1", "k2", "v2") | Object: hset("h", {k1: "v1", k2: "v2"}) |
| Sorted set args | Interleaved: zadd("z", 1, "a", 2, "b") | Array of objects: zadd("z", [{element: "a", score: 1}]) |
| Expiry | Separate commands: setex, psetex | Options on set(): {expiry: {type, count}} |
| Multi-arg commands | Varargs or rest params | Array arguments |
| Connection model | Connection pool or single | Single multiplexed connection per node |
| Cluster | new Redis.Cluster([...]) | GlideClusterClient.createClient({...}) |
| Script caching | Manual defineCommand | Automatic via Script class |
| Events | EventEmitter (on("error")) | No event emitter - errors surface per-command |

## Quick Start - Connection Setup

**ioredis:**
```javascript
const Redis = require("ioredis");
const redis = new Redis({ host: "localhost", port: 6379 });
```

**GLIDE:**
```javascript
import { GlideClient } from "@valkey/valkey-glide";
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 5000,
});
```

## Configuration Mapping

| ioredis parameter | GLIDE equivalent |
|-------------------|------------------|
| host, port | addresses: [{host, port}] |
| db | databaseId |
| password | credentials: {password} |
| username | credentials: {username, password} |
| connectTimeout | requestTimeout (covers full lifecycle) |
| tls: {} | useTls: true |
| retryStrategy | Built-in reconnection with connectionBackoff |
| maxRetriesPerRequest | Not applicable - GLIDE handles retries internally |
| lazyConnect: true | Default behavior in GLIDE |

## Incremental Migration Strategy

No drop-in compatibility layer exists for Node.js. Migration approach:

1. Install `@valkey/valkey-glide` alongside `ioredis`
2. Create a wrapper module that abstracts the client interface
3. Migrate route handlers or services one at a time behind the wrapper
4. Use GLIDE's Batch API for bulk operations previously handled by ioredis pipelines
5. Swap the wrapper implementation once all call sites are migrated
6. Remove `ioredis` dependency

## Reference

| Topic | File |
|-------|------|
| Command-by-command API mapping (strings, hashes, lists, sets, sorted sets, delete, exists, cluster) | [api-mapping](reference/api-mapping.md) |
| Pipelines, transactions, Pub/Sub, Lua scripting, events, TypeScript | [advanced-patterns](reference/advanced-patterns.md) |

## See Also

- **valkey-glide-nodejs** skill - full GLIDE Node.js API details
- Scripting (see valkey-glide skill) - Lua scripting and the Script class
- PubSub (see valkey-glide skill) - subscription patterns and dynamic PubSub
- Batching (see valkey-glide skill) - pipeline and transaction patterns

## Gotchas

1. **Hash argument format.** ioredis accepts spread key-value pairs. GLIDE requires an object or HashDataType array.
2. **Sorted set format.** ioredis uses interleaved score, member pairs. GLIDE uses {element, score} objects.
3. **No setex/psetex/setnx.** Use set() with the expiry and conditionalSet options.
4. **Array args for multi-key commands.** del, exists, lpush, sadd all take arrays, not rest parameters.
5. **Pipeline result format.** ioredis returns [[error, result], ...]. GLIDE returns a flat result array.
6. **No event emitter.** Handle errors per-command or set up external health checks.
7. **Node.js PubSub is creation-time only.** Unlike Java/Python/Go, the Node.js client requires all subscriptions at connection time.
8. **Publish arg order reversed.** ioredis: publish(channel, message). GLIDE: publish(message, channel).
9. **protobufjs bundle size.** Adds ~19KB gzipped - relevant for serverless cold starts.
10. **npm version on Linux.** Requires npm 11+ for proper optional dependency handling.
