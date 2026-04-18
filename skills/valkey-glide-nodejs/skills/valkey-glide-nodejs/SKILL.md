---
name: valkey-glide-nodejs
description: "Use when building Node.js / TypeScript apps with Valkey GLIDE - Promise API, GlideClient, GlideClusterClient, multiplexer behavior, IAM, AZ affinity, OpenTelemetry, Batch, PubSub, streams. Covers the divergence from ioredis; basic command shapes are assumed knowable from training. Not for ioredis migration - use migrate-ioredis."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Node.js Client

Agent-facing skill for GLIDE Node. Assumes the reader can already write basic ioredis or node-redis from training (get/set/hset, pipelines, pub/sub EventEmitter loop). Covers only what diverges from those clients and what GLIDE adds on top.

## Routing

| Question | Reference |
|----------|-----------|
| `GlideClient` vs `GlideClusterClient`, TLS, auth, IAM, lazy connect, AZ affinity, decoder, close | [connection](reference/features-connection.md) |
| PubSub: static config vs dynamic `subscribe` (2.3+), callback vs polling, `getSubscriptions()`, sharded | [pubsub](reference/features-pubsub.md) |
| `Batch` / `ClusterBatch` (constructor `isAtomic`), `raiseOnError`, cluster retry strategy, WATCH | [batching](reference/features-batching.md) |
| Streams typed option objects, split `xclaim` / `xclaimJustId`, split `xpending` / `xpendingWithOptions`, multi-stream slot constraint | [streams](reference/features-streams.md) |
| TLS advanced config, IAM, Lua `Script` (requires `.release()`), Valkey Functions 7.0+, error hierarchy, Decoder | [advanced](reference/features-advanced.md) |
| Error types: `ValkeyError` base (not `GlideError`), subclass hierarchy, reconnection semantics, no EventEmitter | [error-handling](reference/best-practices-error-handling.md) |
| Multiplexer discipline, batching as top optimization, inflight cap, TCP_NODELAY, compression | [performance](reference/best-practices-performance.md) |
| Production defaults, timeout tuning, AZ affinity, OTel setup, platform constraints (glibc, native binding, proxies) | [production](reference/best-practices-production.md) |

## Multiplexer rule (the #1 agent mistake)

One `GlideClient` / `GlideClusterClient` per process, shared across every pending Promise. Do not create per-request clients. Do not pool them.

**Exceptions that need a dedicated client:**

- Blocking commands (per the core's blocking-timeout table): `BLPOP`, `BRPOP`, `BLMOVE`, `BZPOPMAX`, `BZPOPMIN`, `BRPOPLPUSH`, `BLMPOP`, `BZMPOP`, plus `XREAD` / `XREADGROUP` when called with `BLOCK`, and `WAIT` / `WAITAOF`.
- WATCH / MULTI / EXEC transactions (connection-state commands).
- Long polling `getPubSubMessage()` (holds the Promise indefinitely).

Large values are NOT an exception - they pipeline through the multiplexer fine.

## Grep hazards

1. **`decode_responses` has no direct equivalent, but `Decoder` does.** Default is `Decoder.String`; switch to `Decoder.Bytes` client-wide via `defaultDecoder` or per-command via `{ decoder: Decoder.Bytes }` to get `Buffer` returns.
2. **`publish()` argument order is REVERSED from ioredis.** `await client.publish(message, channel)` - message first, channel second. ioredis is `client.publish(channel, message)`. Silent bug factory during migration.
3. **`close()` is synchronous.** Returns `void`, not a `Promise`. Unlike Python where `close()` is async.
4. **`getStatistics()` is synchronous.** Local accessor returning an object with string values. Unlike Python where it is `await client.get_statistics()`.
5. **Error base is `ValkeyError`, NOT `GlideError`.** Python uses `GlideError`; Node uses `ValkeyError` as the abstract base. `RequestError` / `ClosingError` are direct subclasses.
6. **`instanceof RequestError` catches timeouts, conn errors, config errors, exec aborts.** They are subclasses. Check specifics first.
7. **Reconnection is infinite.** `connectionBackoff.numberOfRetries` caps the backoff SEQUENCE length; the client keeps retrying until close.
8. **`periodicChecks.duration_in_sec` is snake_case** - unusual for a JS API; don't correct it to camelCase.
9. **`ServiceType` is PascalCase enum values: `ServiceType.Elasticache` / `ServiceType.MemoryDB`.** All-caps variants don't exist.
10. **`isAtomic` is a constructor arg, not an option object.** `new Batch(true)` for transaction, `new Batch(false)` for pipeline. `Transaction` / `ClusterTransaction` are deprecated aliases.
11. **Scripts are NOT usable inside a Batch.** Use `batch.customCommand(["EVAL", ...])` instead. Also: `Script` objects are not garbage collected - always call `script.release()`.
12. **No Alpine support** out of the box - requires glibc 2.17+. Use Debian-based images.
13. **Static PubSub subscriptions require RESP3.** RESP2 raises `ConfigurationError`.
14. **Node.js HAS dynamic pub/sub at v2.3+** (`subscribe`, `subscribeLazy`, `psubscribe`, `ssubscribe`, `unsubscribe`, `getSubscriptions`). Don't repeat the older docs claim that Node lacks it.

## Cross-references

- `migrate-ioredis` - migrating from ioredis
- `glide-dev` - GLIDE core internals (Rust), binding mechanics
- `valkey` - Valkey commands and app patterns
