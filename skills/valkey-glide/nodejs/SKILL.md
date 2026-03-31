---
name: valkey-glide-nodejs
description: "Use when building Node.js or TypeScript applications with Valkey GLIDE. Covers Promise API, GlideClient, TypeScript types, ESM/CJS, TLS, authentication, OpenTelemetry, batching, PubSub, streams, Lua scripting, Valkey functions."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Node.js Client

Self-contained guide for building Node.js and TypeScript applications with Valkey GLIDE.

## Routing

| Question | Reference |
|----------|-----------|
| Install, setup, client creation, TLS, auth, reconnect | [connection](reference/features/connection.md) |
| PubSub, subscribe, publish, sharded channels | [pubsub](reference/features/pubsub.md) |
| Batching, transactions, pipelines | [batching](reference/features/batching.md) |
| Streams, consumer groups, XADD, XREAD | [streams](reference/features/streams.md) |
| TLS details, auth (password/IAM), Lua scripting, Valkey functions, error types, decoder, protocol version | [advanced](reference/features/advanced.md) |
| Error types, retry, reconnection patterns | [error-handling](reference/best-practices/error-handling.md) |
| Benchmarks, throughput, batching perf | [performance](reference/best-practices/performance.md) |
| Timeouts, connection management, AZ affinity, OTel, cloud defaults | [production](reference/best-practices/production.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
