---
name: valkey-glide-csharp
description: "Use when building C# / .NET 8+ apps with Valkey GLIDE - async/await API, GlideClient, GlideClusterClient, ConnectionMultiplexer facade, SE.Redis-compatible method names, ValkeyKey/ValkeyValue primitives, multiplexer behavior. Covers the divergence from StackExchange.Redis; basic command shapes are assumed knowable from training. Not for SE.Redis migration - use migrate-stackexchange."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE C# Client

Agent-facing skill for GLIDE C#. Assumes the reader can already write basic StackExchange.Redis from training (`db.StringSetAsync`, `ConnectionMultiplexer.Connect`, `IDatabase`, `RedisKey`/`RedisValue`). Covers only what diverges and what GLIDE adds on top.

**Separate repository:** [valkey-io/valkey-glide-csharp](https://github.com/valkey-io/valkey-glide-csharp). GA at `v1.0.0` (not preview).

Package: `dotnet add package Valkey.Glide`.

## Routing

| Question | Reference |
|----------|-----------|
| `GlideClient` vs `GlideClusterClient`, TLS, auth, IAM, lazy connect, AZ affinity, `ConnectionMultiplexer` facade | [connection](reference/features-connection.md) |
| PubSub: static config vs dynamic `SubscribeAsync` (2.3+), `PublishAsync` arg order (NOT reversed), sharded | [pubsub](reference/features-pubsub.md) |
| Command groups, platform support, `ValkeyKey`/`ValkeyValue`, error hierarchy, GA status | [overview](reference/features-overview.md) |

## Multiplexer rule (the #1 agent mistake)

One `GlideClient` / `GlideClusterClient` per process (or one `ConnectionMultiplexer` if using the SE.Redis facade). Shared across every task. Do not create per-request clients. Do not pool them.

**Exceptions that need a dedicated client:**

- Blocking commands: `ListLeftPopAsync` / `ListRightPopAsync` with `timeout`, `SortedSetPopAsync` with `timeout`, plus `StreamReadAsync` / `StreamReadGroupAsync` with block.
- WATCH / MULTI / EXEC transactions (connection-state commands).
- Long-running PubSub polling.

## Grep hazards

1. **`PublishAsync(channel, message)` - NOT reversed** like Python/Node GLIDE. C# matches the Redis / StackExchange.Redis convention. `await client.PublishAsync(channel, message)`.
2. **`ValkeyKey` / `ValkeyValue` types, NOT `RedisKey`/`RedisValue`.** Otherwise SE.Redis-compatible primitives with implicit conversions from `string` / `byte[]`.
3. **Method names are SE.Redis-style, NOT GLIDE-invented.** The API uses `SetAsync` / `GetAsync` (not `StringSetAsync`/`StringGetAsync`), `ListLeftPushAsync` / `ListRightPushAsync` / `ListLeftPopAsync` / `ListRightPopAsync` (not `ListPushAsync`/`ListPopAsync`), `HashSetAsync` / `HashGetAsync`, `SortedSetAddAsync` / `SortedSetRangeAsync`, `StreamAddAsync` / `StreamReadAsync`, `ScriptEvaluateAsync`.
4. **Error classes nested in `Errors` static class.** `Valkey.Glide.Errors.GlideException` (abstract base), `Errors.RequestException`, `Errors.ValkeyServerException` (NOT `ValkeyException`), `Errors.ExecAbortException`, `Errors.TimeoutException`, `Errors.ConnectionException`, `Errors.ConfigurationError` (note "Error" suffix, not "Exception").
5. **`ConnectionMultiplexer` facade exists** for SE.Redis compatibility. Two entry points: GLIDE-native `GlideClient.CreateClient(config)` OR SE.Redis-compatible `ConnectionMultiplexer.ConnectAsync("localhost:6379")`. Same underlying multiplexer.
6. **Builder pattern for GLIDE-native path**: `StandaloneClientConfigurationBuilder` / `ClusterClientConfigurationBuilder` with fluent `WithAddress()`, `WithTls()`, `WithAuthentication()`, `WithReadFrom()`, `WithLazyConnect()`, `.Build()`.
7. **No Alpine / MUSL support** - glibc 2.17+ required.
8. **Reconnection is infinite.** `RetryStrategy` caps backoff sequence length only.
9. **`await using var client = ...`** pattern: client implements `IAsyncDisposable`. Always prefer over manual dispose.
10. **Static subscriptions require RESP3.** Using RESP2 raises `ConfigurationError`.

## Cross-references

- `migrate-stackexchange` - migrating from StackExchange.Redis
- `glide-dev` - GLIDE core internals (Rust) and P/Invoke binding mechanics
- `valkey` - Valkey commands and app patterns
