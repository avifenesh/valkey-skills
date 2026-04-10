# StackExchange.Redis to GLIDE Advanced Patterns

Use when migrating StackExchange.Redis transactions, Pub/Sub, fire-and-forget patterns, or understanding GLIDE C# API compatibility and key type differences.

## Contents

- Transactions (line 12)
- Pub/Sub (line 33)
- Key Type Differences (line 85)
- Fire-and-Forget (line 95)
- API Compatibility Approach (line 107)

---

## Transactions

**StackExchange.Redis:**
```csharp
var tran = db.CreateTransaction();
tran.AddCondition(Condition.KeyNotExists("key"));
_ = tran.StringSetAsync("key", "value");
_ = tran.StringGetAsync("key");
bool committed = await tran.ExecuteAsync();
```

**GLIDE:**
```csharp
// Batch API (when available in C# client)
// Atomic batch = transaction, non-atomic batch = pipeline
```

The C# Batch API is in development. Check the latest GLIDE C# release notes for current transaction support.

---

## Pub/Sub

**StackExchange.Redis:**
```csharp
var sub = muxer.GetSubscriber();
await sub.SubscribeAsync("channel", (channel, message) => {
    Console.WriteLine($"{channel}: {message}");
});
await sub.PublishAsync("channel", "hello");
```

**GLIDE (static subscriptions - at client creation):**
```csharp
var config = new StandaloneClientConfigurationBuilder()
    .WithAddress("localhost", 6379)
    .WithPubSubSubscriptionConfig(new StandalonePubSubSubscriptionConfig()
        .WithChannel("channel")
        .WithPattern("events:*")
        .WithCallback((msg, ctx) => {
            Console.WriteLine($"[{msg.Channel}] {msg.Message}");
        }))
    .Build();

await using var subscriber = await GlideClient.CreateClient(config);
```

**GLIDE (dynamic subscriptions - GLIDE 2.3+):**
```csharp
// Blocking subscribe - waits for confirmation
await subscriber.SubscribeAsync("channel", TimeSpan.FromSeconds(5));
await subscriber.PSubscribeAsync("events:*", TimeSpan.FromSeconds(5));

// Lazy subscribe - returns immediately
await subscriber.SubscribeLazyAsync("updates");
await subscriber.PSubscribeLazyAsync("logs:*");

// Unsubscribe
await subscriber.UnsubscribeAsync("channel", TimeSpan.FromSeconds(5));
await subscriber.UnsubscribeLazyAsync(); // all channels

// Publish (use a separate client)
await publisher.PublishAsync("channel", "hello");
```

Use a dedicated client for subscriptions - a subscribing client enters a special mode where most regular commands are unavailable. GLIDE automatically resubscribes on reconnection.

---

## Key Type Differences

**StackExchange.Redis** uses `RedisKey` and `RedisValue` as wrapper types with implicit conversions from strings. These support both string and binary data with operator overloads.

**GLIDE** uses plain strings for keys and values. Binary data is handled through `GlideString` where needed.

Migration simplifies code - fewer explicit conversions and wrapper types.

---

## Fire-and-Forget

**StackExchange.Redis:**
```csharp
db.StringSet("key", "value", flags: CommandFlags.FireAndForget);
```

**GLIDE** does not support fire-and-forget. Every command returns a result that must be awaited. For equivalent throughput, use non-atomic batches.

---

## API Compatibility Approach

The C# GLIDE client intentionally mirrors StackExchange.Redis naming conventions (`ConnectionMultiplexer`, `StringSetAsync`, `StringGetAsync`) to ease migration. The README states: "API Compatibility: Compatible with StackExchange.Redis APIs to ease migration."

Key positions from the community discussion on API compatibility:

- **Pro-compatibility** (from AWS/GCP stakeholders): Reducing migration effort drives adoption.
- **Anti-compatibility** (from core architect): GLIDE's thin-binding architecture means foreign interfaces would break the design. Dedicated **Adapters** that translate foreign interfaces are preferred over modifying GLIDE core.
- **Tooling approach**: A .NET Roslyn-based migration tool could automate code transformation.

The client has been moved to a separate repository: https://github.com/valkey-io/valkey-glide-csharp
