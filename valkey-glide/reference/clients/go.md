# Go Client

Use when building Go applications with Valkey GLIDE - synchronous API with goroutine safety via CGO bridge.

## Installation

```bash
go get github.com/valkey-io/valkey-glide/go/v2
go mod tidy
```

**Requirements:** Go 1.22+

**Platform support:** Linux glibc (x86_64, arm64), Linux musl/Alpine (x86_64, arm64 with `-tags=musl`), macOS (Apple Silicon, x86_64). No Windows support.

The Go client uses CGO (`CGO_ENABLED=1` required) to interface with the Rust core. Pre-built static libraries (`libglide_ffi.a`) are shipped for each target platform, which can make cross-compilation challenging.

---

## Client Classes

| Class | Package | Mode | Description |
|-------|---------|------|-------------|
| `Client` | `glide` | Standalone | Single-node or primary+replicas |
| `ClusterClient` | `glide` | Cluster | Valkey Cluster with auto-topology |

Both are created via constructor functions and use `context.Context` for cancellation.

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

---

## Configuration Details

### NodeAddress

```go
type NodeAddress struct {
    Host string  // Default: "localhost"
    Port int     // Default: 6379
}
```

### ServerCredentials

Three constructors for different auth modes. See `features/tls-auth.md` for TLS and authentication details.

```go
// Username + password
creds := config.NewServerCredentials("myuser", "mypass")

// Password only (default username)
creds := config.NewServerCredentialsWithDefaultUsername("mypass")

// IAM authentication
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

Formula: `factor * (exponentBase ^ N)` with optional `jitterPercent` as a percentage of the computed duration. See [connection-model](../architecture/connection-model.md) for full retry strategy details.

### ReadFrom

Constants in the `config` package:

| Value | Behavior |
|-------|----------|
| `config.Primary` | All reads to primary (default) |
| `config.PreferReplica` | Round-robin replicas, fallback to primary |
| `config.AzAffinity` | Prefer same-AZ replicas (requires `WithClientAZ`) |
| `config.AzAffinityReplicaAndPrimary` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ and `WithClientAZ` must be set. See `features/az-affinity.md` for detailed AZ routing behavior.

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

See `features/batching.md` for detailed batching API patterns across all languages.

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

## Architecture Notes

- **Communication layer**: CGO bridge with C headers generated by cbindgen from the Rust FFI crate
- Pre-built static libraries (`libglide_ffi`) for each target triple (e.g., `x86_64-unknown-linux-gnu`)
- Synchronous API - safe for concurrent use from multiple goroutines
- All command methods accept `context.Context` as the first parameter
- Single multiplexed connection per node
- The `OK` constant (`glide.OK`) equals `"OK"` for checking SET responses

---

## Build Constraints

### CGO Cross-Compilation

Cross-compilation cannot use simple `GOOS=... go build` because CGO requires a C cross-compiler for the target platform. Implications:
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

## Ecosystem Integrations

No official framework integrations exist yet for the Go client. The idiomatic approach is to create the client at application startup and pass it via dependency injection or global state.
