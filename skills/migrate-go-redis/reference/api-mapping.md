# go-redis to GLIDE API Mapping

Use when migrating specific go-redis commands to their GLIDE equivalents, looking up return type differences, or converting data type operations.

## Contents

- String Operations (line 12)
- Hash Operations (line 34)
- List Operations (line 53)
- Set Operations (line 72)
- Sorted Set Operations (line 89)
- Delete and Exists (line 104)
- Cluster Mode (line 119)

---

## String Operations

**go-redis:**
```go
err := rdb.Set(ctx, "key", "value", 0).Err()
err = rdb.Set(ctx, "key", "value", 60*time.Second).Err()  // with expiry
val, err := rdb.Get(ctx, "key").Result()
```

**GLIDE:**
```go
import (
    "time"
    "github.com/valkey-io/valkey-glide/go/v2/options"
)

_, err := client.Set(ctx, "key", "value")
// With expiry - use SetWithOptions
opts := options.NewSetOptions().
    SetExpiry(options.NewExpiryIn(60 * time.Second))
_, err = client.SetWithOptions(ctx, "key", "value", *opts)
val, err := client.Get(ctx, "key")
fmt.Println(val.Value())  // string
```

---

## Hash Operations

**go-redis:**
```go
rdb.HSet(ctx, "hash", "f1", "v1", "f2", "v2")   // varargs pairs
rdb.HSet(ctx, "hash", map[string]interface{}{"f1": "v1"})
val, err := rdb.HGet(ctx, "hash", "f1").Result()
all, err := rdb.HGetAll(ctx, "hash").Result()     // map[string]string
```

**GLIDE:**
```go
client.HSet(ctx, "hash", map[string]string{"f1": "v1", "f2": "v2"})
val, err := client.HGet(ctx, "hash", "f1")
if !val.IsNil() {
    fmt.Println(val.Value())
}
all, err := client.HGetAll(ctx, "hash")           // map[string]string
```

---

## List Operations

**go-redis:**
```go
rdb.LPush(ctx, "list", "a", "b", "c")
rdb.RPush(ctx, "list", "x", "y")
val, err := rdb.LPop(ctx, "list").Result()
vals, err := rdb.LRange(ctx, "list", 0, -1).Result()
```

**GLIDE:**
```go
client.LPush(ctx, "list", []string{"a", "b", "c"})     // slice arg
client.RPush(ctx, "list", []string{"x", "y"})
val, err := client.LPop(ctx, "list")
if !val.IsNil() {
    fmt.Println(val.Value())
}
vals, err := client.LRange(ctx, "list", 0, -1)          // []string
```

---

## Set Operations

**go-redis:**
```go
rdb.SAdd(ctx, "set", "a", "b", "c")
rdb.SRem(ctx, "set", "a")
members, err := rdb.SMembers(ctx, "set").Result()
isMember, err := rdb.SIsMember(ctx, "set", "b").Result()
```

**GLIDE:**
```go
client.SAdd(ctx, "set", []string{"a", "b", "c"})
client.SRem(ctx, "set", []string{"a"})
members, err := client.SMembers(ctx, "set")              // map[string]struct{}
isMember, err := client.SIsMember(ctx, "set", "b")       // bool
```

---

## Sorted Set Operations

**go-redis:**
```go
rdb.ZAdd(ctx, "zset", redis.Z{Score: 1.0, Member: "alice"},
                       redis.Z{Score: 2.0, Member: "bob"})
score, err := rdb.ZScore(ctx, "zset", "alice").Result()
```

**GLIDE:**
```go
client.ZAdd(ctx, "zset", map[string]float64{
    "alice": 1.0,
    "bob":   2.0,
})
score, err := client.ZScore(ctx, "zset", "alice")
fmt.Println(score.Value())  // 1.0
```

---

## Delete and Exists

**go-redis:**
```go
rdb.Del(ctx, "k1", "k2", "k3")                // varargs
count, err := rdb.Exists(ctx, "k1", "k2").Result()
```

**GLIDE:**
```go
client.Del(ctx, []string{"k1", "k2", "k3"})   // slice arg
count, err := client.Exists(ctx, []string{"k1", "k2"})
```

---

## Cluster Mode

**go-redis:**
```go
rdb := redis.NewClusterClient(&redis.ClusterOptions{
    Addrs: []string{
        "node1.example.com:6379",
        "node2.example.com:6380",
    },
    ReadOnly: true,
})
```

**GLIDE:**
```go
cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6380}).
    WithReadFrom(config.PreferReplica)

client, err := glide.NewClusterClient(cfg)
```
