---
name: valkey-glide-ruby
description: "Use when building Ruby apps with Valkey GLIDE - valkey-rb gem (GA), single Valkey class, drop-in for redis-rb, FFI bridge, varargs subscribe, pubsub_callback module method, pipelined/multi blocks, statistics method, Valkey::OpenTelemetry.init. Assumes redis-rb knowledge; only GLIDE divergence is documented."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Ruby Client

Agent-facing skill for valkey-rb (GLIDE Ruby). Assumes the reader can already write redis-rb from training (`Redis.new`, `redis.set/get`, `pipelined { }`, `multi { }`). Covers only what GLIDE diverges on and what GLIDE adds on top.

**Separate repository:** `valkey-io/valkey-glide-ruby`. Gem: `valkey-rb` on RubyGems (v1.0.0 GA).

## Routing

| Question | Reference |
|----------|-----------|
| `Valkey.new` single class for both modes (`cluster_mode: true` + `nodes:`), `url:`, TLS via `ssl:` + `ssl_params:` (`ca_file`, `cert`, `key`, `ca_path`, `root_certs`), reconnect, auth, `disconnect!` alias | [connection](reference/features-connection.md) |
| Varargs `subscribe(*channels)` / `psubscribe(*patterns)` - NOT arrays; no `on.message` block form; override `pubsub_callback` module method; sharded `ssubscribe` / `spublish` implemented; introspection via `pubsub_*` helpers | [pubsub](reference/features-pubsub.md) |
| `gem install valkey-rb`, Ruby 2.6+, nested error hierarchy, `pipelined { }` / `multi { }` blocks, **MULTI/EXEC batching falls back to sequential** (FFI stability), `statistics` (NOT `get_statistics`), `Valkey::OpenTelemetry.init` | [overview](reference/features-overview.md) |

## Multiplexer rule

One `Valkey` instance is the shared multiplexer for a Ruby process (Puma worker, Sidekiq worker, Rails app, long-running CLI). Do not create per-request clients. Do not pool multiple instances against the same node. The Rust core pipelines concurrent Ruby threads' commands across the multiplexed connection.

**Exceptions that need a dedicated client instance:**

- PubSub subscribers (`subscribe` / `psubscribe` / `ssubscribe` hold the connection in subscriber mode - occupancy).
- Blocking commands (`blpop`, `brpop`, `blmove`, `bzpopmin`, `bzpopmax`, `blmpop`, `bzmpop`, `xread` / `xreadgroup` with `block`, `wait`) - occupancy, they hold the multiplexed connection for the block duration.
- `watch` / `multi` / `exec` optimistic-locking flows - connection-state leakage on a shared multiplexer, not occupancy.

Large values are NOT an exception - they pipeline through the multiplexer fine.

## The #1 agent mistake: statistics method

Models often invent `client.get_statistics` with a nested `stats[:connection_stats][:active_connections]` shape. Neither exists. The real API is:

```ruby
stats = client.statistics   # NO `get_` prefix
stats[:total_connections]   # flat keys only
stats[:total_clients]
stats[:total_values_compressed]
# ... all top-level integer keys
```

See features-overview for the full key list.

## Grep hazards

1. **`publish(channel, message)` - STANDARD ORDER.** Ruby GLIDE matches redis-rb convention. Does NOT reverse args (unlike Python / Node / Java GLIDE which reverse).
2. **`spublish(channel, message)` - STANDARD ORDER.** Same convention. Sharded publish is implemented.
3. **`subscribe(*channels)` - VARARGS, not array.** `redis.subscribe("ch1", "ch2")`. Passing an array `subscribe(["ch1"])` treats the array as the first channel, not as a list.
4. **No `on.message` block form.** redis-rb's `redis.subscribe("ch") { |on| on.message { } }` does NOT work. The subscribe call returns once the server ACKs the subscription; messages arrive through the FFI callback.
5. **Message delivery: override `pubsub_callback` module method.** The default `Valkey::PubSubCallback#pubsub_callback(_client_ptr, kind, msg_ptr, msg_len, chan_ptr, chan_len, pat_ptr, pat_len)` prints messages. To handle messages, re-open `Valkey` and override it before creating the client.
6. **`statistics` (NOT `get_statistics`).** Returns a flat hash of connection and compression counters. No `connection_stats` nested hash, no `command_stats`.
7. **OpenTelemetry: `Valkey::OpenTelemetry.init(traces:, metrics:, flush_interval_ms:)`.** NOT `Valkey.new(tracing: true)` - that option is ignored. Configure OTel once per process; second init is a warning no-op.
8. **MULTI/EXEC/DISCARD in a `pipelined` block falls back to sequential.** The gem code has a `WORKAROUND: The underlying Glide FFI backend has stability issues when batching transactional commands` - transactional ops are issued one-by-one inside a `pipelined` block. Plain `multi { }` (outside pipelined) works normally.
9. **Single `Valkey` class, not `Valkey::Client` + `Valkey::Cluster`.** Cluster mode via `Valkey.new(nodes: [...], cluster_mode: true)` option.
10. **Error hierarchy is NESTED under `Valkey::BaseError < StandardError`.** `CommandError`, `BaseConnectionError` are intermediate nodes with concrete leaves below them. Rescuing `Valkey::BaseError` catches everything; rescuing `StandardError` catches these plus unrelated Ruby errors.
11. **`ssl:` scheme in `url:` is `rediss://`.** GLIDE uses that URL to determine TLS.
12. **`reconnect_delay` / `reconnect_delay_max` interact to derive `exponent_base`** internally. They are not independent caps. The gem computes `exponent_base` from `(max_delay / base_delay) ** (1 / retries)`.
13. **Ruby minimum is 2.6.0**, declared in the gemspec. Older 2.5 and below will not install.
14. **Pre-built FFI shim bundled:** `libglide_ffi.so` (Linux) and `libglide_ffi.dylib` (macOS) in the gem. No Windows binary.
15. **`disconnect!` is an alias for `close`.** Both work; redis-rb used `disconnect!` so keep the alias when migrating.

## Cross-references

- `valkey` skill - Valkey server commands and app patterns
- `glide-dev` skill - GLIDE core internals and FFI binding mechanics
