---
name: valkey-glide-ruby
description: "Use when building Ruby applications with Valkey GLIDE. Covers the Ruby client (in development), installation from source, and planned features."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey GLIDE Ruby Client Reference

Synchronous Ruby client for Valkey built on the GLIDE Rust core via FFI. Designed as a drop-in replacement for redis-rb. Version 1.0.0 published but no gem release yet - install from source.

**Repository:** [valkey-io/valkey-glide-ruby](https://github.com/valkey-io/valkey-glide-ruby)

**Status:** In active development. No published gem on RubyGems yet.

## Installation

### From Source (Current)

```bash
git clone https://github.com/valkey-io/valkey-glide-ruby.git
cd valkey-glide-ruby
bundle install
```

### From RubyGems (Planned)

```bash
gem install valkey-rb
```

**Requirements:** Ruby 2.6+, FFI gem (~> 1.17.0), google-protobuf gem (~> 3.23)

**Dependencies:** The gem bundles pre-built `libglide_ffi.so` (Linux) or `libglide_ffi.dylib` (macOS) - the Rust core library accessed via Ruby FFI.

---

## Client Class

The Ruby client uses a single `Valkey` class. Standalone and cluster modes are controlled by the `cluster_mode` option at initialization.

```ruby
require "valkey"

# Standalone
client = Valkey.new(host: "localhost", port: 6379)

# Cluster mode
client = Valkey.new(
  nodes: [
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
  ],
  cluster_mode: true
)
```

---

## Basic Operations

```ruby
require "valkey"

client = Valkey.new

client.set("mykey", "hello world")
# => "OK"

client.get("mykey")
# => "hello world"

client.set("counter", "0")
client.incr("counter")
# => 1

client.del("mykey")
client.close
```

---

## Configuration

All configuration is passed as an options hash to `Valkey.new`:

```ruby
client = Valkey.new(
  host: "localhost",
  port: 6379,
  password: "secret",
  username: "myuser",
  db: 0,
  ssl: true,
  timeout: 5.0,
  connect_timeout: 3.0,
  client_name: "my-app",
  protocol: :resp2,
)
```

### URL-Based Connection

```ruby
client = Valkey.new(url: "redis://user:pass@localhost:6379/0")
```

### TLS/SSL

```ruby
client = Valkey.new(
  host: "valkey.example.com",
  port: 6380,
  ssl: true,
  ssl_params: {
    ca_file: "/path/to/ca.crt",
    cert: "/path/to/client.crt",
    key: "/path/to/client.key",
  }
)
```

### Reconnection

```ruby
client = Valkey.new(
  reconnect_attempts: 5,
  reconnect_delay: 0.5,
  reconnect_delay_max: 5.0,
)
```

---

## Command Coverage

The Ruby client implements commands across 20 modules:

| Module | Commands |
|--------|----------|
| StringCommands | set, get, incr, decr, incrby, decrby, incrbyfloat, mget, mset, append, getrange, setrange, strlen, getdel, getex, setnx, setex, psetex, msetnx |
| HashCommands | hset, hget, hdel, hgetall, hexists, hkeys, hvals, hlen, hmset, hmget, hincrby, hincrbyfloat, hsetnx, hrandfield, hscan |
| ListCommands | lpush, rpush, lpop, rpop, lrange, llen, lindex, lset, lrem, linsert, lpos, ltrim, blpop, brpop, lmpop, blmpop |
| SetCommands | sadd, srem, smembers, sismember, scard, spop, srandmember, sdiff, sinter, sunion, sdiffstore, sinterstore, sunionstore, smismember, sscan |
| SortedSetCommands | zadd, zrem, zscore, zrank, zrange, zcard, zcount, zincrby, zrangebyscore, zrangebylex, zrevrange, zlexcount, zpopmin, zpopmax, zrandmember, zrangestore, zmscore, zunionstore, zinterstore, zdiffstore, zscan, bzpopmin, bzpopmax |
| StreamCommands | xadd, xlen, xrange, xrevrange, xread, xreadgroup, xack, xclaim, xautoclaim, xdel, xtrim, xinfo, xgroup |
| PubSubCommands | publish, subscribe, unsubscribe, psubscribe, punsubscribe |
| ScriptingCommands | eval, evalsha, script |
| TransactionCommands | multi, exec, discard, watch, unwatch |
| GenericCommands | del, exists, expire, expireat, ttl, pttl, persist, type, rename, renamenx, keys, scan, sort, object, dump, restore, unlink, touch, randomkey, wait, copy, expiretime, pexpiretime |
| GeoCommands | geoadd, geodist, geohash, geopos, geosearch, geosearchstore |
| BitmapCommands | setbit, getbit, bitcount, bitop, bitpos, bitfield |
| HyperLogLogCommands | pfadd, pfcount, pfmerge |
| JsonCommands | JSON module commands |
| VectorSearchCommands | FT.SEARCH, FT.AGGREGATE vector search commands |
| ClusterCommands | cluster info, cluster nodes, cluster slots |
| ConnectionCommands | ping, echo, select, quit, auth |
| ServerCommands | info, dbsize, flushdb, flushall, config, client, command, debug, memory, slowlog, acl, latency, time, lastsave, bgsave, bgrewriteaof |
| FunctionCommands | function load, function list, function dump, function restore, function delete, function flush, fcall, fcall_ro |
| ModuleCommands | module load, module unload, module list |

---

## Pipelining

```ruby
results = client.pipelined do |pipe|
  pipe.set("k1", "v1")
  pipe.set("k2", "v2")
  pipe.get("k1")
  pipe.get("k2")
end
# => ["OK", "OK", "v1", "v2"]
```

Pipelines batch commands into a single round-trip via the Rust core's batch API.

---

## Transactions

```ruby
client.multi do |tx|
  tx.set("k1", "v1")
  tx.incr("counter")
  tx.get("k1")
end
```

MULTI/EXEC transactions are also available via direct commands:

```ruby
client.multi
client.set("k1", "v1")
client.incr("counter")
results = client.exec
```

---

## Error Types

| Exception | Description |
|-----------|-------------|
| `Valkey::CommandError` | Command execution error |
| `Valkey::PermissionError` | ACL permission denied |
| `Valkey::WrongTypeError` | Wrong data type for command |
| `Valkey::OutOfMemoryError` | Server out of memory |
| `Valkey::NoScriptError` | EVALSHA script not found |
| `Valkey::CannotConnectError` | Initial connection failed |
| `Valkey::ConnectionError` | Connection lost during operation |
| `Valkey::TimeoutError` | Request timed out |
| `Valkey::ReadOnlyError` | Write to read-only replica |
| `Valkey::SubscriptionError` | PubSub subscription error |

---

## OpenTelemetry

Built-in tracing support:

```ruby
require "valkey"
require "opentelemetry/sdk"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my-app"
end

client = Valkey.new(
  host: "localhost",
  port: 6379,
  tracing: true
)

# All commands are automatically traced
client.set("key", "value")
client.get("key")
```

---

## Client Statistics

```ruby
client = Valkey.new

client.set("key", "value")
stats = client.statistics

puts "Total connections: #{stats[:total_connections]}"
puts "Total clients: #{stats[:total_clients]}"
puts "Values compressed: #{stats[:total_values_compressed]}"
```

---

## redis-rb Compatibility

The Ruby client is designed as a drop-in replacement for redis-rb. The API follows redis-rb conventions:

- Same method names (`set`, `get`, `hset`, `lpush`, etc.)
- Same return types (strings, integers, arrays, nil for missing keys)
- Same `pipelined` block syntax
- Same `multi`/`exec` transaction pattern
- URL-based connection strings (`redis://...`)
- `disconnect!` alias for `close`

---

## Architecture Notes

- **Communication layer**: Ruby FFI binding to the Rust GLIDE core (`libglide_ffi`)
- Protobuf-based serialization for command requests/responses
- Synchronous blocking API
- Single multiplexed connection per node
- Maintained in a separate repository from the main GLIDE monorepo

---

## Limitations

- No published gem on RubyGems yet - install from source
- No Windows support (depends on native Rust library)
- Cluster mode available via `cluster_mode: true` option but less tested than standalone
- Some advanced features may not be available yet
- No official framework integrations (Rails, Sidekiq) documented
