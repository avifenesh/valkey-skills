# redis-py to GLIDE API Mapping

Use when migrating specific redis-py commands to their GLIDE equivalents, looking up return type differences, or converting data type operations.

## Contents

- String Operations (line 12)
- Hash Operations (line 33)
- List Operations (line 52)
- Set Operations (line 69)
- Sorted Set Operations (line 86)
- Delete and Exists (line 99)
- Cluster Mode (line 114)

---

## String Operations

**redis-py:**
```python
r.set("key", "value")
r.set("key", "value", ex=60)          # expire in 60s
r.set("key", "value", nx=True)        # only if not exists
r.setnx("key", "value")               # same as nx=True
r.setex("key", 60, "value")           # set + expire
val = r.get("key")                     # returns str
```

**GLIDE:**
```python
from glide import ExpirySet, ExpiryType, ConditionalChange

await client.set("key", "value")
await client.set("key", "value", expiry=ExpirySet(ExpiryType.SEC, 60))
await client.set("key", "value", conditional_set=ConditionalChange.ONLY_IF_DOES_NOT_EXIST)
# No separate setnx/setex - use set() with options
val = await client.get("key")          # returns bytes
val.decode()                           # "value"
```

---

## Hash Operations

**redis-py:**
```python
r.hset("hash", "field1", "value1")
r.hset("hash", mapping={"f1": "v1", "f2": "v2"})
val = r.hget("hash", "field1")
all_vals = r.hgetall("hash")           # {"f1": "v1", "f2": "v2"}
```

**GLIDE:**
```python
await client.hset("hash", {"field1": "value1"})
await client.hset("hash", {"f1": "v1", "f2": "v2"})
val = await client.hget("hash", "field1")       # bytes
all_vals = await client.hgetall("hash")          # {b"f1": b"v1", b"f2": b"v2"}
```

---

## List Operations

**redis-py:**
```python
r.lpush("list", "a", "b", "c")
r.rpush("list", "x", "y")
val = r.lpop("list")
vals = r.lrange("list", 0, -1)
```

**GLIDE:**
```python
await client.lpush("list", ["a", "b", "c"])     # list arg, not varargs
await client.rpush("list", ["x", "y"])
val = await client.lpop("list")                  # bytes
vals = await client.lrange("list", 0, -1)        # list of bytes
```

---

## Set Operations

**redis-py:**
```python
r.sadd("set", "a", "b", "c")
r.srem("set", "a")
members = r.smembers("set")
r.sismember("set", "b")
```

**GLIDE:**
```python
await client.sadd("set", ["a", "b", "c"])       # list arg
await client.srem("set", ["a"])                  # list arg
members = await client.smembers("set")           # set of bytes
await client.sismember("set", "b")               # bool
```

---

## Sorted Set Operations

**redis-py:**
```python
r.zadd("zset", {"alice": 1.0, "bob": 2.0})
r.zrange("zset", 0, -1, withscores=True)
r.zscore("zset", "alice")
```

**GLIDE:**
```python
await client.zadd("zset", {"alice": 1.0, "bob": 2.0})
await client.zrange_withscores("zset", RangeByIndex(0, -1))
await client.zscore("zset", "alice")
```

---

## Delete and Exists

**redis-py:**
```python
r.delete("k1", "k2", "k3")           # varargs
r.exists("k1", "k2")                  # returns count
```

**GLIDE:**
```python
await client.delete(["k1", "k2", "k3"])         # list arg
await client.exists(["k1", "k2"])                # returns count
```

---

## Cluster Mode

**redis-py:**
```python
rc = redis.RedisCluster(
    host="node1.example.com",
    port=6379,
    skip_full_coverage_check=True,
)
```

**GLIDE:**
```python
from glide import GlideClusterClient, GlideClusterClientConfiguration, ReadFrom

config = GlideClusterClientConfiguration(
    addresses=[
        NodeAddress("node1.example.com", 6379),
        NodeAddress("node2.example.com", 6380),
    ],
    read_from=ReadFrom.PREFER_REPLICA,
)
client = await GlideClusterClient.create(config)
```

GLIDE discovers the full cluster topology from seed nodes automatically. No need to enumerate all nodes.
