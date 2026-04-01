---
name: valkey-glide-csharp
description: "C#/.NET Valkey GLIDE client - async/await API, .NET 8.0+ (preview), GlideClient, configuration builders, TLS, PubSub, ConnectionMultiplexer compat. Not for StackExchange.Redis migration - use migrate-stackexchange skill."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE C# Client

Async/await C# client for Valkey built on the GLIDE Rust core via native interop. Currently in preview.

**Separate repository:** [valkey-io/valkey-glide-csharp](https://github.com/valkey-io/valkey-glide-csharp)

## Routing

| Question | Reference |
|----------|-----------|
| Setup, client creation, TLS, auth, config builders, read strategy | [connection](reference/features-connection.md) |
| PubSub, subscribe, publish, sharded channels | [pubsub](reference/features-pubsub.md) |
| Install, API status, platform support, command groups, limitations | [overview](reference/features-overview.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
