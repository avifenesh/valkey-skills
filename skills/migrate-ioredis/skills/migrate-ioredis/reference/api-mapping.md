# ioredis to GLIDE: where signatures diverge

Use when translating ioredis calls and the signature is NOT obvious. Where GLIDE mirrors ioredis (most commands), just replace `redis.` with `await client.` - that pattern is not listed here.

## Three universal changes

Apply to every command:

1. **Await needed**: GLIDE returns Promises; ioredis returns ioredis-Promise-like objects that sometimes work sync-ish in pipelines. Add `await`.
2. **Array args, not varargs**: multi-key / multi-value commands take a list, not positional args.
3. **Default decoder returns `string`**: use `defaultDecoder: Decoder.Bytes` or per-command `{ decoder: Decoder.Bytes }` to get `Buffer` returns.

```javascript
// ioredis varargs:
redis.del("k1", "k2", "k3");
redis.exists("k1", "k2");
redis.lpush("list", "a", "b", "c");
redis.sadd("set", "a", "b", "c");
redis.srem("set", "a", "b");

// GLIDE: wrap the multi args in a list:
await client.del(["k1", "k2", "k3"]);
await client.exists(["k1", "k2"]);
await client.lpush("list", ["a", "b", "c"]);
await client.sadd("set", ["a", "b", "c"]);
await client.srem("set", ["a", "b"]);
```

## SET: typed options replace kwargs and specialized methods

ioredis accepts positional kwargs (`"EX", 60`), plus specialized `setex` / `psetex` / `setnx`. GLIDE routes all of them through typed options on `set()` and drops the aliases.

| ioredis | GLIDE |
|---------|-------|
| `redis.set(k, v, "EX", 60)` | `await client.set(k, v, { expiry: { type: TimeUnit.Seconds, count: 60 } })` |
| `redis.set(k, v, "PX", 500)` | `await client.set(k, v, { expiry: { type: TimeUnit.Milliseconds, count: 500 } })` |
| `redis.set(k, v, "EXAT", ts)` | `await client.set(k, v, { expiry: { type: TimeUnit.UnixSeconds, count: ts } })` |
| `redis.set(k, v, "PXAT", ms)` | `await client.set(k, v, { expiry: { type: TimeUnit.UnixMilliseconds, count: ms } })` |
| `redis.set(k, v, "NX")` or `redis.setnx(k, v)` | `await client.set(k, v, { conditionalSet: "onlyIfDoesNotExist" })` |
| `redis.set(k, v, "XX")` | `await client.set(k, v, { conditionalSet: "onlyIfExists" })` |
| `redis.setex(k, 60, v)` | `await client.set(k, v, { expiry: { type: TimeUnit.Seconds, count: 60 } })` |
| `redis.set(k, v, "KEEPTTL")` | `await client.set(k, v, { expiry: "keepExisting" })` |

`TimeUnit` has four values: `Seconds`, `Milliseconds`, `UnixSeconds`, `UnixMilliseconds` (note the spelling - no typo, unlike Python's `UNIX_MILLSEC`). All PascalCase.

`conditionalSet` for `set()` uses STRING LITERALS: `"onlyIfExists" | "onlyIfDoesNotExist" | "onlyIfEqual"`. Valkey 9.0's IFEQ needs `conditionalSet: "onlyIfEqual"` plus `comparisonValue: "..."`. Other commands (ZADD) use a separate `ConditionalChange` enum - they are NOT the same type.

## HSET: takes an object, not spread pairs

```javascript
// ioredis (either works):
redis.hset("h", "f1", "v1", "f2", "v2");
redis.hset("h", { f1: "v1", f2: "v2" });

// GLIDE - object OR [{field, value}] array:
await client.hset("h", { f1: "v1", f2: "v2" });
await client.hset("h", [{ field: "f1", value: "v1" }, { field: "f2", value: "v2" }]);
```

## ZADD: `{element, score}` objects, separate `zrangeWithScores`

```javascript
// ioredis:
redis.zadd("z", 1, "alice", 2, "bob");
redis.zadd("z", "NX", 1, "alice");
redis.zrange("z", 0, -1, "WITHSCORES");

// GLIDE:
import { ConditionalChange } from "@valkey/valkey-glide";

await client.zadd("z", [{ element: "alice", score: 1 }, { element: "bob", score: 2 }]);
await client.zadd("z", { alice: 1 }, { conditionalChange: ConditionalChange.ONLY_IF_DOES_NOT_EXIST });
await client.zrangeWithScores("z", { start: 0, stop: -1 });  // NOTE: `stop`, not `end`
```

`ConditionalChange` is ALL_CAPS enum (GLIDE_NODE convention for this specific enum) with two values: `ONLY_IF_EXISTS`, `ONLY_IF_DOES_NOT_EXIST`. For ZADD only.

## Cluster: `Redis.Cluster` -> `GlideClusterClient`

```javascript
// ioredis:
const cluster = new Redis.Cluster([
    { host: "n1", port: 6379 }, { host: "n2", port: 6379 },
], { scaleReads: "slave" });

// GLIDE:
const client = await GlideClusterClient.createClient({
    addresses: [{ host: "n1", port: 6379 }, { host: "n2", port: 6379 }],
    readFrom: "preferReplica",
});
```

Full topology auto-discovered from seed nodes. `scaleReads: "slave"` maps to `readFrom: "preferReplica"`. `natMap` / manual slot map / `skipFullCoverageCheck` have no equivalent; GLIDE handles discovery internally.

## Everything else is named the same

For 90% of commands (`get`, `hget`, `hgetall`, `lpop`, `lrange`, `smembers`, `sismember`, `zscore`, `exists`, `ttl`, `expire`, `keys`, `type`, `incr`/`decr`, `xadd`/`xread`/`xreadgroup`/`xack`, `publish` BUT WITH REVERSED ARGS, etc.) the only changes are the three universal ones at the top of this file. Just translate.
