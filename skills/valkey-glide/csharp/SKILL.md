---
name: valkey-glide-csharp
description: "Use when building C#/.NET applications with Valkey GLIDE. Covers async/await API, .NET 6.0+/8.0+, configuration builders. Preview status."
version: 1.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE C# Client Reference

Async/await C# client for Valkey built on the GLIDE Rust core via native interop. Currently in **preview** - API may change before GA.

## Routing

- Install/setup -> Installation
- Async API -> Client Classes, Basic Operations
- TLS/auth -> TLS and Authentication
- Streams -> Streams
- Error handling -> Error Handling

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

<!-- SHARED-GLIDE-SECTION: keep in sync with valkey-glide/SKILL.md -->

## Architecture

| Topic | Reference |
|-------|-----------|
| Three-layer design: Rust core, Protobuf IPC, language FFI bridges | [overview](reference/architecture/overview.md) |
| Multiplexed connections, inflight limits, request timeout, reconnect logic | [connection-model](reference/architecture/connection-model.md) |
| Cluster slot routing, MOVED/ASK handling, multi-slot splitting, ReadFrom | [cluster-topology](reference/architecture/cluster-topology.md) |


## Features

| Topic | Reference |
|-------|-----------|
| Batch API: atomic (MULTI/EXEC) and non-atomic (pipeline) modes | [batching](reference/features/batching.md) |
| PubSub: exact, pattern, and sharded subscriptions, dynamic callbacks | [pubsub](reference/features/pubsub.md) |
| Scripting: Lua EVAL/EVALSHA with SHA1 caching, FCALL Functions | [scripting](reference/features/scripting.md) |
| OpenTelemetry: per-command tracing spans, metrics export | [opentelemetry](reference/features/opentelemetry.md) |
| AZ affinity: availability-zone-aware read routing, cross-zone savings | [az-affinity](reference/features/az-affinity.md) |
| TLS, mTLS, custom CA certificates, password auth, IAM tokens | [tls-auth](reference/features/tls-auth.md) |
| Compression: transparent Zstd/LZ4 for large values (SET/GET) | [compression](reference/features/compression.md) |
| Streams: XADD, XREAD, XREADGROUP, consumer groups, XCLAIM, XAUTOCLAIM | [streams](reference/features/streams.md) |
| Server modules: GlideJson (JSON), GlideFt (Search/Vector) | [server-modules](reference/features/server-modules.md) |
| Logging: log levels, file rotation, GLIDE_LOG_DIR, debug output | [logging](reference/features/logging.md) |
| Geospatial: GEOADD, GEOSEARCH, GEODIST, proximity queries | [geospatial](reference/features/geospatial.md) |
| Bitmaps and HyperLogLog: BITCOUNT, BITFIELD, PFADD, PFCOUNT | [bitmaps-hyperloglog](reference/features/bitmaps-hyperloglog.md) |
| Hash field expiration: HSETEX, HGETEX, HEXPIRE (Valkey 9.0+) | [hash-field-expiration](reference/features/hash-field-expiration.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Performance: benchmarks, GLIDE vs native clients, batching throughput | [performance](reference/best-practices/performance.md) |
| Error handling: exception types, reconnection, retry, batch errors | [error-handling](reference/best-practices/error-handling.md) |
| Production: timeout config, connection management, cloud defaults | [production](reference/best-practices/production.md) |

<!-- END SHARED-GLIDE-SECTION -->

## Cross-References

- `valkey` skill - Valkey server commands, data types, patterns
