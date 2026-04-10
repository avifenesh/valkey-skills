# Connection and Configuration (C#)

Use when creating a GLIDE client in C#, choosing between standalone and cluster mode, configuring authentication, TLS, timeouts, reconnection backoff, read strategy, or the StackExchange.Redis-compatible ConnectionMultiplexer.

## Contents

- Client Classes (line 17)
- Standalone Client (Builder Pattern) (line 27)
- Cluster Client (Builder Pattern) (line 64)
- ConnectionMultiplexer (StackExchange.Redis Compatibility) (line 80)
- Authentication (line 92)
- ReadFrom Strategy (line 109)
- RetryStrategy (line 125)
- TLS (line 140)
- Other Options (line 147)

## Client Classes

| Class | Mode | Description |
|-------|------|-------------|
| `GlideClient` | Standalone | Single-node or primary+replicas via builder config |
| `GlideClusterClient` | Cluster | Valkey Cluster with auto-topology discovery |
| `ConnectionMultiplexer` | Auto-detect | StackExchange.Redis-compatible facade, detects cluster automatically |

All clients implement `IAsyncDisposable` - use `await using` for automatic cleanup.

## Standalone Client (Builder Pattern)

```csharp
using Valkey.Glide;
using static Valkey.Glide.ConnectionConfiguration;

var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .Build();

await using var client = await GlideClient.CreateClient(config);

await client.StringSetAsync("key", "value");
var result = await client.StringGetAsync("key");
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
