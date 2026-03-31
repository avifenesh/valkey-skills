# Connection Management

Use when creating, configuring, or managing Valkey GLIDE Go client connections - standalone or cluster, TLS, authentication, reconnection, password rotation, lazy connect, or database selection.

## Client Types

| Type | Constructor | Mode |
|------|-------------|------|
| `Client` | `glide.NewClient(cfg)` | Standalone - single node or primary+replicas |
| `ClusterClient` | `glide.NewClusterClient(cfg)` | Cluster - auto-topology discovery |

Both return `(*T, error)`. Call `defer client.Close()` to release resources.

## Standalone Connection

```go
import (
    "context"
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})

client, err := glide.NewClient(cfg)
if err != nil {
    panic(err)
}
defer client.Close()

ctx := context.Background()
_, err = client.Set(ctx, "key", "value")
val, err := client.Get(ctx, "key")
if !val.IsNil() {
    fmt.Println(val.Value())
}
```

## Cluster Connection

```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6380}).
    WithReadFrom(config.PreferReplica)

client, err := glide.NewClusterClient(cfg)
if err != nil {
    panic(err)
}
defer client.Close()
```

Only seed addresses are needed. GLIDE discovers the full cluster topology automatically.

## Configuration Methods

Both `ClientConfiguration` and `ClusterClientConfiguration` share these methods via `baseClientConfiguration`:

| Method | Type | Description |
|--------|------|-------------|
| `WithAddress(addr)` | `*NodeAddress` | Add a node address (call multiple times for multiple nodes) |
| `WithUseTLS(bool)` | `bool` | Enable TLS encryption |
| `WithCredentials(creds)` | `*ServerCredentials` | Set authentication credentials |
| `WithReadFrom(rf)` | `ReadFrom` | Set read routing strategy |
| `WithRequestTimeout(d)` | `time.Duration` | Timeout for individual requests |
| `WithClientName(name)` | `string` | CLIENT SETNAME on connect |
| `WithClientAZ(az)` | `string` | Availability zone for AZ affinity routing |
| `WithReconnectStrategy(s)` | `*BackoffStrategy` | Custom reconnect backoff |
| `WithLazyConnect(bool)` | `bool` | Defer connection until first command |

Standalone-only:

| Method | Description |
|--------|-------------|
| `WithDatabaseId(id int)` | Select a specific database (default: 0) |

## Authentication

```go
// Username + password
creds := config.NewServerCredentials("myuser", "mypass")

// Password only (default username)
creds := config.NewServerCredentialsWithDefaultUsername("mypass")

// IAM authentication (AWS ElastiCache / MemoryDB)
iamCfg := config.NewIamAuthConfig("my-cluster", config.ElastiCache, "us-east-1")
creds, err := config.NewServerCredentialsWithIam("myuser", iamCfg)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "valkey.example.com", Port: 6379}).
    WithCredentials(creds)
```

IAM tokens are auto-refreshed by the Rust core. Use `WithRefreshIntervalSeconds` on `IamAuthConfig` to customize the renewal interval.

## Password Rotation

Update the client's stored password without recreating the client:

```go
// Update password (immediateAuth=true sends AUTH immediately)
_, err := client.UpdateConnectionPassword(ctx, "newpass", true)

// Remove password
_, err := client.ResetConnectionPassword(ctx)
```

`UpdateConnectionPassword` updates the internal reconnection credential. When `immediateAuth` is `true`, the client also sends AUTH against all connections immediately.

For IAM-authenticated clients, force an immediate token refresh:

```go
_, err := client.RefreshIamToken(ctx)
```

## Reconnection Strategy

```go
strategy := config.NewBackoffStrategy(
    5,    // numOfRetries - retries before reaching max interval
    100,  // factor (ms) - multiplier
    2,    // exponentBase
)
strategy.WithJitterPercent(20)

cfg := config.NewClientConfiguration().
    WithReconnectStrategy(strategy)
```

Formula: `factor * (exponentBase ^ N)` with optional jitter as a percentage of the computed duration. After `numOfRetries`, the interval stays constant. The client retries indefinitely.

## ReadFrom Strategies

| Constant | Behavior |
|----------|----------|
| `config.Primary` | All reads to primary (default) |
| `config.PreferReplica` | Round-robin replicas, fallback to primary |
| `config.AzAffinity` | Prefer same-AZ replicas (requires `WithClientAZ`) |
| `config.AzAffinityReplicaAndPrimary` | Same-AZ replicas, then primary, then remote |

AZ affinity strategies require Valkey 8.0+ and `WithClientAZ` must be set, otherwise client creation fails.

## Lazy Connect

```go
cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithLazyConnect(true)

client, err := glide.NewClient(cfg) // Returns immediately, no connection yet
// Connection established on first command
_, err = client.Set(ctx, "key", "value")
```

## Database Selection

```go
// Preferred: set at configuration time (persists across reconnections)
cfg := config.NewClientConfiguration().
    WithDatabaseId(2)

// Runtime: SELECT command (reverts to config value on reconnect)
_, err := client.Select(ctx, 3)
```

`Select` is standalone-only and not recommended for production - on reconnect, the client reverts to the `DatabaseId` from configuration.

## Connection Info Commands

```go
id, err := client.ClientId(ctx)              // connection ID
name, err := client.ClientGetName(ctx)        // connection name (Result[string])
_, err := client.ClientSetName(ctx, "myconn") // set connection name
pong, err := client.Ping(ctx)                 // "PONG"
info, err := client.Info(ctx)                 // server info string
count, err := client.DBSize(ctx)              // key count in current DB
```

## Error Types

| Error | When |
|-------|------|
| `*ConnectionError` | Connection lost (auto-reconnects) |
| `*TimeoutError` | Request exceeded timeout |
| `*ClosingError` | Client closed, no longer usable |
| `*ConfigurationError` | Invalid client configuration |
| `*DisconnectError` | Connection problem between client and server |
| `*ExecAbortError` | Transaction aborted (WATCH key changed) |

```go
var connErr *glide.ConnectionError
var timeoutErr *glide.TimeoutError
if errors.As(err, &connErr) {
    // Client is reconnecting automatically
} else if errors.As(err, &timeoutErr) {
    // Increase WithRequestTimeout or investigate server
}
```

## Statistics and Close

`client.GetStatistics()` returns `map[string]uint64` with keys: `total_connections`, `total_clients`, `subscription_out_of_sync_count`, `subscription_last_sync_timestamp`, plus compression counters. `Close()` is safe to call multiple times - it drains pending requests with `ClosingError`.
