---
name: valkey-glide-python
description: "Use when building Python apps with Valkey GLIDE - async/sync APIs, GlideClient, GlideClusterClient, multiplexer behavior, IAM, AZ affinity, OpenTelemetry, batching, PubSub, streams. Covers the divergence from redis-py; basic command shapes are assumed knowable from training. Not for redis-py migration - use migrate-redis-py."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Python Client

Agent-facing skill for GLIDE Python. Assumes the reader can already write basic redis-py from training (get/set/hset, pipelines, consumer groups, pubsub message loop). Covers only what diverges from redis-py and what GLIDE adds on top.

## Routing

| Question | Reference |
|----------|-----------|
| `GlideClient` vs `GlideClusterClient`, TLS, auth, IAM, lazy connect, AZ affinity, compression, statistics, graceful close | [connection](reference/features-connection.md) |
| PubSub: static vs dynamic (2.3+) subscriptions, callback vs polling, reconciliation, sharded, `get_subscriptions()` | [pubsub](reference/features-pubsub.md) |
| `Batch` / `ClusterBatch` (`is_atomic` flag), cluster routing, retry strategy, WATCH | [batching](reference/features-batching.md) |
| Streams typed option classes, split `xclaim` vs `xclaim_just_id`, multi-stream slot constraint | [streams](reference/features-streams.md) |
| Lua `Script`, cluster SCAN iterator, routing (`AllNodes`, `SlotKeyRoute`, ...), OpenTelemetry, Logger, error hierarchy | [advanced](reference/features-advanced.md) |
| Error types: shadowing `TimeoutError` / `ConnectionError`, subclass hierarchy, reconnection semantics | [error-handling](reference/best-practices-error-handling.md) |
| Multiplexer discipline, batching as top optimization, inflight cap, compression impact | [performance](reference/best-practices-performance.md) |
| Production defaults, timeout tuning, AZ affinity, OTel setup, platform constraints (glibc, protobuf, proxies) | [production](reference/best-practices-production.md) |

## Multiplexer rule (the #1 agent mistake)

One `GlideClient` / `GlideClusterClient` per process, shared across every coroutine. Do not create per-task clients. Do not pool them.

**Exceptions that need a dedicated client:**

- Blocking commands (per the core's blocking-timeout table): `BLPOP`, `BRPOP`, `BLMOVE`, `BZPOPMAX`, `BZPOPMIN`, `BRPOPLPUSH`, `BLMPOP`, `BZMPOP`, plus `XREAD` / `XREADGROUP` when called with `BLOCK`, and `WAIT` / `WAITAOF`.
- WATCH / MULTI / EXEC transactions (connection-state commands).
- Long polling `get_pubsub_message()` (blocks an asyncio task).

Large values are NOT an exception - they pipeline through the multiplexer fine.

## Grep hazards

1. **`decode_responses=True` does not exist.** All string-like returns are `bytes`. Add `.decode()` at each read site, or use the `str` overloads where typed.
2. **Timeout unit change.** `request_timeout` is milliseconds (redis-py's `socket_timeout` is seconds).
3. **`TimeoutError` and `ConnectionError` shadow Python built-ins** - always import them with `as GlideTimeoutError` / `as GlideConnectionError`.
4. **Reconnection is infinite.** `BackoffStrategy.num_of_retries` caps the backoff SEQUENCE length; the client keeps retrying until close.
5. **`get_statistics()` values are strings, not int.** The dict values are `str` (stringified counters / timestamps).
6. **Batches are executed by the client, not the batch.** Call `await client.exec(batch, ...)` - the verb is a client method. Not `batch.execute()`.
7. **`is_atomic=True` for transactions, `False` for pipelines.** One class (`Batch` / `ClusterBatch`), two modes.
8. **Sync is `glide_sync` (not `glide`).** The sync wrapper (GLIDE 2.1+) imports from `glide_sync`, with the same class names.
9. **Static PubSub subscriptions require RESP3.** Using RESP2 raises `ConfigurationError`.
10. **No Alpine support.** GLIDE requires glibc 2.17+.
11. **`publish()` argument order is REVERSED from redis-py.** `await client.publish(message, channel)` - message first, channel second. redis-py is `r.publish(channel, message)`. Silent bug factory during migration.

## Cross-references

- `migrate-redis-py` - migrating from redis-py
- `glide-dev` - GLIDE core internals (Rust), binding mechanics
- `valkey` - Valkey commands and app patterns
