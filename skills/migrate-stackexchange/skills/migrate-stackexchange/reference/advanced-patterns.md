# StackExchange.Redis to GLIDE: migration patterns (C#)

Use when translating SE.Redis transactions, Pub/Sub, and fire-and-forget patterns, or choosing between the ConnectionMultiplexer facade and the GLIDE-native builder.

## Transactions and batches

SE.Redis `ITransaction` with conditions maps to GLIDE's `Batch(isAtomic: true)` + `client.ExecAsync(batch, raiseOnError)`:

```csharp
// SE.Redis:
var tx = db.CreateTransaction();
tx.AddCondition(Condition.KeyNotExists("key"));
_ = tx.StringSetAsync("key", "value");
_ = tx.StringGetAsync("key");
bool committed = await tx.ExecuteAsync();

// GLIDE:
using Valkey.Glide.Pipeline;

var batch = new Batch(isAtomic: true)
    .Set("key", "value")
    .Get("key");

// WATCH via client.WatchAsync before the batch (replaces the AddCondition pattern)
await client.WatchAsync(new ValkeyKey[] { "key" });
object[]? results = await client.ExecAsync(batch, raiseOnError: true);
// results is null when a watched key was modified (WATCH conflict)
```

Differences from `ITransaction`:

- No `Condition` objects - use `WATCH` + `ExecAsync` pattern. Returns `null` on conflict.
- Atomic batches in cluster mode require all keys to hash to one slot; use hash tags.
- Non-atomic pipelines (`new Batch(isAtomic: false)`) split per-slot automatically in cluster mode.

Cluster-only retry strategy:

```csharp
var options = new ClusterBatchOptions { Timeout = TimeSpan.FromSeconds(5) }
    .WithRetryStrategy(new BatchRetryStrategy(retryServerError: true, retryConnectionError: false));
await clusterClient.ExecAsync(batch, raiseOnError: false, options);
```

Same hazards as in other languages - `retryServerError` can reorder within a slot; `retryConnectionError` can cause duplicates.

## Pub/Sub

```csharp
// SE.Redis:
var sub = mux.GetSubscriber();
await sub.SubscribeAsync("channel", (ch, msg) => Console.WriteLine($"{ch}: {msg}"));
await sub.PublishAsync("channel", "hello");

// GLIDE - static subscriptions via builder:
var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .WithPubSubSubscriptionConfig(new StandalonePubSubSubscriptionConfig()
        .WithChannel("channel")
        .WithPattern("events:*")
        .WithCallback((msg, ctx) =>
            Console.WriteLine($"[{msg.Channel}] {msg.Message}")))
    .Build();
await using var subscriber = await GlideClient.CreateClient(config);

// GLIDE - dynamic subscribe:
await subscriber.SubscribeAsync("channel", TimeSpan.FromSeconds(5));
await subscriber.PSubscribeAsync("events:*", TimeSpan.FromSeconds(5));
await subscriber.SubscribeLazyAsync("updates");          // non-blocking
await subscriber.UnsubscribeAsync("channel", TimeSpan.FromSeconds(5));
await subscriber.UnsubscribeLazyAsync();                 // all channels

// Publish - argument order SAME as SE.Redis (channel, message)
await publisher.PublishAsync("channel", "hello");
```

GLIDE multiplexes subscriptions alongside commands - the subscribing client CAN still run regular commands. A dedicated subscriber client is recommended for high-volume subscriptions but not required. Auto-resubscribe on reconnect + topology change is handled by the synchronizer. `TimeSpan.Zero` for the timeout blocks indefinitely.

Static subscriptions require RESP3 (default). RESP2 raises `Errors.ConfigurationError`.

## Key and value types: rename, not reinvent

SE.Redis uses `RedisKey` / `RedisValue` wrappers with implicit conversions from `string` / `byte[]` / etc. GLIDE keeps the exact same model, just renamed:

| SE.Redis | GLIDE C# |
|----------|---------|
| `RedisKey` | `ValkeyKey` |
| `RedisValue` | `ValkeyValue` |
| `HashEntry` | (no direct equivalent; `HashSetAsync` takes `KeyValuePair<ValkeyValue, ValkeyValue>[]`) |
| `SortedSetEntry` | (no direct equivalent; typed methods take member + score args) |

For binary-safe bytes where even `ValkeyValue` is awkward, GLIDE uses `GlideString` at the interop boundary.

Migration is a mechanical global rename (`RedisKey` -> `ValkeyKey`, `RedisValue` -> `ValkeyValue`). The implicit `string` conversions make most call sites keep working.

## Fire-and-forget removed

SE.Redis's `CommandFlags.FireAndForget` has NO equivalent in GLIDE. Every command returns `Task<T>` that must be awaited. Use non-atomic batches for bulk-send throughput:

```csharp
// SE.Redis:
for (int i = 0; i < 1000; i++)
    db.StringSet($"k:{i}", $"v:{i}", flags: CommandFlags.FireAndForget);

// GLIDE:
var batch = new Batch(isAtomic: false);
for (int i = 0; i < 1000; i++) batch.Set($"k:{i}", $"v:{i}");
await client.ExecAsync(batch, raiseOnError: false);
```

One round trip, one multiplexer slot. Faster than 1000 fire-and-forget sends.

## ConnectionMultiplexer facade vs GLIDE-native

| Situation | Use |
|-----------|-----|
| Fast migration, minimal code changes | `ConnectionMultiplexer.ConnectAsync(connString)` facade - same `IDatabase`, same `IBatch`, `ValkeyKey`/`ValkeyValue` replace `Redis*` types, everything else familiar |
| Need explicit standalone/cluster typing | `GlideClient.CreateClient` / `GlideClusterClient.CreateClient` with builder |
| Want GLIDE-only features (IAM, AZ affinity, compression config, OTel init before client creation) | Native path - the `ConfigurationBuilder` exposes these; the facade's connection string parser does not cover all of them |
| Existing SE.Redis DI setup via `IConnectionMultiplexer` | Facade - GLIDE's `ConnectionMultiplexer` implements `IConnectionMultiplexer` for drop-in DI replacement |

## Platform and packaging

- **NuGet**: `dotnet add package Valkey.Glide`. v1.0.0 is GA.
- **.NET 8.0+** required. No .NET Framework / .NET Standard support.
- **Platforms**: Linux (glibc 2.17+, x86_64/arm64), macOS (x86_64/Apple Silicon), Windows (x86_64). Alpine / MUSL not supported.
- **Native binary**: ships platform-specific `Valkey.Glide.<os>-<arch>` runtime package. Lockfile on one OS/arch won't pull the right native for another - keep `dotnet restore` platform-aligned with deploy target.
- **Proxies**: GLIDE sends `CLIENT SETNAME`, `CLIENT SETINFO`, `INFO REPLICATION` at setup. Transparent proxies that strip these break topology detection.
