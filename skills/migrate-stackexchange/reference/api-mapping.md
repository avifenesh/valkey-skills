# StackExchange.Redis to GLIDE API Mapping

Use when migrating specific StackExchange.Redis commands to their GLIDE equivalents, looking up type differences, or converting data type operations.

## Contents

- String Operations (line 12)
- Hash Operations (line 30)
- List Operations (line 49)
- Set Operations (line 66)
- Sorted Set Operations (line 81)
- Delete and Exists (line 96)
- Cluster Mode (line 111)

---

## String Operations

**StackExchange.Redis:**
```csharp
await db.StringSetAsync("key", "value");
await db.StringSetAsync("key", "value", TimeSpan.FromSeconds(60));
await db.StringSetAsync("key", "value", when: When.NotExists);
RedisValue val = await db.StringGetAsync("key");
string str = val.ToString();
```

**GLIDE:**
```csharp
await client.Set("key", "value");
// Expiry and conditional set use options (API may vary in preview)
var val = await client.GetAsync("key");
```

---

## Hash Operations

**StackExchange.Redis:**
```csharp
await db.HashSetAsync("hash", new HashEntry[] {
    new HashEntry("f1", "v1"),
    new HashEntry("f2", "v2"),
});
RedisValue val = await db.HashGetAsync("hash", "f1");
HashEntry[] all = await db.HashGetAllAsync("hash");
```

**GLIDE:**
```csharp
// Hash commands use field-value pairs
await client.HSet("hash", new Dictionary<string, string> {
    { "f1", "v1" },
    { "f2", "v2" },
});
var val = await client.HGet("hash", "f1");
```

---

## List Operations

**StackExchange.Redis:**
```csharp
await db.ListLeftPushAsync("list", new RedisValue[] { "a", "b", "c" });
await db.ListRightPushAsync("list", "x");
RedisValue val = await db.ListLeftPopAsync("list");
RedisValue[] range = await db.ListRangeAsync("list", 0, -1);
```

**GLIDE:**
```csharp
await client.LPush("list", new string[] { "a", "b", "c" });
await client.RPush("list", new string[] { "x" });
var val = await client.LPop("list");
```

---

## Set Operations

**StackExchange.Redis:**
```csharp
await db.SetAddAsync("set", new RedisValue[] { "a", "b", "c" });
await db.SetRemoveAsync("set", "a");
RedisValue[] members = await db.SetMembersAsync("set");
bool isMember = await db.SetContainsAsync("set", "b");
```

**GLIDE:**
```csharp
await client.SAdd("set", new string[] { "a", "b", "c" });
await client.SRem("set", new string[] { "a" });
```

---

## Sorted Set Operations

**StackExchange.Redis:**
```csharp
await db.SortedSetAddAsync("zset", new SortedSetEntry[] {
    new SortedSetEntry("alice", 1.0),
    new SortedSetEntry("bob", 2.0),
});
double? score = await db.SortedSetScoreAsync("zset", "alice");
```

**GLIDE:**
```csharp
// Sorted set commands accept member-score mappings
await client.ZAdd("zset", new Dictionary<string, double> {
    { "alice", 1.0 },
    { "bob", 2.0 },
});
```

---

## Delete and Exists

**StackExchange.Redis:**
```csharp
await db.KeyDeleteAsync(new RedisKey[] { "k1", "k2", "k3" });
bool exists = await db.KeyExistsAsync("k1");
```

**GLIDE:**
```csharp
await client.Del(new string[] { "k1", "k2", "k3" });
var exists = await client.Exists(new string[] { "k1" });
```

---

## Cluster Mode

**StackExchange.Redis:**
```csharp
// StackExchange.Redis auto-detects cluster mode
var options = new ConfigurationOptions
{
    EndPoints = {
        { "node1.example.com", 6379 },
        { "node2.example.com", 6380 },
    },
};
var muxer = ConnectionMultiplexer.Connect(options);
```

**GLIDE:**
```csharp
var config = new ClusterClientConfigurationBuilder()
    .WithAddress("node1.example.com", 6379)
    .WithAddress("node2.example.com", 6380)
    .Build();

await using var client = await GlideClusterClient.CreateClient(config);
```

StackExchange.Redis auto-detects standalone vs cluster mode. GLIDE uses separate client types: `GlideClient` for standalone and `GlideClusterClient` for cluster.
