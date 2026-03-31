---
name: valkey-glide-go
description: "Use when building Go applications with Valkey GLIDE. Covers synchronous API, Client/ClusterClient, CGO bridge, Result[T] types, error handling, batching, streams, TLS, authentication, OpenTelemetry, and migration from go-redis."
version: 1.0.0
argument-hint: "[API, config, or migration question]"
---

# Valkey GLIDE Go Client Reference

Synchronous Go client for Valkey built on the GLIDE Rust core via CGO bridge.

## Routing

- Install/setup -> Installation
- CGO/cross-compile -> Installation, Cross-Compilation
- Result[T] types -> Result Types
- TLS/auth -> TLS and Authentication
- Streams -> Streams
- Error handling -> Error Handling
- Batching -> Batching
- go-redis migration -> Migration from go-redis
- OTel/tracing -> OpenTelemetry

## Installation

```bash
go get github.com/valkey-io/valkey-glide/go/v2
go mod tidy
```

**Requirements:** Go 1.22+, CGO_ENABLED=1

**Platform support:** Linux glibc (x86_64, arm64), Linux musl/Alpine (x86_64, arm64 with `-tags=musl`), macOS (Apple Silicon, x86_64). No Windows support.

The Go client uses CGO to interface with the Rust core. Pre-built static libraries (`libglide_ffi.a`) ship for each target platform.

---

## Client Types

| Type | Package | Mode | Description |
|------|---------|------|-------------|
| `Client` | `glide` | Standalone | Single-node or primary+replicas |
| `ClusterClient` | `glide` | Cluster | Valkey Cluster with auto-topology |

Note: Go uses `Client` and `ClusterClient` (not `GlideClient`). Both are created via constructor functions.

---

## Standalone Connection

```go
package main

import (
    "context"
    "fmt"

    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

func main() {
    cfg := config.NewClientConfiguration().
        WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})

    client, err := glide.NewClient(cfg)
    if err != nil {
        panic(err)
    }
    defer client.Close()

    ctx := context.Background()

    _, err = client.Set(ctx, "greeting", "Hello from GLIDE")
    if err != nil {
        panic(err)
    }

    val, err := client.Get(ctx, "greeting")
    if err != nil {
        panic(err)
    }
    fmt.Printf("Got: %s\n", val.Value())
}
```

---

## Cluster Connection

```go
import (
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6380}).
    WithReadFrom(config.PreferReplica)

client, err := glide.NewClusterClient(cfg)
if err != nil {
    panic(err)
}
defer client.Close()

ctx := context.Background()
_, err = client.Set(ctx, "key", "value")
val, err := client.Get(ctx, "key")
fmt.Printf("Got: %s\n", val.Value())
```

Only seed addresses are needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration

Configuration uses constructor functions with method chaining. Package: `github.com/valkey-io/valkey-glide/go/v2/config`.

### ClientConfiguration

```go
import (
    "time"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithUseTLS(true).
    WithCredentials(config.NewServerCredentials("myuser", "mypass")).
    WithReadFrom(config.Primary).
    WithRequestTimeout(5 * time.Second).
    WithReconnectStrategy(config.NewBackoffStrategy(5, 100, 2)).
    WithClientName("my-app")
```

### ClusterClientConfiguration

```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithReadFrom(config.AzAffinity).
    WithClientAZ("us-east-1a")
```

### NodeAddress

```go
type NodeAddress struct {
    Host string  // Default: "localhost"
    Port int     // Default: 6379
}
```

### ServerCredentials

```go
// Username + password
creds := config.NewServerCredentials("myuser", "mypass")

// Password only (default username)
creds := config.NewServerCredentialsWithDefaultUsername("mypass")

// IAM authentication (AWS ElastiCache / MemoryDB)
iamConfig := config.NewIamAuthConfig("my-cluster", config.ElastiCache, "us-east-1")
creds, err := config.NewServerCredentialsWithIam("myuser", iamConfig)
```

### BackoffStrategy

```go
strategy := config.NewBackoffStrategy(
    5,    // numOfRetries
    100,  // factor (milliseconds)
    2,    // exponentBase
)
strategy.WithJitterPercent(20)  // optional
```

Formula: `factor * (exponentBase ^ N)` with optional `jitterPercent` as a percentage of the computed duration.

### ReadFrom

| Value | Behavior |
|-------|----------|
| `config.Primary` | All reads to primary (default) |
| `config.PreferReplica` | Round-robin replicas, fallback to primary |
| `config.AzAffinity` | Prefer same-AZ replicas (requires `WithClientAZ`) |
| `config.AzAffinityReplicaAndPrimary` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ and `WithClientAZ` must be set.

---

## Result Type

Go commands return `models.Result[T]` - a generic wrapper that distinguishes between a value and nil (key not found).

```go
import "github.com/valkey-io/valkey-glide/go/v2/models"
```

| Method | Return | Description |
|--------|--------|-------------|
| `result.Value()` | `T` | The actual value (zero value if nil) |
| `result.IsNil()` | `bool` | True if key does not exist |

```go
val, err := client.Get(ctx, "key")
if err != nil {
    // handle error
    return
}
if val.IsNil() {
    fmt.Println("Key does not exist")
} else {
    fmt.Printf("Value: %s\n", val.Value())
}
```

Common result types:
- `Result[string]` - string commands (GET, etc.)
- `Result[int64]` - integer commands (INCR, etc.)
- `Result[float64]` - float commands (INCRBYFLOAT, etc.)

---

## Error Handling

Error types are in the root `glide` package:

| Error | Description |
|-------|-------------|
| `*ConnectionError` | Connection lost (auto-reconnects) |
| `*TimeoutError` | Request exceeded timeout |
| `*ExecAbortError` | Transaction aborted (WATCH key changed) |
| `*DisconnectError` | Connection problem between client and server |
| `*ClosingError` | Client closed, no longer usable |
| `*ConfigurationError` | Invalid client configuration |

Use `errors.As` to check error types:

```go
import "errors"

val, err := client.Get(ctx, "key")
if err != nil {
    var connErr *glide.ConnectionError
    var timeoutErr *glide.TimeoutError
    if errors.As(err, &connErr) {
        fmt.Println("Connection error - client is reconnecting")
    } else if errors.As(err, &timeoutErr) {
        fmt.Println("Request timed out")
    } else {
        fmt.Printf("Error: %v\n", err)
    }
    return
}
```

---

## Batching

Package: `github.com/valkey-io/valkey-glide/go/v2/pipeline`.

### Transaction (Atomic)

```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

tx := pipeline.NewStandaloneBatch(true)  // true = atomic
tx.Set("key", "value")
tx.Incr("counter")
tx.Get("key")
results, err := client.Exec(ctx, *tx, true)  // raiseOnError=true
```

### Pipeline (Non-Atomic)

```go
pipe := pipeline.NewClusterBatch(false)  // false = non-atomic
pipe.Set("k1", "v1")
pipe.Set("k2", "v2")
pipe.Get("k1")
results, err := clusterClient.Exec(ctx, *pipe, false)
```

The `Exec` method returns `([]any, error)`. The `raiseOnError` parameter controls whether the first error is returned immediately or errors are embedded in the results slice.

---

## Streams

```go
import (
    "github.com/valkey-io/valkey-glide/go/v2/models"
    "github.com/valkey-io/valkey-glide/go/v2/options"
)

// Add entry
entryId, err := client.XAdd(ctx, "mystream", []models.FieldValue{
    {Field: "sensor", Value: "temp"}, {Field: "value", Value: "23.5"},
})

// Read entries
entries, err := client.XRead(ctx, map[string]string{"mystream": "0"})

// Consumer group
_, err = client.XGroupCreate(ctx, "mystream", "mygroup", "0")
messages, err := client.XReadGroup(ctx, "mygroup", "consumer1",
    map[string]string{"mystream": ">"})
ackCount, err := client.XAck(ctx, "mystream", "mygroup",
    []string{"1234567890123-0"})
```

Use a dedicated client for blocking XREAD/XREADGROUP to avoid blocking the multiplexed connection.

---

## OpenTelemetry in Go

The GLIDE Go client supports OpenTelemetry tracing. Spans are created per-command and per-batch. Configure the OpenTelemetry SDK in your Go application and GLIDE will emit spans automatically when tracing is enabled.

---

## CGO Cross-Compilation

Cross-compilation cannot use simple `GOOS=... go build` because CGO requires a C cross-compiler for the target platform:

- Docker-based cross-compilation is the recommended approach
- macOS cross-compilation requires building on actual macOS hardware
- ARM64 Linux cross-compilation needs `CC=aarch64-linux-gnu-gcc`

### MUSL / Alpine (Build-From-Source Only)

Alpine Linux is experimental and requires building from source with an explicit build tag:

```bash
export GOFLAGS=-tags=musl
```

Without this tag, the build links against glibc libraries and will fail on Alpine.

### No Windows Support

CGO type mapping mismatches (`size_t` to `long/long long`) currently prevent Windows builds.

---

## Migration from go-redis

### Key Differences at a Glance

| Area | go-redis | GLIDE |
|------|----------|-------|
| Return types | `*StatusCmd`, `*StringCmd` with `.Result()` | `models.Result[T]` with `.Value()` and `.IsNil()` |
| Nil handling | `redis.Nil` sentinel error | `val.IsNil()` method |
| Configuration | `redis.Options{}` struct | `config.NewClientConfiguration()` builder chain |
| Multi-arg commands | Varargs: `Del(ctx, "k1", "k2")` | Slice args: `Del(ctx, []string{"k1", "k2"})` |
| Expiry | Duration arg: `Set(ctx, "k", "v", 60*time.Second)` | `SetWithOptions` + `options.SetOptions` |
| Transactions | `TxPipelined()` closure | `pipeline.NewStandaloneBatch(true)` + `client.Exec()` |
| Pipelines | `Pipelined()` closure | `pipeline.NewStandaloneBatch(false)` + `client.Exec()` |
| Connection model | Pool with configurable size | Single multiplexed connection per node |

### Configuration Mapping

| go-redis field | GLIDE equivalent |
|----------------|------------------|
| `Addr: "host:port"` | `WithAddress(&config.NodeAddress{Host, Port})` |
| `Password` | `WithCredentials(&config.ServerCredentials{Password: "..."})` |
| `Username` | `WithCredentials(&config.ServerCredentials{Username: "...", Password: "..."})` |
| `DB` | `WithDatabaseId(0)` |
| `DialTimeout` | `WithRequestTimeout(time.Duration)` |
| `ReadTimeout` | Part of `WithRequestTimeout` |
| `TLSConfig` | `WithUseTLS(true)` |
| `PoolSize` | Not needed - single multiplexed connection |
| `MaxRetries` | Built-in reconnection via `WithReconnectStrategy` |

### Connection Setup

**go-redis:**
```go
import "github.com/redis/go-redis/v9"

rdb := redis.NewClient(&redis.Options{
    Addr:     "localhost:6379",
    Password: "",
    DB:       0,
})
err := rdb.Ping(ctx).Err()
```

**GLIDE:**
```go
import (
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
```

### Error Handling - The Biggest Change

**go-redis:**
```go
val, err := rdb.Get(ctx, "key").Result()
if err == redis.Nil {
    fmt.Println("key does not exist")
} else if err != nil {
    fmt.Println("error:", err)
} else {
    fmt.Println("value:", val)
}
```

**GLIDE:**
```go
val, err := client.Get(ctx, "key")
if err != nil {
    fmt.Println("error:", err)
    return
}
if val.IsNil() {
    fmt.Println("key does not exist")
} else {
    fmt.Println("value:", val.Value())
}
```

The critical difference: go-redis uses `redis.Nil` as an error sentinel for missing keys. GLIDE separates the nil check from error handling - `err` is only for actual errors, and `val.IsNil()` checks for key absence.

### String Operations

**go-redis:**
```go
err := rdb.Set(ctx, "key", "value", 0).Err()
err = rdb.Set(ctx, "key", "value", 60*time.Second).Err()  // with expiry
val, err := rdb.Get(ctx, "key").Result()
```

**GLIDE:**
```go
import (
    "time"
    "github.com/valkey-io/valkey-glide/go/v2/options"
)

_, err := client.Set(ctx, "key", "value")
// With expiry - use SetWithOptions
opts := options.NewSetOptions().
    SetExpiry(options.NewExpiryIn(60 * time.Second))
_, err = client.SetWithOptions(ctx, "key", "value", *opts)
val, err := client.Get(ctx, "key")
fmt.Println(val.Value())
```

### Hash Operations

**go-redis:**
```go
rdb.HSet(ctx, "hash", "f1", "v1", "f2", "v2")   // varargs pairs
val, err := rdb.HGet(ctx, "hash", "f1").Result()
all, err := rdb.HGetAll(ctx, "hash").Result()     // map[string]string
```

**GLIDE:**
```go
client.HSet(ctx, "hash", map[string]string{"f1": "v1", "f2": "v2"})
val, err := client.HGet(ctx, "hash", "f1")
if !val.IsNil() {
    fmt.Println(val.Value())
}
all, err := client.HGetAll(ctx, "hash")           // map[string]string
```

### Other Data Types (Varargs to Slice Pattern)

All multi-element commands follow the same pattern - go-redis uses varargs, GLIDE uses `[]string` slices:

```go
// go-redis                                    // GLIDE
rdb.LPush(ctx, "list", "a", "b")              client.LPush(ctx, "list", []string{"a", "b"})
rdb.SAdd(ctx, "set", "a", "b")                client.SAdd(ctx, "set", []string{"a", "b"})
rdb.Del(ctx, "k1", "k2")                      client.Del(ctx, []string{"k1", "k2"})
```

Sorted sets use `map[string]float64` instead of `redis.Z` structs:

```go
// go-redis
rdb.ZAdd(ctx, "zset", redis.Z{Score: 1.0, Member: "alice"})

// GLIDE
client.ZAdd(ctx, "zset", map[string]float64{"alice": 1.0})
```

### Cluster Mode

**go-redis:**
```go
rdb := redis.NewClusterClient(&redis.ClusterOptions{
    Addrs:    []string{"node1.example.com:6379", "node2.example.com:6380"},
    ReadOnly: true,
})
```

**GLIDE:**
```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6380}).
    WithReadFrom(config.PreferReplica)

client, err := glide.NewClusterClient(cfg)
```

### Transactions and Pipelines

**go-redis:**
```go
// Transaction
_, err := rdb.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
    pipe.Set(ctx, "k1", "v1", 0)
    pipe.Get(ctx, "k1")
    return nil
})

// Pipeline
_, err := rdb.Pipelined(ctx, func(pipe redis.Pipeliner) error {
    pipe.Set(ctx, "k1", "v1", 0)
    pipe.Set(ctx, "k2", "v2", 0)
    return nil
})
```

**GLIDE:**
```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

// Transaction (atomic)
tx := pipeline.NewStandaloneBatch(true)
tx.Set("k1", "v1")
tx.Get("k1")
results, err := client.Exec(ctx, *tx, true)

// Pipeline (non-atomic)
pipe := pipeline.NewStandaloneBatch(false)
pipe.Set("k1", "v1")
pipe.Set("k2", "v2")
results, err := client.Exec(ctx, *pipe, false)
```

---

## Migration Gotchas

1. **`Result[T]` instead of `redis.Nil`.** The biggest behavioral change. go-redis returns `redis.Nil` as an error for missing keys. GLIDE returns a `Result[T]` with `.IsNil()` and `.Value()` methods. Always check `IsNil()` before calling `Value()`.

2. **Slice args, not varargs.** Multi-key commands take `[]string` slices. Passing bare strings will not compile.

3. **Separate `Set` and `SetWithOptions`.** go-redis combines expiry into `Set()` as a duration parameter. GLIDE has a plain `Set()` and `SetWithOptions()` for expiry, conditional set, and return-old-value.

4. **CGO dependency.** GLIDE for Go uses CGO to call the Rust core via pre-built static libraries. Cross-compilation requires Docker-based builds (`CGO_ENABLED=1` with appropriate `CC` for the target arch) or platform-native compilation.

5. **Alpine Linux / MUSL.** Supported but requires the `musl` build tag: `export GOFLAGS=-tags=musl`. Without this tag, the build will fail or produce a broken binary on Alpine containers.

6. **No connection pool tuning.** Drop all `PoolSize`, `MinIdleConns`, and pool-related configuration. GLIDE handles connection multiplexing internally.

7. **Context parameter.** Both go-redis and GLIDE use `context.Context` as the first parameter, so this transfers directly.

8. **Import path.** The module is `github.com/valkey-io/valkey-glide/go/v2`. Subpackages include `config`, `options`, `pipeline`, `models`, and `constants`.

9. **`go mod vendor` support.** Added in GLIDE 2.2. Earlier versions did not work with vendor mode.

---

## Incremental Migration Strategy

No drop-in compatibility layer exists for Go. The recommended approach:

1. Add `github.com/valkey-io/valkey-glide/go/v2` to your `go.mod` alongside `go-redis`
2. Define a repository or store interface that abstracts the Redis client
3. Create a GLIDE implementation of that interface alongside the go-redis one
4. Migrate one service or package at a time, swapping the interface implementation
5. Replace `redis.Nil` error checks with `Result[T].IsNil()` at each call site
6. Run tests after each package migration to catch nil-handling regressions
7. Remove `go-redis` from `go.mod` once all implementations are migrated

---

## Architecture Notes

- **Communication layer**: CGO bridge with C headers generated by cbindgen from the Rust FFI crate
- Pre-built static libraries (`libglide_ffi`) for each target triple
- Synchronous API - safe for concurrent use from multiple goroutines
- All command methods accept `context.Context` as the first parameter
- Single multiplexed connection per node
- The `OK` constant (`glide.OK`) equals `"OK"` for checking SET responses

---

## Go API Maturity Timeline

| Version | Feature |
|---------|---------|
| 2.0 | GA release (June 2025), PubSub support |
| 2.2 | `go mod vendor` support |
| 2.3 | Dynamic PubSub, ACL commands, cluster management commands |

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
