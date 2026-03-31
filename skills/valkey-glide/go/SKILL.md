---
name: valkey-glide-go
description: "Use when building Go applications with Valkey GLIDE. Covers synchronous API, Client/ClusterClient, CGO bridge, Result[T] types, error handling, batching, streams, TLS, authentication, OpenTelemetry."
version: 1.0.0
argument-hint: "[API or config question]"
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
