---
name: migrate-stackexchange
description: "Use when migrating C#/.NET applications from StackExchange.Redis to Valkey GLIDE. Covers API mapping, configuration changes, connection setup, error handling differences, and common migration gotchas."
version: 1.0.0
argument-hint: "[API or pattern to migrate]"
---

# Migrating from StackExchange.Redis to Valkey GLIDE (C#)

Use when migrating a .NET application from StackExchange.Redis to the GLIDE client library.

**Status**: The GLIDE C# client is in preview (requires .NET 8.0+). APIs may change before GA.

---

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

Both libraries use multiplexed connections and async/await - the programming model is similar.

---

## Connection Setup

**StackExchange.Redis:**
```csharp
using StackExchange.Redis;

// Connection string
var muxer = ConnectionMultiplexer.Connect("localhost:6379");
IDatabase db = muxer.GetDatabase();

// Or ConfigurationOptions
var options = new ConfigurationOptions
{
    EndPoints = { "localhost:6379" },
    Password = "secret",
    DefaultDatabase = 0,
    Ssl = true,
};
var muxer = ConnectionMultiplexer.Connect(options);
IDatabase db = muxer.GetDatabase();
```

**GLIDE:**
```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .Build();

await using var client = await GlideClient.CreateClient(config);
```

GLIDE has no `IDatabase` layer. Commands are called directly on the client instance.

---

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

---

## String Operations

**StackExchange.Redis:**
```csharp
await db.StringSetAsync("key", "value");
await db.StringSetAsync("key", "value", TimeSpan.FromSeconds(60));
await db.StringSetAsync("key", "value", when: When.NotExists);
RedisValue val = await db.StringGetAsync("key");
string str = val.ToString();
```

**GLIDE:**
```csharp
await client.Set("key", "value");
// Expiry and conditional set use options (API may vary in preview)
var val = await client.GetAsync("key");
```

---

## Hash Operations

**StackExchange.Redis:**
```csharp
await db.HashSetAsync("hash", new HashEntry[] {
    new HashEntry("f1", "v1"),
    new HashEntry("f2", "v2"),
});
RedisValue val = await db.HashGetAsync("hash", "f1");
HashEntry[] all = await db.HashGetAllAsync("hash");
```

**GLIDE:**
```csharp
// Hash commands use field-value pairs
await client.HSet("hash", new Dictionary<string, string> {
    { "f1", "v1" },
    { "f2", "v2" },
});
var val = await client.HGet("hash", "f1");
```

---

## List Operations

**StackExchange.Redis:**
```csharp
await db.ListLeftPushAsync("list", new RedisValue[] { "a", "b", "c" });
await db.ListRightPushAsync("list", "x");
RedisValue val = await db.ListLeftPopAsync("list");
RedisValue[] range = await db.ListRangeAsync("list", 0, -1);
```

**GLIDE:**
```csharp
await client.LPush("list", new string[] { "a", "b", "c" });
await client.RPush("list", new string[] { "x" });
var val = await client.LPop("list");
```

---

## Set Operations

**StackExchange.Redis:**
```csharp
await db.SetAddAsync("set", new RedisValue[] { "a", "b", "c" });
await db.SetRemoveAsync("set", "a");
RedisValue[] members = await db.SetMembersAsync("set");
bool isMember = await db.SetContainsAsync("set", "b");
```

**GLIDE:**
```csharp
await client.SAdd("set", new string[] { "a", "b", "c" });
await client.SRem("set", new string[] { "a" });
```

---

## Sorted Set Operations

**StackExchange.Redis:**
```csharp
await db.SortedSetAddAsync("zset", new SortedSetEntry[] {
    new SortedSetEntry("alice", 1.0),
    new SortedSetEntry("bob", 2.0),
});
double? score = await db.SortedSetScoreAsync("zset", "alice");
```

**GLIDE:**
```csharp
// Sorted set commands accept member-score mappings
await client.ZAdd("zset", new Dictionary<string, double> {
    { "alice", 1.0 },
    { "bob", 2.0 },
});
```

---

## Delete and Exists

**StackExchange.Redis:**
```csharp
await db.KeyDeleteAsync(new RedisKey[] { "k1", "k2", "k3" });
bool exists = await db.KeyExistsAsync("k1");
```

**GLIDE:**
```csharp
await client.Del(new string[] { "k1", "k2", "k3" });
var exists = await client.Exists(new string[] { "k1" });
```

---

## Cluster Mode

**StackExchange.Redis:**
```csharp
// StackExchange.Redis auto-detects cluster mode
var options = new ConfigurationOptions
{
    EndPoints = {
        { "node1.example.com", 6379 },
        { "node2.example.com", 6380 },
    },
};
var muxer = ConnectionMultiplexer.Connect(options);
```

**GLIDE:**
```csharp
var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithAddress("node2.example.com", 6380)
    .Build();

await using var client = await GlideClusterClient.CreateClient(config);
```

StackExchange.Redis auto-detects standalone vs cluster mode. GLIDE uses separate client types: `GlideClient` for standalone and `GlideClusterClient` for cluster.

---

## Transactions

**StackExchange.Redis:**
```csharp
var tran = db.CreateTransaction();
tran.AddCondition(Condition.KeyNotExists("key"));
_ = tran.StringSetAsync("key", "value");
_ = tran.StringGetAsync("key");
bool committed = await tran.ExecuteAsync();
```

**GLIDE:**
```csharp
// Batch API (when available in C# client)
// Atomic batch = transaction, non-atomic batch = pipeline
```

Note: The C# Batch API is being developed. Check the latest GLIDE C# release notes for current transaction support.

---

## Pub/Sub

**StackExchange.Redis:**
```csharp
var sub = muxer.GetSubscriber();
await sub.SubscribeAsync("channel", (channel, message) => {
    Console.WriteLine($"{channel}: {message}");
});
await sub.PublishAsync("channel", "hello");
```

**GLIDE:**
Pub/Sub in the GLIDE C# client follows the same pattern as other GLIDE languages - subscriptions are configured at client creation time or via dynamic `subscribe()` (GLIDE 2.3+). Message reception uses either callback or queue-based approaches.

---

## Key Type Differences

**StackExchange.Redis** uses `RedisKey` and `RedisValue` as wrapper types with implicit conversions from strings. These support both string and binary data with operator overloads.

**GLIDE** uses plain strings for keys and values. Binary data is handled through `GlideString` where needed.

This means migration typically simplifies code - fewer explicit conversions and wrapper types.

---

## Fire-and-Forget

**StackExchange.Redis:**
```csharp
db.StringSet("key", "value", flags: CommandFlags.FireAndForget);
```

**GLIDE** does not support fire-and-forget. Every command returns a result that should be awaited. If you used fire-and-forget for performance, consider batching commands instead - non-atomic batches provide similar throughput benefits.

---

## API Compatibility Approach

The C# GLIDE client intentionally mirrors StackExchange.Redis naming conventions (`ConnectionMultiplexer`, `StringSetAsync`, `StringGetAsync`) to ease migration. The README states: "API Compatibility: Compatible with StackExchange.Redis APIs to ease migration."

A significant community discussion debated how closely GLIDE should match existing client APIs. Key positions from that debate:

- **Pro-compatibility** (from AWS/GCP stakeholders): Reducing migration effort drives adoption.
- **Anti-compatibility** (from core architect): GLIDE's thin-binding architecture means foreign interfaces would break the design. Recommended dedicated **Adapters** that translate foreign interfaces rather than modifying GLIDE core.
- **Tooling approach**: A .NET Roslyn-based migration tool could automate code transformation.

The client has been moved to a separate repository: https://github.com/valkey-io/valkey-glide-csharp

---

## Incremental Migration Strategy

No drop-in compatibility layer exists for C#, though the GLIDE C# client intentionally mirrors StackExchange.Redis naming to reduce effort. The recommended approach:

1. Add `Valkey.Glide` NuGet package alongside `StackExchange.Redis`
2. Create a service interface abstracting your Redis operations
3. Implement the interface with GLIDE, replacing `IDatabase` method calls with direct client calls
4. Replace `RedisKey`/`RedisValue` types with plain strings at each call site
5. Remove `CommandFlags.FireAndForget` usage - use batching for throughput instead
6. Migrate one service at a time and run integration tests after each
7. Remove `StackExchange.Redis` NuGet package once all services are migrated
8. Review `best-practices/production.md` for timeout tuning, connection management, and observability setup

**Important**: Since GLIDE C# is in preview, evaluate feature coverage against your usage before committing to migration in production.

---

## See Also

- **valkey-glide-csharp** skill - full GLIDE C# API details
- [Batching](../features/batching.md) - pipeline and transaction patterns
- [PubSub](../features/pubsub.md) - subscription patterns and dynamic PubSub
- [TLS and authentication](../features/tls-auth.md) - TLS setup and credential management
- [Production deployment](../best-practices/production.md) - timeout tuning, connection management, observability
- [Error handling](../best-practices/error-handling.md) - error types, reconnection, batch error semantics

---

## Gotchas

1. **Preview status.** The GLIDE C# client is in preview - not recommended for production. Many features remain unimplemented before GA. Check the [GLIDE C# releases](https://www.nuget.org/packages/Valkey.Glide) for the latest API surface.

2. **Separate client types.** StackExchange.Redis auto-detects cluster mode. GLIDE requires you to choose `GlideClient` (standalone) or `GlideClusterClient` (cluster) explicitly.

3. **No `IDatabase` layer.** Commands are on the client directly. No `GetDatabase(n)` - set the database in configuration.

4. **No `RedisKey`/`RedisValue` wrappers.** GLIDE uses plain strings. This simplifies code but means you lose implicit conversions.

5. **No fire-and-forget.** All commands are awaitable. Use batching for throughput optimization.

6. **.NET 8.0+ required.** The GLIDE C# client targets .NET 8.0 and above. Earlier .NET versions are not supported.

7. **Platform support.** The C# client ships pre-built native libraries for Linux (x86_64, arm64), macOS (Apple Silicon, x86_64), and Amazon Linux. Windows support is available for the C# client.

8. **API stability.** Being in preview, method signatures may change between releases. Pin your dependency version and review changelogs before upgrading.

9. **StackExchange.Redis ecosystem size.** StackExchange.Redis has 6,000 GitHub stars, 597M+ NuGet downloads, and 206 contributors. The GLIDE C# client is comparatively early-stage - evaluate feature coverage against your specific usage patterns before committing to migration.
