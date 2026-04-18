---
name: valkey-glide-go
description: "Use when building Go apps with Valkey GLIDE - synchronous API, Client / ClusterClient, CGO bridge, Result[T] nil handling, Batch, streams, multiplexer behavior, IAM, AZ affinity, OpenTelemetry. Covers the divergence from go-redis; basic command shapes are assumed knowable from training. Not for go-redis migration - use migrate-go-redis."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Go Client

Agent-facing skill for GLIDE Go. Assumes the reader can already write basic go-redis from training (`rdb.Get(ctx, key).Result()`, pipelines, consumer groups, pubsub loop). Covers only what diverges from go-redis and what GLIDE adds on top.

## Routing

| Question | Reference |
|----------|-----------|
| `Client` vs `ClusterClient`, TLS, auth, IAM, lazy connect, AZ affinity, DB selection, `ResetConnectionPassword` | [connection](reference/features-connection.md) |
| PubSub: static config vs dynamic `Subscribe` (2.3+), callback vs polling, `GetSubscriptionConfig`, sharded | [pubsub](reference/features-pubsub.md) |
| `Batch` / `ClusterBatch`, atomic vs pipeline, `BatchOptions`, `RetryStrategy`, WATCH | [batching](reference/features-batching.md) |
| Streams typed options, split `XClaim` / `XClaimJustId`, `XAutoClaimResponse` struct, multi-stream slot constraint | [streams](reference/features-streams.md) |
| Custom commands, routing (`AllNodes`, `SlotKeyRoute`, ...), OpenTelemetry, cluster SCAN, Lua `Script` | [advanced](reference/features-advanced.md) |
| Go-specific flat error model, `GoError` mapping (only 3 types auto-mapped), `BatchError` | [error-handling](reference/best-practices-error-handling.md) |
| Multiplexer discipline, batching as top optimization, inflight cap, `GetStatistics()` uint64 | [performance](reference/best-practices-performance.md) |
| Production defaults, timeout tuning, AZ affinity, OTel setup, CGO / glibc constraints | [production](reference/best-practices-production.md) |

## Multiplexer rule (the #1 agent mistake)

One `*Client` / `*ClusterClient` per process, shared across every goroutine. Do not create per-request clients. Do not pool them.

**Exceptions that need a dedicated client:**

- Blocking commands: `BLPop`, `BRPop`, `BLMove`, `BZPopMax`, `BZPopMin`, `BRPopLPush`, `BLMPop`, `BZMPop`, plus `XRead` / `XReadGroup` with block, and `Wait` / `WaitAof`. They occupy the multiplexed connection for the block duration.
- `Watch` / `Multi` / `Exec` transactions (connection-state commands).
- PubSub clients doing high-volume subscriptions.

Large values are NOT an exception - they pipeline through the multiplexer fine.

## Grep hazards

1. **`Publish(ctx, channel, message)` - NOT reversed like Python/Node.** Go matches the Redis / go-redis convention. If you've read the Python or Node skill's "REVERSED publish" gotcha - that does NOT apply to Go.
2. **`Result[T]` wraps nil.** Methods returning `Result[T]` (Get, HGet, etc.) require `.IsNil()` check before `.Value()`. Unlike go-redis where `.Result()` returns `(T, error)` with `redis.Nil` as a sentinel error.
3. **Flat error model - no hierarchy.** `ConnectionError`, `TimeoutError`, `DisconnectError`, `ExecAbortError`, `ClosingError`, `ConfigurationError`, `BatchError` are independent structs. Python's `except RequestError:` pattern does NOT translate - you can't catch a whole category with one `errors.As`.
4. **Only 3 errors auto-typed.** `go/errors.go:GoError()` maps ONLY `ExecAbort`, `Timeout`, `Disconnect` to typed errors. Everything else falls through to generic `errors.New(msg)`. So `errors.As(err, &connErr)` with `*ConnectionError` may miss most "connection lost" cases that arrive as `*DisconnectError` or plain strings.
5. **`GetStatistics() map[string]uint64`.** Typed uint64 values, not strings like Python/Node. Still exposes the same counter keys (`total_connections`, `total_clients`, compression counters, `subscription_out_of_sync_count`, etc.).
6. **`ResetConnectionPassword(ctx)` is a separate method**, unlike Python's `update_connection_password(None)`. The `UpdateConnectionPassword(ctx, pw, immediateAuth)` method does not accept an empty string to clear.
7. **CGO is mandatory.** Requires glibc 2.17+ and a C toolchain. No pure-Go build. Alpine needs `musl-gcc` or use Debian base.
8. **`context.Context` is the first arg to every command method.** Unlike go-redis's `rdb.Get(ctx, key)` (same pattern) but unlike Python/Node (no ctx).
9. **`AzAffinityReplicaAndPrimary`** - singular `Replica` in the enum name (`go/config/config.go:169`). Matches the protobuf name `AZAffinityReplicasAndPrimary` internally despite the user-facing enum being singular.
10. **Configure deadlines via `context.WithTimeout`**, not just `WithRequestTimeout`. Both work; context takes precedence and is Go-idiomatic.

## Cross-references

- `migrate-go-redis` - migrating from go-redis
- `glide-dev` - GLIDE core internals (Rust), binding mechanics
- `valkey` - Valkey commands and app patterns
