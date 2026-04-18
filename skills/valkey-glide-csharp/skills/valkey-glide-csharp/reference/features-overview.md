# C# Client Overview

Use when checking GLIDE C# status, platform support, method naming convention, error model, or features beyond the connection / pubsub basics.

## Status

**GA at v1.0.0** (previously preview). Published as `Valkey.Glide` on NuGet. Repo: [valkey-io/valkey-glide-csharp](https://github.com/valkey-io/valkey-glide-csharp).

## Requirements and platform support

- .NET 8.0+
- Valkey 7.2+ or Redis 6.2+

| Platform | Arch | Supported |
|----------|------|-----------|
| Linux (glibc) | x86_64, arm64 | Yes |
| macOS | Apple Silicon, x86_64 | Yes |
| Windows | x86_64 | Yes |
| Alpine / MUSL | any | No (glibc 2.17+ required) |

## Method naming

C# GLIDE uses **StackExchange.Redis-compatible** method names, NOT GLIDE-invented `<Type>Command`-style prefixes. Agents migrating from SE.Redis can use the same method names for most commands. Examples:

| What you want | Actual method |
|---------------|---------------|
| SET | `SetAsync(key, value)` - NOT `StringSetAsync` |
| GET | `GetAsync(key)` - NOT `StringGetAsync` |
| HSET | `HashSetAsync(key, field, value)` - ✓ matches SE.Redis |
| HGET | `HashGetAsync(key, field)` |
| LPUSH / RPUSH | `ListLeftPushAsync` / `ListRightPushAsync` - NOT `ListPushAsync` |
| LPOP / RPOP | `ListLeftPopAsync` / `ListRightPopAsync` - NOT `ListPopAsync` |
| SADD / SMEMBERS | `SetAddAsync` / `SetMembersAsync` |
| ZADD / ZRANGE | `SortedSetAddAsync` / `SortedSetRangeAsync` |
| XADD / XREAD | `StreamAddAsync` / `StreamReadAsync` |
| SUBSCRIBE / PUBLISH | `SubscribeAsync` / `PublishAsync` |
| SETBIT / GETBIT / BITCOUNT | `StringSetBitAsync` / `StringGetBitAsync` / `StringBitCountAsync` (here `String*` prefix IS used - inherits from SE.Redis convention for these) |
| PFADD / PFCOUNT | `HyperLogLogAddAsync` / `HyperLogLogLengthAsync` |
| GEOADD / GEOSEARCH | `GeoAddAsync` / `GeoSearchAsync` |
| EVAL / EVALSHA | `ScriptEvaluateAsync` |
| DEL / EXISTS / EXPIRE | `KeyDeleteAsync` / `KeyExistsAsync` / `KeyExpireAsync` |
| INFO / DBSIZE / FLUSHALL | `InfoAsync` / `DatabaseSizeAsync` / `FlushAllAsync` (server-management group) |

When in doubt, the SE.Redis naming convention is the default; grep the `BaseClient.*Commands.cs` files under `sources/Valkey.Glide/Client/` for exact signatures.

## Types

- `ValkeyKey` - SE.Redis-compatible key wrapper (equivalent to `RedisKey`). Implicit conversions from `string` and `byte[]`.
- `ValkeyValue` - SE.Redis-compatible value wrapper (equivalent to `RedisValue`).
- `GlideString` - binary-safe string used in some low-level APIs.
- `ClusterValue<T>` - cluster response wrapper when a command fans out to multiple nodes.

## Error hierarchy

All errors nested in the static `Errors` class. `Valkey.Glide.Errors.GlideException` (abstract base) with sealed subclasses:

```
Errors.GlideException (abstract)              # catches everything
├── Errors.RequestException                    # general request failure
├── Errors.ValkeyServerException               # server-side error (WRONGTYPE, OOM, NOAUTH)
├── Errors.ExecAbortException                  # atomic batch aborted (WATCH conflict)
├── Errors.TimeoutException                    # request timeout
├── Errors.ConnectionException                 # network / connection problem
└── Errors.ConfigurationError                  # invalid config (note "Error" suffix, not "Exception")
```

**Gotcha**: `ConfigurationError` uses the `Error` suffix while every other leaf uses `Exception`. That's an upstream inconsistency in `sources/Valkey.Glide/Errors.cs`. Use the exact name when catching.

```csharp
using static Valkey.Glide.Errors;

try
{
    await client.SetAsync("key", "value");
}
catch (ConnectionException ex) { /* network issue - auto-reconnecting */ }
catch (TimeoutException    ex) { /* check requestTimeout or server load */ }
catch (ValkeyServerException ex) { /* server-side WRONGTYPE, OOM, etc. */ }
catch (GlideException ex)        { /* catch-all */ }
```

## Feature availability

| Feature | Notes |
|---------|-------|
| Standalone + Cluster | Both via `GlideClient` / `GlideClusterClient` or `ConnectionMultiplexer` facade |
| TLS / mTLS | Builder `.WithTls()` + optional `.WithRootCertificate(bytes)`; or `ssl=true` in connection string |
| Password / ACL / IAM auth | All supported. IAM config requires TLS. |
| PubSub | Static (in config) + dynamic (2.3+); sharded cluster-only |
| Batching | `Batch` / `ClusterBatch` with atomic (MULTI/EXEC) and non-atomic (pipeline) modes |
| OpenTelemetry | Traces + metrics via `OpenTelemetry.Init(...)` before creating clients |
| AZ Affinity | `ReadFromStrategy.AzAffinity` + `WithReadFrom(new ReadFrom(strategy, "us-east-1a"))` |
| Compression | Zstd / LZ4 via `CompressionConfig` on builder |
| Lazy connect | `.WithLazyConnect(true)` |
| RESP2 / RESP3 | RESP3 default; PubSub static subscriptions require RESP3 |
