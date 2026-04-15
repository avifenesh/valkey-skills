# Ruby Client Overview

Use when checking GLIDE Ruby capabilities, available commands, and limitations.

## Status

**GA** - valkey-rb 1.0.0 published on RubyGems. Production-ready. Synchronous (blocking) API via Ruby FFI gem, redis-rb drop-in replacement, single `Valkey` class for both standalone and cluster.

## Requirements

- Ruby 2.6+
- FFI gem (~> 1.17.0)
- google-protobuf gem (~> 3.23)
- Valkey 7.2+ or Redis 6.2+

The gem bundles pre-built `libglide_ffi.so` (Linux) or `libglide_ffi.dylib` (macOS).

## Installation

```bash
gem install valkey-rb
```

Or in Gemfile:

```ruby
gem 'valkey-rb'
```

## Available Command Groups

20 command modules covering the full Valkey command surface:

| Module | Key Commands |
|--------|-------------|
| StringCommands | `set`, `get`, `incr`, `mget`, `mset`, `append`, `getdel`, `getex` |
| HashCommands | `hset`, `hget`, `hgetall`, `hdel`, `hmset`, `hscan` |
| ListCommands | `lpush`, `rpush`, `lpop`, `rpop`, `lrange`, `blpop`, `brpop` |
| SetCommands | `sadd`, `smembers`, `sismember`, `sdiff`, `sinter`, `sunion` |
| SortedSetCommands | `zadd`, `zscore`, `zrank`, `zrange`, `zpopmin`, `zpopmax` |
| StreamCommands | `xadd`, `xread`, `xreadgroup`, `xack`, `xclaim`, `xautoclaim` |
| PubSubCommands | `subscribe`, `publish`, `psubscribe`, `ssubscribe`, `spublish` |
| ScriptingCommands | `eval`, `evalsha`, `script` |
| TransactionCommands | `multi`, `exec`, `discard`, `watch`, `unwatch` |
| GenericCommands | `del`, `exists`, `expire`, `ttl`, `type`, `scan`, `keys`, `sort` |
| GeoCommands | `geoadd`, `geodist`, `geosearch`, `geosearchstore` |
| BitmapCommands | `setbit`, `getbit`, `bitcount`, `bitop`, `bitfield` |
| HyperLogLogCommands | `pfadd`, `pfcount`, `pfmerge` |
| JsonCommands | JSON module commands |
| VectorSearchCommands | FT.SEARCH, FT.AGGREGATE |
| ClusterCommands | `cluster info`, `cluster nodes`, `cluster slots` |
| ConnectionCommands | `ping`, `echo`, `select`, `auth`, `hello`, `client` |
| ServerCommands | `info`, `dbsize`, `flushdb`, `config`, `acl`, `slowlog` |
| FunctionCommands | `function load`, `fcall`, `fcall_ro` |
| ModuleCommands | `module load`, `module list` |

## Features

| Feature | Available | Notes |
|---------|-----------|-------|
| Standalone mode | Yes | `Valkey.new(host: ...)` |
| Cluster mode | Yes | `Valkey.new(nodes: [...], cluster_mode: true)` |
| TLS/mTLS | Yes | `ssl: true`, `ssl_params: { ... }` |
| Authentication | Yes | Password, ACL username+password |
| PubSub | Yes | Subscribe, psubscribe, ssubscribe (sharded) |
| Pipelining | Yes | `client.pipelined { \|pipe\| ... }` |
| Transactions | Yes | `client.multi { \|tx\| ... }` |
| OpenTelemetry | Yes | `tracing: true` in constructor |
| Client statistics | Yes | `client.get_statistics` |
| redis-rb compat | Yes | Drop-in replacement API |
| URL-based connect | Yes | `redis://` and `rediss://` schemes |
| Server modules | Yes | JSON and vector search commands |
| Functions | Yes | Valkey Functions (FCALL) |

## OpenTelemetry

Built-in tracing - no separate instrumentation gem needed:

```ruby
require "valkey"
require "opentelemetry/sdk"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my-app"
end

client = Valkey.new(host: "localhost", port: 6379, tracing: true)
# All commands are automatically traced
```

## Client Statistics

```ruby
client = Valkey.new
client.set("key", "value")

stats = client.get_statistics
puts "Active connections: #{stats[:connection_stats][:active_connections]}"
puts "Total commands: #{stats[:command_stats][:total_commands]}"
```

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

## redis-rb Drop-In Replacement

Change `require "redis"` to `require "valkey"` and `Redis.new` to `Valkey.new`. Same method names, return types, `pipelined` block syntax, `multi`/`exec` pattern, URL schemes, and `disconnect!` alias.

## Limitations

- No official framework integrations documented (Rails, Sidekiq)
- No async API - Ruby FFI binding is synchronous
- No Windows support (pre-built binaries for Linux and macOS only)

## Repository

Separate repo: [valkey-io/valkey-glide-ruby](https://github.com/valkey-io/valkey-glide-ruby)

Gem: `gem install valkey-rb`
