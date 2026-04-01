---
name: valkey-glide-ruby
description: "Use when building Ruby apps with Valkey GLIDE - valkey-rb gem (GA), redis-rb drop-in replacement, FFI bridge, PubSub, pipelining, OpenTelemetry, TLS. Not for other languages - see valkey-glide router."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Ruby Client

Synchronous Ruby client for Valkey built on the GLIDE Rust core via FFI. Drop-in replacement for redis-rb.

**Repository:** [valkey-io/valkey-glide-ruby](https://github.com/valkey-io/valkey-glide-ruby)

**Status:** GA. valkey-rb 1.0.0 published on RubyGems.

## Routing

| Question | Reference |
|----------|-----------|
| Setup, client creation, TLS, auth, config, redis-rb migration, reconnection | [connection](reference/features-connection.md) |
| PubSub, subscribe, publish, sharded channels, introspection | [pubsub](reference/features-pubsub.md) |
| Install, API status, platform support, command groups, pipelining, OpenTelemetry, limitations | [overview](reference/features-overview.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
