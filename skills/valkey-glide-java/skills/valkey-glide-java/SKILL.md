---
name: valkey-glide-java
description: "Use when building Java apps with Valkey GLIDE - CompletableFuture API, Lombok builder pattern, GlideClient, GlideClusterClient, multiplexer behavior, direct-JNI binding (NOT UDS), Batch, PubSub, streams, OpenTelemetry. Covers the divergence from Jedis / Lettuce; basic command shapes are assumed knowable from training. Not for Jedis/Lettuce migration - use migrate-jedis or migrate-lettuce."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Java Client

Agent-facing skill for GLIDE Java. Assumes the reader can already write basic Jedis or Lettuce from training (Jedis synchronous commands, Lettuce's `RedisAsyncCommands`, `RedisFuture`, or reactive `RedisReactiveCommands`). Covers only what diverges and what GLIDE adds on top.

## Routing

| Question | Reference |
|----------|-----------|
| `GlideClient` vs `GlideClusterClient`, Lombok builders, TLS, auth, IAM, lazy connect, AZ affinity, `AutoCloseable` | [connection](reference/features-connection.md) |
| PubSub: static subscription config vs runtime `subscribe`, callback vs polling, `publish(message, channel)` REVERSED args, sharded | [pubsub](reference/features-pubsub.md) |
| `Batch` / `ClusterBatch` with `isAtomic` constructor, `BatchOptions`, retry strategy, WATCH | [batching](reference/features-batching.md) |
| Stream typed options, `StreamRange` bounds, split `xclaim` / `xclaimJustId`, cluster multi-stream slot constraint | [streams](reference/features-streams.md) |
| TLS advanced config, IAM, `Script` + `invokeScript`, Valkey Functions, custom commands, OTel | [advanced](reference/features-advanced.md) |
| Error types: `GlideException` base + 6 siblings (FLAT hierarchy), `ExecutionException` unwrap rule, `ConfigurationError` "Error" suffix | [error-handling](reference/best-practices-error-handling.md) |
| Multiplexer discipline, batching as top optimization, inflight cap, CompletableFuture composition | [performance](reference/best-practices-performance.md) |
| Production defaults, timeout tuning, AZ affinity, OTel setup, JVM and glibc constraints | [production](reference/best-practices-production.md) |

## Multiplexer rule (the #1 agent mistake)

One `GlideClient` / `GlideClusterClient` per JVM. Shared across every thread / CompletableFuture chain. Do not create per-request clients. Do not pool them.

**Exceptions that need a dedicated client:**

- Blocking commands (dedicated client due to **occupancy** - they hold the multiplexed connection for the block duration): `blpop`, `brpop`, `blmove`, `bzpopmax`, `bzpopmin`, `brpoplpush`, `blmpop`, `bzmpop`, plus `xread` / `xreadgroup` with block, and `wait` / `waitaof`.
- Transactional commands (dedicated client due to **connection-state leakage** across callers on the shared multiplexer): `watch` / `multi` / `exec` (atomic batch after WATCH).
- Long polling `getPubSubMessage()` - holds the future indefinitely (occupancy).

Large values are NOT an exception - they pipeline through the multiplexer fine.

## Grep hazards

1. **`publish(message, channel)` - REVERSED from Jedis / Lettuce.** Java matches the Python/Node reversed pattern. `client.publish("message", "channel").get()` - message first, channel second. Jedis is `publish(channel, message)`; Lettuce is `publish(channel, message)`. **Silent bug factory during migration.** Go and C# GLIDE match the legacy convention; Python, Node, and Java GLIDE reverse it. Source: `java/client/.../commands/PubSubBaseCommands.java` `CompletableFuture<String> publish(String message, String channel);`.
2. **Java uses direct JNI, NOT UDS.** Migrated from UDS to direct JNI in GLIDE 2.2 for Windows support. UDS is Python-async and Node.js ONLY; Java, Go, Python-sync, C#, PHP, Ruby are all direct-FFI. Do not describe Java as UDS-backed.
3. **Every command returns `CompletableFuture<T>`.** Unwrap with `.get(timeout, TimeUnit)` - never bare `.get()` (blocks indefinitely if the connection has issues).
4. **Errors come via `ExecutionException` from `.get()`.** Unwrap via `.getCause()` and `instanceof` check against specific `GlideException` subclasses.
5. **Error hierarchy is FLAT under `GlideException`.** No nested subclass tree like Python/Node. `GlideException extends RuntimeException` (not abstract). Direct children: `ClosingException`, `ConnectionException`, `ConfigurationError` (note "Error" suffix - inconsistency), `ExecAbortException`, `RequestException`, `TimeoutException`. No `LoggerError`.
6. **`java.util.concurrent.TimeoutException` vs GLIDE's `TimeoutException`** - two different classes with the same simple name. `.get(n, TimeUnit.MILLISECONDS)` can throw the former if the future doesn't complete in `n` ms; GLIDE's internal request timeout surfaces as the latter wrapped in `ExecutionException`. Import both with explicit packages or fully-qualified names.
7. **`GlideString` binary type** - methods often have `String` and `GlideString` overloads. Use `GlideString` for binary-safe bytes; `gs("...")` is the factory helper.
8. **Lombok `@Builder` pattern** - `GlideClientConfiguration.builder().address(...).useTLS(true).build()`. Nested builders for `NodeAddress`, `ServerCredentials`, `BackoffStrategy`, `AdvancedGlideClientConfiguration`.
9. **`AutoCloseable`** - clients implement it; use try-with-resources or call `close()` explicitly.
10. **Jedis compatibility layer** available at `java/jedis-compatibility/` - zero-code-change drop-in for Jedis users. See `migrate-jedis` skill.
11. **Reconnection is infinite.** `BackoffStrategy.numOfRetries` caps the backoff sequence length only.
12. **Static PubSub subscriptions require RESP3.** Using RESP2 raises `ConfigurationError`.

## Cross-references

- `migrate-jedis` - migrating from Jedis (with zero-code-change compat layer option)
- `migrate-lettuce` - migrating from Lettuce (CompletableFuture-to-CompletableFuture conversion)
- `spring-data-valkey` - Spring Boot integration via Spring Data Valkey
- `glide-dev` - GLIDE core internals (Rust) and JNI binding mechanics
- `valkey` - Valkey commands and app patterns
