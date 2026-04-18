# Ruby Client Overview

Use when checking GLIDE Ruby capabilities, limitations, and install options.

## Status

**GA** - valkey-rb 1.0.0 on RubyGems. Synchronous blocking API via the Ruby FFI gem calling the bundled GLIDE Rust core. Single `Valkey` class for both standalone and cluster. Designed as a redis-rb drop-in.

## Requirements

- Ruby **>= 2.6.0** (gemspec `required_ruby_version`)
- `ffi` gem
- Pre-built `libglide_ffi.so` (Linux) / `libglide_ffi.dylib` (macOS) bundled in the gem
- **No Windows binary**

## Installation

```bash
gem install valkey-rb
```

Gemfile:
```ruby
gem "valkey-rb"
```

Usage:
```ruby
require "valkey"
valkey = Valkey.new
valkey.set("key", "value")
```

Namespace is `Valkey`, not `ValkeyGlide`. `require "valkey"` gives you everything.

## Command groups

20 command modules included in the `Commands` module; all are mixed into `Valkey` instances.

| Module | Key commands |
|--------|-------------|
| StringCommands | `set`, `get`, `incr`, `mget`, `mset`, `append`, `getdel`, `getex` |
| HashCommands | `hset`, `hget`, `hgetall`, `hdel`, `hmset`, `hscan` |
| ListCommands | `lpush`, `rpush`, `lpop`, `rpop`, `lrange`, `blpop`, `brpop` |
| SetCommands | `sadd`, `smembers`, `sismember`, `sdiff`, `sinter`, `sunion` |
| SortedSetCommands | `zadd`, `zscore`, `zrank`, `zrange`, `zpopmin`, `zpopmax` |
| StreamCommands | `xadd`, `xread`, `xreadgroup`, `xack`, `xclaim`, `xautoclaim` |
| PubSubCommands | `subscribe`, `publish`, `psubscribe`, `ssubscribe`, `spublish` |
| ScriptingCommands | `eval`, `evalsha`, `script_*` |
| TransactionCommands | `multi`, `watch`, `unwatch`, `discard` |
| GenericCommands | `del`, `exists`, `expire`, `ttl`, `type`, `scan`, `keys`, `sort` |
| GeoCommands | `geoadd`, `geodist`, `geosearch`, `geosearchstore` |
| BitmapCommands | `setbit`, `getbit`, `bitcount`, `bitop`, `bitfield` |
| HyperLogLogCommands | `pfadd`, `pfcount`, `pfmerge` |
| JsonCommands | Valkey JSON module |
| VectorSearchCommands | Valkey Search module (`FT.SEARCH`, `FT.AGGREGATE`) |
| ClusterCommands | `cluster_info`, `cluster_nodes`, `cluster_slots`, `cluster_addslots`, etc. |
| ConnectionCommands | `ping`, `echo`, `select`, `auth`, `hello`, `client_*`, `quit` |
| ServerCommands | `info`, `dbsize`, `flushdb`, `config_*`, `acl_*`, `slowlog_*` |
| FunctionCommands | `function_load`, `fcall`, `fcall_ro` |
| ModuleCommands | `module_load`, `module_list`, `module_unload` |

## Batching

Two block forms. Both match the redis-rb API shape, with one caveat.

```ruby
# Pipeline - non-atomic, higher throughput
results = valkey.pipelined do |pipe|
  pipe.set("a", 1)
  pipe.incr("a")
  pipe.get("a")
end

# MULTI - atomic transaction
results = valkey.multi do |tx|
  tx.set("a", 1)
  tx.incr("a")
end
```

**FFI stability caveat on `pipelined` containing MULTI/EXEC/DISCARD.** The gem detects transactional request types inside a `pipelined` block and falls back to sequential execution instead of native batching (from `lib/valkey.rb`: `WORKAROUND: The underlying Glide FFI backend has stability issues when batching transactional commands`). For atomic transactions use `multi do |tx|` directly - not nested inside `pipelined`.

`watch` outside a `multi` block for optimistic locking:

```ruby
valkey.watch("key")
if valkey.get("key") == "expected"
  valkey.multi do |tx|
    tx.set("key", "new")
  end
end
```

## Error hierarchy

All under the `Valkey` namespace, nested under `BaseError`:

```
Valkey::BaseError < StandardError
|-- ProtocolError                       # bad initial reply byte (forking issue)
|-- CommandError                        # server command errors
|   |-- PermissionError                 # ACL denied
|   |-- WrongTypeError                  # WRONGTYPE
|   |-- OutOfMemoryError                # OOM
|   `-- NoScriptError                   # NOSCRIPT on EVALSHA
|-- BaseConnectionError                 # connection issues
|   |-- CannotConnectError              # initial connect failed
|   |-- ConnectionError                 # lost mid-operation
|   |-- TimeoutError                    # request timeout
|   |-- InheritedError                  # forked socket inherited
|   `-- ReadOnlyError                   # write to read-only replica
|-- InvalidClientOptionError            # bad constructor args
`-- SubscriptionError                   # PubSub state violation
```

Rescue `Valkey::BaseError` to catch everything from the client. `CommandError` errors inside an EXEC response come back as `CommandError` instances inside the result array (not raised) - check each result for that class before using it.

## Client statistics

**Method is `statistics` - NOT `get_statistics`.** Returns a FLAT hash of integer counters:

```ruby
stats = client.statistics

stats[:total_connections]         # all connections opened to Valkey
stats[:total_clients]             # total GLIDE clients
stats[:total_values_compressed]
stats[:total_values_decompressed]
stats[:total_original_bytes]
stats[:total_bytes_compressed]
stats[:total_bytes_decompressed]
stats[:compression_skipped_count]
```

These counters are **process-global**, tracked across all clients in the Ruby process. There is no `connection_stats` or `command_stats` nested hash - do not invent one.

## OpenTelemetry

**Configure via the module method, NOT a constructor flag.** Valid endpoints are `http://`, `grpc://`, or `file://`.

```ruby
require "valkey"

Valkey::OpenTelemetry.init(
  traces: {
    endpoint: "http://localhost:4318/v1/traces",
    sample_percentage: 10
  },
  metrics: {
    endpoint: "http://localhost:4318/v1/metrics"
  },
  flush_interval_ms: 5000
)

client = Valkey.new
# Subsequent commands emit spans / metrics automatically.
```

Call `init` once per process. The module warns and no-ops on a second init. `Valkey.new(tracing: true)` has no effect - that option does not exist in `initialize`.

## Features matrix

| Feature | Available | Notes |
|---------|-----------|-------|
| Standalone mode | Yes | `Valkey.new(host:, port:)` |
| Cluster mode | Yes | `Valkey.new(nodes:, cluster_mode: true)` |
| TLS / mTLS | Yes | `ssl: true` + `ssl_params:` |
| Auth - password, ACL | Yes | `password:`, `username:` |
| URL-based connect | Yes | `redis://` / `rediss://` |
| PubSub exact / pattern | Yes | Varargs + `pubsub_callback` |
| Sharded PubSub | Yes | `ssubscribe`, `spublish`, `sunsubscribe` |
| Pipelining | Yes | `pipelined { \|pipe\| }` |
| Transactions | Yes | `multi { \|tx\| }` (use outside `pipelined` due to FFI workaround) |
| OpenTelemetry | Yes | `Valkey::OpenTelemetry.init` (not a constructor option) |
| Statistics | Yes | `client.statistics` (not `get_statistics`) |
| Valkey Functions | Yes | `fcall`, `fcall_ro`, `function_load` |
| Valkey JSON | Yes | Via JsonCommands |
| Valkey Search | Yes | Via VectorSearchCommands |
| redis-rb drop-in | Mostly | Subscribe/unsubscribe block form NOT supported |
| Async API | **No** | Ruby FFI binding is synchronous |
| Windows | **No** | Pre-built binaries for Linux and macOS only |

## redis-rb drop-in notes

Replace `require "redis"` with `require "valkey"` and `Redis.new` with `Valkey.new`. Most method signatures and return types match. Known divergences:

- **No `redis.subscribe("ch") { |on| on.message { } }` block.** Override `pubsub_callback` instead (see features-pubsub).
- **Statistics method name differs** (`statistics`, not something else).
- **MULTI inside `pipelined`** runs sequentially due to FFI stability.
- **`disconnect!` is an alias for `close`** - both work.

## Repository

`valkey-io/valkey-glide-ruby` (separate repo from the main GLIDE monorepo). Gem name: `valkey-rb`.
