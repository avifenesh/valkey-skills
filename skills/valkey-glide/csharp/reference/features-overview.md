# C# Client Overview

Use when evaluating GLIDE C# capabilities, understanding differences from other GLIDE clients or StackExchange.Redis, or checking available commands and limitations.

## Contents

- Status (line 18)
- Key Differences from Other GLIDE Clients (line 22)
- Requirements (line 33)
- Platform Support (line 38)
- Two Connection Styles (line 49)
- Available Command Groups (line 67)
- Features (line 86)
- Error Handling (line 103)
- Limitations (Preview) (line 124)
- Repository (line 131)

## Status

**Preview** - the C# wrapper is functional but API may change before GA. Many features are implemented; some advanced features may still be in progress.

## Key Differences from Other GLIDE Clients

| Aspect | C# Client | Python/Java/Node.js Clients |
|--------|-----------|----------------------------|
| Status | Preview | GA |
| Async model | `Task<T>` with async/await | Varies (asyncio, CompletableFuture, Promise) |
| StackExchange.Redis compat | `ConnectionMultiplexer` facade | N/A |
| Method naming | `StringSetAsync`, `StringGetAsync` (PascalCase) | `set`, `get` (language-idiomatic) |
| Repository | Separate (`valkey-glide-csharp`) | Monorepo (`valkey-glide`) |
| Platform | Windows, Linux, macOS | Linux, macOS (Windows varies) |

## Requirements

- .NET 8.0+
- Valkey 7.2+ or Redis 6.2+

## Platform Support

| Platform | Architecture | Supported |
|----------|-------------|-----------|
| Linux | x86_64 | Yes |
| Linux | arm64 | Yes |
| macOS | Apple Silicon | Yes |
| macOS | x86_64 | Yes |
| Windows | x86_64 | Yes |
| Alpine/MUSL | any | No |

## Two Connection Styles

**Builder pattern** (GLIDE-native):
```csharp
var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .Build();
await using var client = await GlideClient.CreateClient(config);
```

**ConnectionMultiplexer** (StackExchange.Redis-compatible):
```csharp
var mux = await ConnectionMultiplexer.ConnectAsync("localhost:6379");
var db = mux.Database;
```

ConnectionMultiplexer auto-detects cluster mode and provides a familiar API for StackExchange.Redis users.

## Available Command Groups

| Group | Examples | Status |
|-------|----------|--------|
| String | `StringSetAsync`, `StringGetAsync`, `IncrAsync` | Available |
| Hash | `HashSetAsync`, `HashGetAsync`, `HashGetAllAsync` | Available |
| List | `ListPushAsync`, `ListPopAsync`, `ListRangeAsync` | Available |
| Set | `SetAddAsync`, `SetMembersAsync`, `SetIsMemberAsync` | Available |
| Sorted Set | `SortedSetAddAsync`, `SortedSetRangeAsync` | Available |
| Stream | `StreamAddAsync`, `StreamReadAsync`, `StreamReadGroupAsync` | Available |
| PubSub | `SubscribeAsync`, `PublishAsync`, `PSubscribeAsync` | Available |
| Bitmap | `StringSetBitAsync`, `StringGetBitAsync`, `BitCountAsync` | Available |
| HyperLogLog | `HyperLogLogAddAsync`, `HyperLogLogLengthAsync` | Available |
| Geo | `GeoAddAsync`, `GeoSearchAsync`, `GeoDistAsync` | Available |
| Scripting | `ScriptEvaluateAsync`, `ScriptEvaluateShaAsync` | Available |
| Generic | `KeyDeleteAsync`, `KeyExistsAsync`, `KeyExpireAsync` | Available |
| Server | `InfoAsync`, `DBSizeAsync`, `FlushAllAsync` | Available |
| Batching | `ClusterBatch` / `StandaloneBatch` | Available |

## Features

| Feature | Available | Notes |
|---------|-----------|-------|
| Standalone mode | Yes | Via `GlideClient` or `ConnectionMultiplexer` |
| Cluster mode | Yes | Via `GlideClusterClient` or `ConnectionMultiplexer` |
| TLS/mTLS | Yes | Builder `.WithTls()` or connection string `ssl=true` |
| Authentication | Yes | Password, ACL username+password, IAM (AWS) |
| PubSub | Yes | Static + dynamic subscriptions, sharded PubSub |
| Batching | Yes | Atomic (MULTI/EXEC) and non-atomic (pipeline) |
| OpenTelemetry | Yes | Traces + metrics via `OpenTelemetry.Init()` |
| AZ Affinity | Yes | `ReadFromStrategy.AzAffinity` (Valkey 8.0+) |
| Compression | In progress | Zstd/LZ4 support being added |
| Server modules | In progress | JSON, Search support being added |
| Lazy connect | Yes | Defer connection until first command |
| RESP2/RESP3 | Yes | RESP3 default, RESP2 for compatibility |

## Error Handling

```csharp
try
{
    await client.StringSetAsync("key", "value");
}
catch (ConnectionException ex)
{
    // Connection lost - client auto-reconnects
}
catch (TimeoutException ex)
{
    // Request exceeded configured timeout
}
catch (ValkeyException ex)
{
    // Server-side error (WRONGTYPE, OOM, etc.)
}
```

## Limitations (Preview)

- API may change before GA
- Some advanced features (compression, server modules) may lag behind GA clients
- Not all StackExchange.Redis APIs are supported in the ConnectionMultiplexer facade
- Performance tuning and benchmarking are ongoing

## Repository

Separate repo: [valkey-io/valkey-glide-csharp](https://github.com/valkey-io/valkey-glide-csharp)

Package: `dotnet add package Valkey.Glide`
