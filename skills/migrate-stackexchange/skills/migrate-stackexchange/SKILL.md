---
name: migrate-stackexchange
description: "Use when migrating C# / .NET from StackExchange.Redis to Valkey GLIDE. Covers two entry points (ConnectionMultiplexer facade vs GLIDE-native builder), ValkeyKey/ValkeyValue rename, method-name parity, no fire-and-forget, Errors static class hierarchy. Not for greenfield C# - use valkey-glide-csharp."
version: 1.1.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from StackExchange.Redis to Valkey GLIDE (C#)

Use when moving an existing StackExchange.Redis app to GLIDE. Assumes you already know SE.Redis. GLIDE C# is GA at v1.0.0 on NuGet as `Valkey.Glide` and ships a deliberate SE.Redis-compatible surface to minimize migration effort. This skill covers the deltas; most method names already match.

## Divergences that actually matter

| Area | StackExchange.Redis | GLIDE C# |
|------|---------------------|---------|
| Entry point | `ConnectionMultiplexer.Connect(connString)` | Two options: (1) `ConnectionMultiplexer.ConnectAsync(connString)` - SE.Redis-compat facade, OR (2) `GlideClient.CreateClient(config)` / `GlideClusterClient.CreateClient(config)` with fluent builder |
| Connect | `Connect(connString)` or `ConnectAsync(...)` | Facade has both `Connect(connString)` and `ConnectAsync(...)`; GLIDE-native `CreateClient(config)` is async-only |
| Client type | Auto-detects cluster vs standalone | GLIDE-native path requires explicit `GlideClient` vs `GlideClusterClient`. Facade path auto-detects like SE.Redis |
| Key / value types | `RedisKey`, `RedisValue` | **`ValkeyKey`, `ValkeyValue`** - drop-in equivalents with the same implicit conversions |
| Access pattern | `IDatabase db = mux.GetDatabase()` then `db.StringSetAsync(...)` | GLIDE-native: methods on `client` directly; facade: `mux.GetDatabase()` works the same |
| `CommandFlags.FireAndForget` | Supported | **NOT supported** - all commands return `Task<T>`. Use batching for throughput |
| Configuration | `ConfigurationOptions` or connection string | `StandaloneClientConfigurationBuilder` / `ClusterClientConfigurationBuilder` fluent builder (or connection string through the facade) |
| `AbortOnConnectFail` | Option | No equivalent - GLIDE retries infinitely; cap backoff sequence with `RetryStrategy` |
| Connection pool | `syncTimeout`, response pool | Multiplexer - single multiplexed connection per node |
| Events | `OnConnectionFailed`, `OnConnectionRestored`, etc. | No EventEmitter-style events - errors surface per-Task; track state via `client.GetStatistics()` |
| Transactions | `ITransaction tx = db.CreateTransaction(); tx.AddCondition(...)` | `Batch(isAtomic: true)` + `client.ExecAsync(batch, raiseOnError)` |
| Pipelines | `db.Batch()` + chained awaits | `Batch(isAtomic: false)` - same class, flag-selected |
| `RedisSubscriber` | `var sub = mux.GetSubscriber(); sub.Subscribe(ch, (ch, msg) => ...)` | Static config on builder OR dynamic `client.SubscribeAsync(ch, timeout)`; callback OR polling |
| `sub.Publish(channel, message)` | Channel first | `client.PublishAsync(channel, message)` - **SAME ORDER** (Python/Node GLIDE reverse it; C# matches SE.Redis) |
| Error types | `RedisException`, `RedisConnectionException`, `RedisTimeoutException`, etc. | Nested in static `Errors` class: `Errors.GlideException` (abstract base), `Errors.RequestException`, `Errors.ValkeyServerException`, `Errors.ExecAbortException`, `Errors.TimeoutException`, `Errors.ConnectionException`, `Errors.ConfigurationError` (note inconsistent "Error" suffix on the last one) |
| `RedisResult` | Dynamic typed result | Methods return typed `Task<ValkeyValue>`, `Task<bool>`, `Task<long>`, etc. |
| `CommandMap` (command renaming) | Supported | Not supported |

## Config translation

```csharp
// SE.Redis:
var mux = ConnectionMultiplexer.Connect(
    "localhost:6379,password=pw,ssl=true,connectTimeout=5000,syncTimeout=5000");
IDatabase db = mux.GetDatabase();

// GLIDE - facade path (minimal change):
var mux = await ConnectionMultiplexer.ConnectAsync(
    "localhost:6379,password=pw,ssl=true");
IDatabase db = mux.GetDatabase();  // standard IConnectionMultiplexer method

// GLIDE - native builder path (more control):
var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .WithAuthentication("default", "pw")
    .WithTls()
    .WithRequestTimeout(TimeSpan.FromSeconds(5))
    .Build();
await using var client = await GlideClient.CreateClient(config);
```

## Method names - mostly the same, with a twist

GLIDE C# mirrors SE.Redis naming for most commands. Where it differs, the difference usually is dropping a redundant `<Type>` prefix:

| SE.Redis | GLIDE C# |
|----------|---------|
| `db.StringSetAsync(k, v)` / `StringGetAsync(k)` | `client.SetAsync(k, v)` / `GetAsync(k)` - `String*` prefix dropped |
| `db.StringSetBitAsync` / `StringGetBitAsync` / `StringBitCountAsync` | SAME names - `String*` prefix kept for bitmap ops |
| `db.HashSetAsync` / `HashGetAsync` / `HashGetAllAsync` | SAME names |
| `db.ListLeftPushAsync` / `ListRightPushAsync` / `ListLeftPopAsync` / `ListRightPopAsync` | SAME names |
| `db.SetAddAsync` / `SetMembersAsync` / `SetIsMemberAsync` | SAME names |
| `db.SortedSetAddAsync` / `SortedSetRangeAsync` | SAME names |
| `db.StreamAddAsync` / `StreamReadAsync` | SAME names |
| `db.KeyDeleteAsync` / `KeyExistsAsync` / `KeyExpireAsync` | SAME names |
| `sub.Publish` / `Subscribe` | `PublishAsync` / `SubscribeAsync` (suffix `Async`) |

When in doubt, the SE.Redis method name is likely correct; grep `sources/Valkey.Glide/Client/BaseClient.*Commands.cs` for exact signatures.

## Migration strategy

Two routes:

1. **Fast swap (facade path)**: replace `ConnectionMultiplexer.Connect` with `ConnectionMultiplexer.ConnectAsync`, rename `RedisKey` -> `ValkeyKey` and `RedisValue` -> `ValkeyValue` wholesale. Most call sites work unchanged. Fire-and-forget calls need rewriting to batches.
2. **Progressive rewrite (native path)**: add a service interface; implement both SE.Redis and GLIDE-native sides; swap per service behind a flag. Most useful when you want explicit standalone-vs-cluster typing or the full GLIDE-specific builder options (IAM, AZ affinity, compression).

## Reference

| Topic | File |
|-------|------|
| Method-name mapping with the SE.Redis naming compatibility table, key types, cluster | [api-mapping](reference/api-mapping.md) |
| Batch API (replaces `ITransaction`), Pub/Sub migration, no-fire-and-forget, ecosystem notes | [advanced-patterns](reference/advanced-patterns.md) |

## Gotchas (the short list)

1. **GA at v1.0.0** - not preview. Older docs claiming preview status are outdated.
2. **`ConnectionMultiplexer` facade has both** `Connect(connString)` and `ConnectAsync(...)` - same as SE.Redis. GLIDE-native `GlideClient.CreateClient(config)` is async-only.
3. **`ValkeyKey` / `ValkeyValue`** (not `RedisKey`/`RedisValue`). Rename, then most code still compiles.
4. **No `CommandFlags.FireAndForget`** - all commands return `Task<T>`. Use batching for throughput.
5. **`IDatabase` is ONLY available via the `ConnectionMultiplexer` facade.** GLIDE-native clients expose commands directly on the client.
6. **`PublishAsync(channel, message)` - SAME ORDER** as SE.Redis. Python/Node GLIDE reverse it; C# does NOT.
7. **Error types nested in `Errors` static class.** Use `Errors.ConnectionException`, `Errors.TimeoutException`, `Errors.ValkeyServerException` (NOT `ValkeyException`), `Errors.GlideException` (abstract base). `Errors.ConfigurationError` uses "Error" suffix.
8. **No `IDatabase.GetDatabase(n)` multiple databases** on GLIDE-native path. Set `WithDatabaseId(n)` in config; one client = one database.
9. **Reconnection is infinite** - no `AbortOnConnectFail` equivalent.
10. **.NET 8.0+ required**. No .NET Framework, no .NET Standard.
11. **No Alpine / MUSL support**. glibc 2.17+ required.
12. **No `CommandMap` command renaming**.

## Cross-references

- `valkey-glide-csharp` - full C# skill for GLIDE features beyond the migration scope
- `glide-dev` - GLIDE core internals (Rust) and P/Invoke binding mechanics
