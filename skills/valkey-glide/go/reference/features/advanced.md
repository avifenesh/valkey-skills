# Advanced Configuration

Use when tuning connection timeouts, TLS certificates, TCP_NODELAY, cluster topology refresh, request routing, custom commands, or scan iteration.

Packages: `github.com/valkey-io/valkey-glide/go/v2/config`, `github.com/valkey-io/valkey-glide/go/v2/options`, `github.com/valkey-io/valkey-glide/go/v2/constants`.

## Contents

- AdvancedClientConfiguration (Standalone) (line 20)
- AdvancedClusterClientConfiguration (line 45)
- TLS Configuration (line 64)
- Request Routing (Cluster) (line 95)
- Custom Commands (line 121)
- Scan Iteration (line 142)
- Server Management (line 178)
- Lua Scripting (EVAL/EVALSHA) (line 188)
- Functions API (Valkey 7.0+) (line 219)
- OpenTelemetry Integration (line 249)

## AdvancedClientConfiguration (Standalone)

```go
import (
    "time"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

advanced := config.NewAdvancedClientConfiguration().
    WithConnectionTimeout(3 * time.Second).
    WithTcpNoDelay(true).
    WithPubSubReconciliationIntervalMs(5000)

cfg := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithAdvancedConfiguration(advanced)
```

| Method | Default | Description |
|--------|---------|-------------|
| `WithConnectionTimeout(d)` | 2000ms | TCP/TLS connect timeout (initial and reconnect) |
| `WithTcpNoDelay(bool)` | true | Disable Nagle's algorithm for lower latency |
| `WithTlsConfiguration(cfg)` | nil | Custom TLS settings (certs, insecure mode) |
| `WithPubSubReconciliationIntervalMs(ms)` | 3000 | PubSub sync interval |

## AdvancedClusterClientConfiguration

```go
advanced := config.NewAdvancedClusterClientConfiguration().
    WithConnectionTimeout(3 * time.Second).
    WithRefreshTopologyFromInitialNodes(true).
    WithTcpNoDelay(true)

cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAdvancedConfiguration(advanced)
```

Additional cluster-only method:

| Method | Default | Description |
|--------|---------|-------------|
| `WithRefreshTopologyFromInitialNodes(bool)` | false | Refresh topology using only initial seed nodes instead of internal cluster view |

## TLS Configuration

```go
tlsCfg := config.NewTlsConfiguration()

// Custom root CA certificates (PEM format)
certs, err := config.LoadRootCertificatesFromFile("/path/to/ca-cert.pem")
if err != nil {
    panic(err)
}
tlsCfg.WithRootCertificates(certs)

// Insecure TLS (skip verification - dev/test only)
tlsCfg.WithInsecureTLS(true)

advanced := config.NewAdvancedClientConfiguration().
    WithTlsConfiguration(tlsCfg)

cfg := config.NewClientConfiguration().
    WithUseTLS(true).
    WithAdvancedConfiguration(advanced)
```

| Method | Description |
|--------|-------------|
| `WithRootCertificates([]byte)` | PEM-encoded root certificates; nil = system trust store |
| `WithInsecureTLS(bool)` | Skip certificate verification (requires `WithUseTLS(true)`) |
| `LoadRootCertificatesFromFile(path)` | Helper to read PEM file from disk |

`WithInsecureTLS(true)` fails if `WithUseTLS` is not enabled on the base config.

## Request Routing (Cluster)

Override default routing for cluster commands using `config.Route` types.

### Route Types

Constants: `AllNodes`, `AllPrimaries`, `RandomRoute`. Constructors: `NewSlotKeyRoute(slotType, key)`, `NewSlotIdRoute(slotType, slotId)`, `NewByAddressRoute(host, port)`. SlotType: `config.SlotTypePrimary` or `config.SlotTypeReplica`.

### Routed Commands

```go
// Route to a specific key's slot
route := config.NewSlotKeyRoute(config.SlotTypePrimary, "mykey")
result, err := clusterClient.InfoWithOptions(ctx, options.ClusterInfoOptions{
    RouteOption: &options.RouteOption{Route: route},
})

// Route to all primaries
result, err := clusterClient.InfoWithOptions(ctx, options.ClusterInfoOptions{
    RouteOption: &options.RouteOption{Route: config.AllPrimaries},
})

// Route to specific node
route := config.NewByAddressRoute("10.0.0.5", 6379)
```

## Custom Commands

Execute arbitrary commands not wrapped by the client API:

```go
// Standalone
result, err := client.CustomCommand(ctx, []string{"CLIENT", "INFO"})

// Cluster (auto-routed)
result, err := clusterClient.CustomCommand(ctx, []string{"DBSIZE"})

// Cluster with explicit route
route := config.NewByAddressRoute("node1.example.com", 6379)
result, err := clusterClient.CustomCommandWithRoute(ctx,
    []string{"CLIENT", "LIST"}, route)
```

`CustomCommand` returns `(any, error)` for standalone, `(models.ClusterValue[any], error)` for cluster. Cast the result based on the command's expected response type.

Do not use `CustomCommand` for blocking commands (SUBSCRIBE, BLPOP), multi-response commands (XREAD without count), or commands that change client mode.

## Scan Iteration

Incrementally iterate over keys without blocking the server:

```go
import "github.com/valkey-io/valkey-glide/go/v2/models"

cursor := models.NewCursor()
for {
    result, err := client.Scan(ctx, cursor)
    if err != nil {
        break
    }
    for _, key := range result.Data {
        fmt.Println(key)
    }
    cursor = result.Cursor
    if cursor.IsFinished() {
        break
    }
}
```

### Scan with Options

```go
scanOpts := options.NewScanOptions().
    SetMatch("user:*").
    SetCount(100).
    SetType(constants.ObjectTypeString)

result, err := client.ScanWithOptions(ctx, cursor, *scanOpts)
```

Cluster clients use `ClusterScanOptions` with the same methods.

## Server Management

```go
params, err := client.ConfigGet(ctx, []string{"maxmemory", "timeout"})
_, err = client.ConfigSet(ctx, map[string]string{"maxmemory": "100mb"})
_, err = client.FlushAll(ctx)                           // or FlushAllWithOptions(ctx, options.ASYNC)
_, err = client.FlushDB(ctx)                            // current database only
lastSave, err := client.LastSave(ctx)                   // UNIX timestamp
```

## Lua Scripting (EVAL/EVALSHA)

```go
import "github.com/valkey-io/valkey-glide/go/v2/options"

script := options.NewScript("return redis.call('GET', KEYS[1])")
defer script.Close() // drops script from cache

result, err := client.InvokeScript(ctx, *script)

// With keys and args
scriptWithArgs := options.NewScript("return redis.call('SET', KEYS[1], ARGV[1])")
defer scriptWithArgs.Close()
opts := options.NewScriptOptions().
    WithKeys([]string{"mykey"}).
    WithArgs([]string{"myvalue"})
result, err = client.InvokeScriptWithOptions(ctx, *scriptWithArgs, *opts)

// Cache management
exists, err := client.ScriptExists(ctx, []string{"sha1hex"})  // []bool
_, err = client.ScriptFlush(ctx)                                // SCRIPT FLUSH
_, err = client.ScriptFlushWithMode(ctx, options.ASYNC)         // SCRIPT FLUSH ASYNC
code, err := client.ScriptShow(ctx, "sha1hex")                 // SCRIPT SHOW (Valkey 8.0+)
_, err = client.ScriptKill(ctx)                                 // SCRIPT KILL

// Cluster: route script commands
routeOpt := options.RouteOption{Route: config.AllPrimaries}
result, err = clusterClient.InvokeScriptWithRoute(ctx, *script, routeOpt)
exists, err = clusterClient.ScriptExistsWithRoute(ctx, sha1s, routeOpt)
```

## Functions API (Valkey 7.0+)

```go
// Load a library (replace=true to overwrite)
libName, err := client.FunctionLoad(ctx, luaCode, true)

// Call functions
result, err := client.FCall(ctx, "myfunc")
result, err = client.FCallReadOnly(ctx, "myfunc")
result, err = client.FCallWithKeysAndArgs(ctx, "myfunc", []string{"key1"}, []string{"arg1"})
result, err = client.FCallReadOnlyWithKeysAndArgs(ctx, "myfunc", []string{"key1"}, []string{"arg1"})

// Management
_, err = client.FunctionDelete(ctx, "mylib")
libs, err := client.FunctionList(ctx, models.FunctionListQuery{})
_, err = client.FunctionFlush(ctx)                      // FUNCTION FLUSH
_, err = client.FunctionFlushSync(ctx)                  // FUNCTION FLUSH SYNC
_, err = client.FunctionFlushAsync(ctx)                 // FUNCTION FLUSH ASYNC
stats, err := client.FunctionStats(ctx)                 // running script + engine info
payload, err := client.FunctionDump(ctx)                // serialized payload
_, err = client.FunctionRestore(ctx, payload)           // restore from dump
_, err = client.FunctionRestoreWithPolicy(ctx, payload, constants.AppendPolicy)
_, err = client.FunctionKill(ctx)                       // kill running read-only function

// Cluster: route function commands
routeOpt := options.RouteOption{Route: config.AllPrimaries}
result, err = clusterClient.FCallWithRoute(ctx, "myfunc", routeOpt)
result, err = clusterClient.FunctionLoadWithRoute(ctx, luaCode, true, routeOpt)
```

## OpenTelemetry Integration

Quick setup:

```go
otelCfg := glide.OpenTelemetryConfig{
    Traces:          &glide.OpenTelemetryTracesConfig{Endpoint: "http://localhost:4318/v1/traces", SamplePercentage: 5},
    Metrics:         &glide.OpenTelemetryMetricsConfig{Endpoint: "http://localhost:4318/v1/metrics"},
    SpanFromContext: glide.DefaultSpanFromContext,
}
err := glide.GetOtelInstance().Init(otelCfg)

// Parent-child spans
spanPtr, _ := glide.GetOtelInstance().CreateSpan("my-operation")
defer glide.GetOtelInstance().EndSpan(spanPtr)
ctx = glide.WithSpan(ctx, spanPtr) // GLIDE commands with this ctx become child spans
```
