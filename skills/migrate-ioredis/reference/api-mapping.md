# ioredis to GLIDE API Mapping

Use when migrating specific ioredis commands to their GLIDE equivalents, looking up argument format changes, or converting data type operations.

## Contents

- String Operations (line 12)
- Hash Operations (line 32)
- List Operations (line 51)
- Set Operations (line 66)
- Sorted Set Operations (line 81)
- Delete and Exists (line 104)
- Cluster Mode (line 117)

---

## String Operations

**ioredis:**
```javascript
await redis.set("key", "value");
await redis.set("key", "value", "EX", 60);
await redis.set("key", "value", "NX");
await redis.setex("key", 60, "value");
const val = await redis.get("key");
```

**GLIDE:**
```javascript
import { TimeUnit } from "@valkey/valkey-glide";

await client.set("key", "value");
await client.set("key", "value", { expiry: { type: TimeUnit.Seconds, count: 60 } });
await client.set("key", "value", { conditionalSet: "onlyIfDoesNotExist" });
// No separate setex - use set() with expiry option
const val = await client.get("key");
```

---

## Hash Operations

**ioredis:**
```javascript
await redis.hset("hash", "f1", "v1", "f2", "v2");    // spread pairs
await redis.hset("hash", { f1: "v1", f2: "v2" });     // also works
const val = await redis.hget("hash", "f1");
const all = await redis.hgetall("hash");                // {f1: "v1", f2: "v2"}
```

**GLIDE:**
```javascript
// Object form or HashDataType array form
await client.hset("hash", { f1: "v1", f2: "v2" });
await client.hset("hash", [{ field: "f1", value: "v1" }, { field: "f2", value: "v2" }]);
const val = await client.hget("hash", "f1");
const all = await client.hgetall("hash");               // Record<string, string>
```

---

## List Operations

**ioredis:**
```javascript
await redis.lpush("list", "a", "b", "c");
await redis.rpush("list", "x", "y");
const val = await redis.lpop("list");
const range = await redis.lrange("list", 0, -1);
```

**GLIDE:**
```javascript
await client.lpush("list", ["a", "b", "c"]);            // array arg
await client.rpush("list", ["x", "y"]);
const val = await client.lpop("list");
const range = await client.lrange("list", 0, -1);
```

---

## Set Operations

**ioredis:**
```javascript
await redis.sadd("set", "a", "b", "c");
await redis.srem("set", "a", "b");
const members = await redis.smembers("set");
```

**GLIDE:**
```javascript
await client.sadd("set", ["a", "b", "c"]);              // array arg
await client.srem("set", ["a", "b"]);
const members = await client.smembers("set");
```

---

## Sorted Set Operations

**ioredis:**
```javascript
await redis.zadd("zset", 1, "alice", 2, "bob");         // score, member pairs
await redis.zadd("zset", "NX", 1, "alice");              // NX flag
const score = await redis.zscore("zset", "alice");
const range = await redis.zrange("zset", 0, -1, "WITHSCORES");
```

**GLIDE:**
```javascript
import { ConditionalChange } from "@valkey/valkey-glide";

// Array of {element, score} objects or Record<string, number>
await client.zadd("zset", [
    { element: "alice", score: 1 },
    { element: "bob", score: 2 },
]);
await client.zadd("zset", { alice: 1 }, { conditionalChange: ConditionalChange.ONLY_IF_DOES_NOT_EXIST });
const score = await client.zscore("zset", "alice");
const range = await client.zrangeWithScores("zset", { start: 0, end: -1 });
```

---

## Delete and Exists

**ioredis:**
```javascript
await redis.del("k1", "k2", "k3");
const count = await redis.exists("k1", "k2");
```

**GLIDE:**
```javascript
await client.del(["k1", "k2", "k3"]);                   // array arg
const count = await client.exists(["k1", "k2"]);
```

---

## Cluster Mode

**ioredis:**
```javascript
const cluster = new Redis.Cluster([
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
], { scaleReads: "slave" });
```

**GLIDE:**
```javascript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "node1.example.com", port: 6379 },
        { host: "node2.example.com", port: 6380 },
    ],
    readFrom: "preferReplica",
});
```

GLIDE auto-discovers the full topology from seed nodes. No natMap or manual slot configuration needed.
