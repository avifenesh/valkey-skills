# Connection and configuration (C#)

Use when creating clients, configuring auth, TLS, timeouts, reconnection, read strategy, or using the StackExchange.Redis-compatible ConnectionMultiplexer. Covers what differs from StackExchange.Redis's `ConnectionMultiplexer.Connect(connString)` + `IDatabase`.

## Two entry points - pick one

| API | When to use |
|-----|-------------|
| `GlideClient.CreateClient(config)` / `GlideClusterClient.CreateClient(config)` | GLIDE-native builder pattern; explicit standalone vs cluster |
| `ConnectionMultiplexer.ConnectAsync(connString)` | SE.Redis facade; auto-detects standalone vs cluster from connection string |

Both sit on the same underlying multiplexer. All clients implement `IAsyncDisposable` - use `await using` for cleanup.

## Divergence from StackExchange.Redis

| SE.Redis | GLIDE C# |
|----------|---------|
| `ConnectionMultiplexer.Connect(connString)` - sync | `GlideClient.CreateClient(config)` async static OR `ConnectionMultiplexer.ConnectAsync(connString)` |
| Connection pool with `syncTimeout` / `responseTimeout` | Multiplexer - single multiplexed connection per node; no pool knobs |
| `RedisKey` / `RedisValue` primitive wrappers | `ValkeyKey` / `ValkeyValue` - same idea, rebranded |
| `IDatabase db = mux.GetDatabase()` | Call commands directly on `client` (or `mux.Database` through the facade) |
| `db.StringSetAsync(key, value)` | `client.SetAsync(key, value)` - SE.Redis-compatible method names but `String*` prefix dropped where redundant |
| `db.ListLeftPushAsync` / `ListRightPushAsync` | Same names (SE.Redis-compatible) |
| `ConnectionMultiplexer.GetServer()` / `GetServers()` | Not exposed; server commands on the client |
| `ConfigurationOptions` parser | `StandaloneClientConfigurationBuilder` / `ClusterClientConfigurationBuilder` fluent builder; connection strings also parsed by `ConnectionMultiplexer` facade |
| `OnConnectionFailed` / `OnConnectionRestored` events | No events - errors surface per-Task via `await`; track via `client.GetStatistics()` |
| `MaxRetries`, `MaxInflightOperations` | `RetryStrategy(n, factor, exponentBase, jitter)` caps BACKOFF sequence length only - reconnection is INFINITE |

## GLIDE-native builder pattern

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .Build();

await using var client = await GlideClient.CreateClient(config);

await client.SetAsync("key", "value");         // NOT StringSetAsync
ValkeyValue val = await client.GetAsync("key"); // NOT StringGetAsync
```

With full configuration:

```csharp
var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .WithTls()
    .WithAuthentication("myuser", "mypass")
    .WithRequestTimeout(TimeSpan.FromSeconds(5))
    .WithConnectionTimeout(TimeSpan.FromSeconds(3))
    .WithDatabaseId(0)
    .WithClientName("my-app")
    .WithProtocol(Protocol.RESP3)
    .WithReadFrom(new ReadFrom(ReadFromStrategy.PreferReplica))
    .WithRetryStrategy(new RetryStrategy(
        numberOfRetries: 5, factor: 1000, exponentBase: 2, jitterPercent: 20))
    .WithLazyConnect(true)
    .Build();

await using var client = await GlideClient.CreateClient(config);
```

## Cluster Client (Builder Pattern)

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithAddress("node2.example.com", 6380)
    .Build();

await using var client = await GlideClusterClient.CreateClient(config);
```

Only seed addresses are needed - GLIDE discovers full topology automatically.

## ConnectionMultiplexer (StackExchange.Redis Compatibility)

```csharp
using Valkey.Glide;

var mux = await ConnectionMultiplexer.ConnectAsync("localhost:6379");
var db = mux.Database;
await db.StringSetAsync("key", "value");
```

Connection string: `"host1:6379,host2:6380,ssl=true,password=secret"`. Auto-detects standalone vs cluster.

## Authentication

```csharp
// Password only
builder.WithAuthentication(password: "mypass");

// Username + password (ACL)
builder.WithAuthentication("myuser", "mypass");

// IAM authentication (AWS ElastiCache/MemoryDB)
using var iamConfig = new IamAuthConfig(
    "my-cluster", ServiceType.ElastiCache, "us-east-1");
builder.WithAuthentication("iam-user", iamConfig);
```

IAM authentication requires TLS and provides automatic token refresh.

## ReadFrom Strategy

| Strategy | Behavior |
|----------|----------|
| `ReadFromStrategy.Primary` | All reads to primary (default) |
| `ReadFromStrategy.PreferReplica` | Round-robin replicas, fallback to primary |
| `ReadFromStrategy.AzAffinity` | Same-AZ replicas, fallback to others |
| `ReadFromStrategy.AzAffinityReplicasAndPrimary` | Same-AZ replicas, then primary, then remote |

AZ-affinity requires Valkey 8.0+:

```csharp
builder.WithReadFrom(
    new ReadFrom(ReadFromStrategy.AzAffinity, "us-east-1a"));
```

## RetryStrategy

Controls reconnection on disconnection. Delay follows `rand(0 ... factor * (exponentBase ^ N))`.

```csharp
builder.WithRetryStrategy(new RetryStrategy(
    numberOfRetries: 5,   // retries before delay plateaus
    factor: 1000,         // base delay multiplier in ms
    exponentBase: 2,      // exponential growth factor
    jitterPercent: 20     // random jitter on calculated delay
));
```

The client retries indefinitely - once `numberOfRetries` is reached, delay stays constant.

## TLS

```csharp
builder.WithTls();                                        // basic TLS
builder.WithTls().WithRootCertificate(caCertBytes);       // custom CA (max 10 MB)
```

## Other Options

- **Protocol**: `builder.WithProtocol(Protocol.RESP3)` (default) or `Protocol.RESP2`. PubSub requires RESP3.
- **Lazy connect**: `builder.WithLazyConnect(true)` - defers connection until first command.
- **Closing**: Use `await using` for automatic cleanup, or call `await client.DisposeAsync()` manually.
