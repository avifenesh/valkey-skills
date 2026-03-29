# C# Client

Use when building .NET applications with Valkey GLIDE - async/await API with Task-based patterns. Currently in preview.

## Installation

```bash
dotnet add package Valkey.Glide
```

**Requirements:** .NET 8.0+

**Separate repository:** [valkey-io/valkey-glide-csharp](https://github.com/valkey-io/valkey-glide-csharp)

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64), Windows (x86_64). No Alpine/MUSL support.

---

## Status

The C# client is explicitly marked as **preview** - "still has many features that remain to be implemented before GA." The API surface is smaller than the Python, Java, Node.js, and Go clients. Core features (connect, basic commands, cluster mode) are available, but advanced features may not yet be implemented.

The API is designed to be compatible with StackExchange.Redis conventions (method naming like `StringSetAsync`, `StringGetAsync`). See the Ecosystem Integrations section for the migration guide.

IAM authentication is available for AWS ElastiCache, similar to Java and Python clients.

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

The `GlideClient` implements `IAsyncDisposable` - use `await using` for automatic cleanup.

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
    .WithTLS(true)
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

---

## Configuration Details

### Addresses

```csharp
builder.WithAddress("localhost", 6379)
       .WithAddress("another-host", 6380)
```

### Authentication

See `features/tls-auth.md` for TLS and authentication details.

```csharp
// Password only
builder.WithCredentials(password: "mypass")

// Username + password
builder.WithCredentials("myuser", "mypass")
```

### TLS

```csharp
builder.WithTLS(true)
```

### Reconnect Strategy

Reconnect backoff configuration is not yet exposed in the C# preview API. The Rust core manages retry behavior automatically.

### ReadFrom

| Value | Behavior |
|-------|----------|
| `ReadFrom.Primary` | All reads to primary (default) |
| `ReadFrom.PreferReplica` | Round-robin replicas, fallback to primary |
| `ReadFrom.AzAffinity` | Prefer same-AZ replicas |
| `ReadFrom.AzAffinityReplicasAndPrimary` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ with the client AZ configured. See `features/az-affinity.md` for detailed AZ routing behavior.

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

## Architecture Notes

- **Communication layer**: Native interop with the Rust core via platform-specific binaries
- Async/await with `Task<T>` return types throughout
- `IAsyncDisposable` support for proper resource cleanup
- Single multiplexed connection per node
- The C# client is maintained in a separate repository from the main GLIDE monorepo
- NuGet package: `Valkey.Glide`

---

## Batching

Batching/transaction API is not yet available in the C# preview client. See `features/batching.md` for the batching patterns used in other languages.

---

## Missing Features for GA

The following are required or requested before GA:
- MUSL/Alpine support
- `Span<T>` and `Memory<T>` performance optimization
- Benchmarking infrastructure
- Blocking subscribe commands
- Valkey Search support
- Security hardening
- ALL_NODES ReadFrom strategy

---

## Ecosystem Integrations

No official framework integrations exist. A StackExchange.Redis migration guide is available: https://github.com/valkey-io/valkey-glide/wiki/Migration-Guide-StackExchange.Redis

---

## Limitations

- **Preview status** - API may change between releases
- Feature coverage is smaller than the core clients (Python, Java, Node.js, Go)
- Some advanced features are not yet available:
  - OpenTelemetry integration (available but less mature)
  - Automatic compression
  - Full PubSub support (blocking subscribe missing)
  - Batching/transactions API
- Alpine Linux / MUSL is not supported
- Maintained in a separate repository, so releases may trail the main GLIDE repo
