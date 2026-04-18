---
name: migrate-ioredis
description: "Use when migrating Node.js from ioredis to Valkey GLIDE. Covers API-shape divergences (hash object vs spread, zadd element-score objects, typed SET options, array args), PubSub mental-model switch, Batch API, EventEmitter removal, reversed publish args. Not for greenfield Node.js - use valkey-glide-nodejs."
version: 1.1.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from ioredis to Valkey GLIDE (Node.js)

Use when moving an existing ioredis app to GLIDE. Assumes you already know ioredis. Covers what breaks or changes shape; commands that translate literally (just `client.` -> `await glideClient.`, array args for multi-key) are not listed here.

## Divergences that actually matter

| Area | ioredis | GLIDE |
|------|---------|-------|
| Construction | `new Redis({ host, port })` - sync | `await GlideClient.createClient(config)` - async factory |
| Hash args | `hset(key, "f1", "v1", "f2", "v2")` (spread pairs) | `hset(key, { f1: "v1", f2: "v2" })` (object) |
| Sorted set args | `zadd(key, 1, "a", 2, "b")` (interleaved) | `zadd(key, [{ element: "a", score: 1 }, { element: "b", score: 2 }])` |
| SET expiry / conditional | `setex`, `psetex`, `setnx` / kwargs `EX`, `PX`, `NX`, `XX` | `client.set(k, v, { expiry: { type: "sec", count: 60 }, conditionalSet: "onlyIfDoesNotExist" })` |
| Multi-arg commands | Varargs: `del("k1", "k2")` | Array: `del(["k1", "k2"])` - same rule for `exists`, `lpush`, `sadd`, `srem` etc. |
| Connection pool | `new Redis({ ... })` per connection, or cluster with N connections | Multiplexer - one client per process; blocking commands need a dedicated client |
| Cluster | `new Redis.Cluster([{host, port}], { ... })` | `await GlideClusterClient.createClient({ addresses })` |
| Pipeline | `client.pipeline().set().get().exec()` - chainable on client | `new Batch(false).set().get()` run through the client's batch method - standalone object |
| Transaction | `client.multi().set().get().exec()` | `new Batch(true)` - same class, `isAtomic` flag |
| Pipeline result | `[[err, result], ...]` tuples | Flat results array; with `raiseOnError: false`, errors are `RequestError` instances inline |
| Script caching | `client.defineCommand(name, { lua, numberOfKeys })` | `new Script(lua)` + `client.invokeScript(script, { keys, args })`; remember `script.release()` |
| PubSub | `sub = client.duplicate(); sub.subscribe(ch); sub.on("message", ...)` | Static config OR runtime `await client.subscribe(new Set([ch]))` (GLIDE 2.3+); callback in config OR `await client.getPubSubMessage()` polling |
| `publish` | `client.publish(channel, message)` | `await client.publish(message, channel)` - **arguments REVERSED**; top silent-bug source during migration |
| Events | `client.on("error", ...)`, `on("ready", ...)`, `on("end", ...)` EventEmitter | No EventEmitter; errors surface per-Promise via `await`, state via `getStatistics()` counters |
| `retryStrategy: (times) => ...` | Function | Object: `connectionBackoff: { numberOfRetries, factor, exponentBase, jitterPercent }` |
| `maxRetriesPerRequest` | Caps retries | Reconnection is INFINITE in GLIDE; no equivalent. Commands fail with `ConnectionError` while reconnecting. |
| `lazyConnect: true` | Delays implicit connect | GLIDE equivalent is also `lazyConnect: true` (NOT default) - delays the TCP connect until first command |
| `connectTimeout` | ms for initial socket | GLIDE: `advancedConfiguration.connectionTimeout` (default 2000 ms); `requestTimeout` is separate (default 250 ms) |
| `tls: {}` | TLS config object | `useTLS: true` top-level + `advancedConfiguration.tlsAdvancedConfiguration` for custom CA / insecure mode |
| `client.disconnect()` / `.quit()` | Methods | `client.close()` - synchronous (`void`, not a Promise) |
| `client.status` property | Enum-like string | Not exposed; observe via commands or `getStatistics()` |

## Config translation

```javascript
// ioredis:
const redis = new Redis({
    host: "h", port: 6379, db: 0, password: "pw",
    tls: {}, connectTimeout: 5000, retryStrategy: (times) => Math.min(times * 50, 2000),
});

// GLIDE:
import { GlideClient } from "@valkey/valkey-glide";
const client = await GlideClient.createClient({
    addresses: [{ host: "h", port: 6379 }],
    databaseId: 0,
    credentials: { password: "pw" },
    useTLS: true,
    requestTimeout: 5000,  // ms, default 250
    connectionBackoff: { numberOfRetries: 5, factor: 50, exponentBase: 2, jitterPercent: 20 },
});
```

## Migration strategy

No compatibility layer exists for Node. Migrate incrementally via a wrapper module:

1. Install `@valkey/valkey-glide` alongside `ioredis`.
2. Build a thin adapter interface that covers every `client.*` call your app makes.
3. Implement the GLIDE side of the adapter command-by-command, starting with hot paths.
4. Swap services or route handlers behind a feature flag.
5. Remove `ioredis` only after every call site is migrated and canaried.

Big-bang migration trips on divergences - hash object vs spread, sorted-set element-score format, REVERSED publish args, pipeline result shape, EventEmitter removal, lazyConnect semantics change.

## Reference

| Topic | File |
|-------|------|
| SET typed options, HSET object form, ZADD element/score objects, array args, cluster | [api-mapping](reference/api-mapping.md) |
| PubSub mental-model switch, Batch API, Lua Script.release(), no-EventEmitter, TypeScript | [advanced-patterns](reference/advanced-patterns.md) |

## Gotchas (the short list)

1. **`publish(message, channel)` - arguments REVERSED** from ioredis's `publish(channel, message)`. Silent bug source.
2. **HSET takes an object, not spread pairs.** `hset(key, { f1: "v1" })` not `hset(key, "f1", "v1")`.
3. **ZADD takes `{element, score}` array** - `zadd(key, [{ element: "a", score: 1 }])`.
4. **Multi-key commands take arrays** not varargs: `del(["k1", "k2"])`.
5. **No EventEmitter.** Handle errors per-Promise. For health monitoring use `getStatistics()`.
6. **Pipeline result is a flat array**, not `[[err, result], ...]` tuples. Use `raiseOnError: false` to get errors inline.
7. **No connection pool.** Multiplexer - one client per process; blocking commands (`BLPOP`, `BRPOP`, `BLMOVE`, `BZPOPMAX`/`MIN`, `BRPOPLPUSH`, `BLMPOP`, `BZMPOP`, `XREAD`/`XREADGROUP` with `BLOCK`) and WATCH/MULTI/EXEC need a dedicated client.
8. **Node.js HAS dynamic pub/sub at v2.3+** - `subscribe`, `subscribeLazy`, `psubscribe`, `ssubscribe`, `unsubscribe`, `getSubscriptions`. Older docs claiming Node is config-only are outdated.
9. **Static pub/sub subscriptions require RESP3.** Using RESP2 raises `ConfigurationError`.
10. **Reconnection is infinite** - no `maxRetriesPerRequest` equivalent; commands fail with `ConnectionError` while reconnecting.
11. **`Script` needs manual `release()`** - not garbage collected, leaks native memory otherwise.
12. **Scripts not supported in Batch** - use `batch.customCommand(["EVAL", ...])` instead.
13. **`close()` is synchronous** - returns `void`, not a Promise. Don't `await` it.
14. **Alpine not supported** out of the box - glibc 2.17+ required. Use Debian-based images.
15. **`ServiceType.Elasticache` / `ServiceType.MemoryDB`** - PascalCase enum values for IAM config.

## Cross-references

- `valkey-glide-nodejs` - full Node skill for GLIDE features beyond the migration scope
- `glide-dev` - GLIDE core internals if you need to debug binding-level issues
