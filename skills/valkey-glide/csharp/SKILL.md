---
name: valkey-glide-csharp
description: "Use when building C#/.NET applications with Valkey GLIDE. Covers async/await API, .NET 6.0+/8.0+, configuration builders, and migration from StackExchange.Redis. Preview status."
version: 1.0.0
last-verified: 2026-03-30
argument-hint: "[API, config, or migration question]"
---

# Valkey GLIDE C# Client Reference

Async/await C# client for Valkey built on the GLIDE Rust core via native interop. Currently in **preview** - API may change before GA. For architecture concepts shared across all languages, see the `valkey-glide` skill.

## Routing

- Install/setup -> Installation
- Async API -> Client Classes, Basic Operations
- TLS/auth -> TLS and Authentication
- Streams -> Streams
- Error handling -> Error Handling
- StackExchange.Redis migration -> Migration from StackExchange.Redis

**Separate repository:** [valkey-io/valkey-glide-csharp](https://github.com/valkey-io/valkey-glide-csharp)

## Installation

```bash
dotnet add package Valkey.Glide
```

**Requirements:** .NET 6.0+ or .NET 8.0+

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64), Windows (x86_64). No Alpine/MUSL support.

---

## Client Classes

| Class | Namespace | Mode | Description |
|-------|-----------|------|-------------|
| `GlideClient` | `Valkey.Glide` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | `Valkey.Glide` | Cluster | Valkey Cluster with auto-topology |

Both use the standard C# async/await pattern with `Task<T>` return types.

---

## Standalone Connection

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .Build();

await using var client = await GlideClient.CreateClient(config);

await client.SetAsync("greeting", "Hello from GLIDE");
var value = await client.GetAsync("greeting");
Console.WriteLine($"Got: {value}");
```

`GlideClient` implements `IAsyncDisposable` - use `await using` for automatic cleanup.

---

## Cluster Connection

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithAddress("node2.example.com", 6380)
    .Build();

await using var client = await GlideClusterClient.CreateClient(config);

await client.SetAsync("key", "value");
var value = await client.GetAsync("key");
Console.WriteLine($"Got: {value}");
```

Only seed addresses are needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration

Configuration uses the builder pattern with `StandaloneClientConfigurationBuilder` and `ClusterClientConfigurationBuilder`.

### StandaloneClientConfigurationBuilder

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .WithTls(true)
    .WithCredentials("myuser", "mypass")
    .WithRequestTimeout(5000)
    .WithDatabaseId(0)
    .WithClientName("my-app")
    .Build();
```

### ClusterClientConfigurationBuilder

```csharp
var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithAddress("node2.example.com", 6380)
    .WithReadFrom(ReadFrom.PreferReplica)
    .Build();
```

### Authentication

```csharp
// Password only
builder.WithCredentials(password: "mypass")

// Username + password
builder.WithCredentials("myuser", "mypass")
```

### ReadFrom

| Value | Behavior |
|-------|----------|
| `ReadFrom.Primary` | All reads to primary (default) |
| `ReadFrom.PreferReplica` | Round-robin replicas, fallback to primary |
| `ReadFrom.AzAffinity` | Prefer same-AZ replicas |
| `ReadFrom.AzAffinityReplicasAndPrimary` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ with the client AZ configured.

---

## Error Handling

The C# client throws exceptions on errors. Use standard try-catch patterns:

```csharp
try
{
    var value = await client.GetAsync("key");
    if (value == null)
    {
        Console.WriteLine("Key does not exist");
    }
}
catch (RequestException ex)
{
    Console.WriteLine($"Request failed: {ex.Message}");
}
catch (TimeoutException ex)
{
    Console.WriteLine("Request timed out");
}
catch (ConnectionException ex)
{
    Console.WriteLine("Connection lost - client is reconnecting");
}
```

---

## Basic Operations

### Strings

```csharp
await client.SetAsync("key", "value");
var value = await client.GetAsync("key");  // "value" or null

await client.SetAsync("counter", "0");
var count = await client.IncrAsync("counter");  // 1
```

### Multiple Keys

```csharp
await client.SetAsync("k1", "v1");
await client.SetAsync("k2", "v2");

var values = await client.MGetAsync(new[] { "k1", "k2", "missing" });
// ["v1", "v2", null]
```

### Key Expiration

```csharp
await client.SetAsync("session", "data");
await client.ExpireAsync("session", 3600);  // 1 hour TTL
var ttl = await client.TTLAsync("session");
```

### Streams

```csharp
// Add entry
var entryId = await client.XAddAsync("mystream", new Dictionary<string, string> {
    { "sensor", "temp" }, { "value", "23.5" },
});

// Read entries
var entries = await client.XReadAsync(new Dictionary<string, string> {
    { "mystream", "0" },
});

// Consumer group
await client.XGroupCreateAsync("mystream", "mygroup", "0");
var messages = await client.XReadGroupAsync("mygroup", "consumer1",
    new Dictionary<string, string> { { "mystream", ">" } });
var ackCount = await client.XAckAsync("mystream", "mygroup",
    new[] { "1234567890123-0" });
```

---

## Return Types

- String commands return `string?` - `null` when key does not exist
- Numeric commands return `long` or `double`
- `SetAsync` returns `string` (`"OK"` on success)
- Multi-key commands return arrays (e.g., `MGetAsync` returns `string?[]`)

---

## Async/Await Pattern

All command methods return `Task<T>` and follow C# async conventions:

```csharp
// Sequential
await client.SetAsync("key", "value");
var value = await client.GetAsync("key");

// Concurrent
var task1 = client.SetAsync("k1", "v1");
var task2 = client.SetAsync("k2", "v2");
await Task.WhenAll(task1, task2);

// With cancellation
using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
try
{
    var value = await client.GetAsync("key");
}
catch (OperationCanceledException)
{
    Console.WriteLine("Operation was cancelled");
}
```

---

## Migration from StackExchange.Redis

### Key Differences

| Area | StackExchange.Redis | GLIDE |
|------|---------------------|-------|
| Connection | `ConnectionMultiplexer.Connect()` | `GlideClient.CreateClient(config)` |
| Operations | `IDatabase` methods | Direct client methods |
| Configuration | Connection string or `ConfigurationOptions` | `StandaloneClientConfigurationBuilder` |
| Fire-and-forget | `CommandFlags.FireAndForget` | Not supported - all commands return results |
| Keys/values | `RedisKey` / `RedisValue` types | Strings |
| Transactions | `ITransaction` with conditions | Not yet available |

Both libraries use multiplexed connections and async/await - the programming model is similar.

### Connection Setup

**StackExchange.Redis:**
```csharp
using StackExchange.Redis;

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

### Configuration Mapping

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

### String Operations

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
await client.SetAsync("key", "value");
var val = await client.GetAsync("key");
```

### Hash Operations

**StackExchange.Redis:**
```csharp
await db.HashSetAsync("hash", new HashEntry[] {
    new HashEntry("f1", "v1"),
    new HashEntry("f2", "v2"),
});
RedisValue val = await db.HashGetAsync("hash", "f1");
```

**GLIDE:**
```csharp
await client.HSetAsync("hash", new Dictionary<string, string> {
    { "f1", "v1" },
    { "f2", "v2" },
});
var val = await client.HGetAsync("hash", "f1");
```

### Other Data Types

The pattern is consistent - `RedisValue[]`/`RedisKey[]` become `string[]`, and typed wrappers become `Dictionary`:

```csharp
// StackExchange.Redis                               // GLIDE
db.ListLeftPushAsync("l", new RedisValue[]{"a"})     await client.LPushAsync("l", new string[]{"a"})
db.SetAddAsync("s", new RedisValue[]{"a"})           await client.SAddAsync("s", new string[]{"a"})
db.KeyDeleteAsync(new RedisKey[]{"k1","k2"})         await client.DelAsync(new string[]{"k1","k2"})
db.SortedSetAddAsync("z", new SortedSetEntry[]{      await client.ZAddAsync("z", new Dictionary<string,double>{
    new("alice", 1.0)})                                  {"alice", 1.0}})
```

### Cluster Mode

StackExchange.Redis auto-detects cluster mode. GLIDE requires separate types:

```csharp
var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithAddress("node2.example.com", 6380)
    .Build();
await using var client = await GlideClusterClient.CreateClient(config);
```

---

## Migration Gotchas

1. **Preview status.** The GLIDE C# client is in preview - API may change between releases. Pin your dependency version and review changelogs before upgrading.

2. **Separate client types.** StackExchange.Redis auto-detects cluster mode. GLIDE requires you to choose `GlideClient` or `GlideClusterClient` explicitly.

3. **No `IDatabase` layer.** Commands are on the client directly. No `GetDatabase(n)` - set the database in configuration.

4. **No `RedisKey`/`RedisValue` wrappers.** GLIDE uses plain strings. This simplifies code but means you lose implicit conversions.

5. **No fire-and-forget.** All commands are awaitable. Use batching for throughput optimization.

6. **.NET 6.0+ or .NET 8.0+ required.** Targets both `net6.0` and `net8.0` frameworks.

7. **Batch/transaction API not yet available.** Being developed for the C# client.

---

## Incremental Migration Strategy

Add `Valkey.Glide` NuGet alongside `StackExchange.Redis`. Create a service interface abstracting Redis operations, then implement it with GLIDE one service at a time. Replace `RedisKey`/`RedisValue` with strings and remove `FireAndForget` usage at each call site. Since GLIDE C# is in preview, evaluate feature coverage before committing to production migration.

---

## Missing Features for GA

MUSL/Alpine support, `Span<T>`/`Memory<T>` optimization, blocking subscribe, Valkey Search, batching/transactions API, ALL_NODES ReadFrom strategy, security hardening.

---

## Architecture Notes

- **Communication layer**: Native interop with the Rust core via platform-specific binaries
- Async/await with `Task<T>` return types throughout
- `IAsyncDisposable` support for proper resource cleanup
- Single multiplexed connection per node
- Maintained in a separate repository from the main GLIDE monorepo
- NuGet package: `Valkey.Glide`
- IAM authentication is available for AWS ElastiCache

---

## Cross-References

- `valkey-glide` skill - architecture, connection model, features shared across all languages
- `valkey` skill - Valkey server commands, data types, patterns
