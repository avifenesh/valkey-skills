---
name: migrate-stackexchange
description: "Use when migrating C#/.NET from StackExchange.Redis to Valkey GLIDE. Covers API mapping, async/await Task, no IDatabase layer, PubSub, Batch API (.NET 8.0+, preview). Not for greenfield C# apps - use valkey-glide-csharp instead."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from StackExchange.Redis to Valkey GLIDE (C#)

Use when migrating a .NET application from StackExchange.Redis to the GLIDE client library.

**Status**: The GLIDE C# client is in preview (requires .NET 8.0+). APIs may change before GA.

## Routing

- String, hash, list, set, sorted set, delete, exists, cluster -> API Mapping
- Transaction, Batch API, fire-and-forget -> Advanced Patterns
- PubSub, subscribe, publish -> Advanced Patterns
- Key types, API compatibility, ecosystem -> Advanced Patterns

## Key Differences

| Area | StackExchange.Redis | GLIDE |
|------|---------------------|-------|
| Connection | `ConnectionMultiplexer.Connect()` | `GlideClient.CreateClient(config)` |
| Operations | `IDatabase` methods | Direct client methods |
| Async model | `async/await` with `Task<T>` | `async/await` with `Task<T>` (similar) |
| Configuration | Connection string or `ConfigurationOptions` | `StandaloneClientConfigurationBuilder` |
| Fire-and-forget | `CommandFlags.FireAndForget` | Not supported - all commands return results |
| Keys/values | `RedisKey` / `RedisValue` types | Strings |
| Transactions | `ITransaction` with conditions | `Batch` API |
| Connection model | Multiplexed | Multiplexed (single connection per node) |

Both libraries use multiplexed connections and async/await.

## Quick Start - Connection Setup

**StackExchange.Redis:**
```csharp
var muxer = ConnectionMultiplexer.Connect("localhost:6379");
IDatabase db = muxer.GetDatabase();
```

**GLIDE:**
```csharp
var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379).Build();
await using var client = await GlideClient.CreateClient(config);
```

No `IDatabase` layer - commands are called directly on the client instance.

## Configuration Mapping

| StackExchange.Redis | GLIDE equivalent |
|---------------------|------------------|
| `EndPoints.Add(host, port)` | `.WithAddress(host, port)` |
| `Password` | `.WithCredentials(username, password)` |
| `DefaultDatabase` | `.WithDatabaseId(id)` |
| `Ssl = true` | `.WithTls(true)` |
| `ConnectTimeout` | `.WithRequestTimeout(ms)` |
| `SyncTimeout` | Part of `WithRequestTimeout` |
| `AllowAdmin` | Not applicable |
| `AbortOnConnectFail` | GLIDE always retries - configure via backoff strategy |

## Incremental Migration Strategy

No drop-in compatibility layer exists for C#. The GLIDE C# client intentionally mirrors StackExchange.Redis naming to reduce effort. Migration approach:

1. Add `Valkey.Glide` NuGet package alongside `StackExchange.Redis`
2. Create a service interface abstracting your Redis operations
3. Implement the interface with GLIDE, replacing `IDatabase` calls with direct client calls
4. Replace `RedisKey`/`RedisValue` types with plain strings
5. Remove `CommandFlags.FireAndForget` usage - use batching for throughput
6. Migrate one service at a time and run integration tests
7. Remove `StackExchange.Redis` NuGet package once all services are migrated

GLIDE C# is in preview - evaluate feature coverage before committing to production migration.

## Reference

| Topic | File |
|-------|------|
| Command-by-command API mapping (strings, hashes, lists, sets, sorted sets, delete, exists, cluster) | [api-mapping](reference/api-mapping.md) |
| Transactions, Pub/Sub, key types, fire-and-forget, API compatibility | [advanced-patterns](reference/advanced-patterns.md) |

## See Also

- **valkey-glide-csharp** skill - full GLIDE C# API details
- Batching (see valkey-glide skill) - pipeline and transaction patterns
- PubSub (see valkey-glide skill) - subscription patterns and dynamic PubSub

## Gotchas

1. **Preview status.** Not production-ready. Check [GLIDE C# releases](https://www.nuget.org/packages/Valkey.Glide) for the latest API surface.
2. **Separate client types.** StackExchange.Redis auto-detects cluster mode. GLIDE requires `GlideClient` or `GlideClusterClient` explicitly.
3. **No `IDatabase` layer.** Commands are on the client directly. No `GetDatabase(n)` - set database in configuration.
4. **No `RedisKey`/`RedisValue` wrappers.** GLIDE uses plain strings.
5. **No fire-and-forget.** All commands are awaitable. Use batching for throughput.
6. **.NET 8.0+ required.** Earlier .NET versions are not supported.
7. **Platform support.** Pre-built native libraries for Linux (x86_64, arm64), macOS, and Windows.
8. **API stability.** Method signatures may change between releases. Pin the dependency version.
9. **Ecosystem gap.** StackExchange.Redis has 597M+ NuGet downloads. Evaluate feature coverage carefully.
