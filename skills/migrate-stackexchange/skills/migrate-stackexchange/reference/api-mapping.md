# StackExchange.Redis to GLIDE: where signatures diverge

Use when translating SE.Redis calls. GLIDE C# intentionally mirrors SE.Redis method names, so for most commands the only change is the type rename (`RedisKey`/`RedisValue` -> `ValkeyKey`/`ValkeyValue`) and `async` method call-sites.

## Most commands: name-identical, just rename types

The big one: `RedisKey` -> `ValkeyKey`, `RedisValue` -> `ValkeyValue`. Both sets implicit-convert from `string` / `byte[]` so most call-sites keep working unchanged.

| SE.Redis | GLIDE C# | Comment |
|----------|---------|---------|
| `await db.HashSetAsync(k, f, v)` | `await client.HashSetAsync(k, f, v)` | Identical |
| `await db.HashGetAsync(k, f)` returning `RedisValue` | `await client.HashGetAsync(k, f)` returning `ValkeyValue` | Type rename only |
| `await db.ListLeftPushAsync(k, v)` / `ListRightPushAsync` / `ListLeftPopAsync` / `ListRightPopAsync` | Identical names | |
| `await db.SetAddAsync(k, v)` / `SetMembersAsync` / `SetRemoveAsync` / `SetContainsAsync` | Identical names | |
| `await db.SortedSetAddAsync(k, m, score)` / `SortedSetRangeAsync` / `SortedSetScoreAsync` | Identical names | |
| `await db.StreamAddAsync(key, field, value)` / `StreamReadAsync` / `StreamReadGroupAsync` | Identical names | |
| `await db.KeyDeleteAsync(k)` / `KeyExistsAsync` / `KeyExpireAsync` / `KeyTimeToLiveAsync` | Identical names | |
| `await db.StringBitCountAsync(k)` / `StringSetBitAsync` / `StringGetBitAsync` | Identical names | |
| `await db.HyperLogLogAddAsync` / `HyperLogLogLengthAsync` | Identical names | |
| `await db.GeoAddAsync` / `GeoDistanceAsync` / `GeoSearchAsync` | Identical names | |
| `await db.ScriptEvaluateAsync(lua, keys, values)` | Identical | |

## Handful of renames (`String*` prefix dropped for GET / SET)

| SE.Redis | GLIDE C# |
|----------|---------|
| `await db.StringSetAsync(k, v)` | `await client.SetAsync(k, v)` |
| `await db.StringSetAsync(k, v, TimeSpan.FromSeconds(60))` | `await client.SetAsync(k, v, SetExpiryOptions.From(TimeSpan.FromSeconds(60)))` - typed expiry option |
| `await db.StringSetAsync(k, v, when: When.NotExists)` | `await client.SetAsync(k, v, SetCondition.NotExists)` |
| `await db.StringGetAsync(k)` | `await client.GetAsync(k)` |
| `await db.StringGetSetAsync(k, v)` | `await client.GetSetAsync(k, v)` |
| `await db.StringLengthAsync(k)` | `await client.LengthAsync(k)` (in the string-commands group) |

`StringSetBitAsync` / `StringGetBitAsync` / `StringBitCountAsync` keep the `String*` prefix.

## Different set operations take arrays

SE.Redis has both single-value and array-valued overloads. GLIDE is consistent:

```csharp
// Single-value
await client.SetAddAsync("set", (ValkeyValue)"a");
await client.SetRemoveAsync("set", (ValkeyValue)"a");

// Multi-value (bulk)
await client.SetAddAsync("set", new ValkeyValue[] { "a", "b", "c" });
await client.SetRemoveAsync("set", new ValkeyValue[] { "a", "b" });
```

## Publish: argument order UNCHANGED

```csharp
// SE.Redis:
await sub.PublishAsync("channel", "message");

// GLIDE: same order (unlike Python/Node GLIDE which reverse it)
await client.PublishAsync("channel", "message");
```

## Cluster client type

SE.Redis auto-detects cluster via `ConnectionMultiplexer.Connect`. GLIDE has two paths:

```csharp
// Facade path - auto-detects like SE.Redis:
var mux = await ConnectionMultiplexer.ConnectAsync("n1:6379,n2:6379");

// Native path - explicit cluster client:
var config = new ClusterClientConfigurationBuilder()
    .WithAddress("n1", 6379)
    .WithAddress("n2", 6379)
    .Build();
await using var client = await GlideClusterClient.CreateClient(config);
```

## Everything else is translation-free

For 80%+ of command call-sites, the SE.Redis code compiles after:

1. `using StackExchange.Redis;` -> `using Valkey.Glide;`
2. `RedisKey` -> `ValkeyKey`, `RedisValue` -> `ValkeyValue` (global find/replace works)
3. `ConnectionMultiplexer.Connect(...)` -> `await ConnectionMultiplexer.ConnectAsync(...)`
4. Remove any `CommandFlags.FireAndForget` (no equivalent - use a Batch)
5. Rewrite catch blocks: `RedisConnectionException` -> `Errors.ConnectionException`, etc.

The method names just work.
