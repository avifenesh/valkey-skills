---
name: valkey-glide-go
description: "Use when building Go applications with Valkey GLIDE. Covers synchronous API, Client/ClusterClient, CGO bridge, Result[T] types, error handling, batching, streams, TLS, authentication, OpenTelemetry, Lua scripting."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Go Client

Synchronous Go client for Valkey built on the GLIDE Rust core via CGO bridge.

## Routing

| Question | Reference |
|----------|-----------|
| Install, setup, client creation, TLS, auth, reconnect | [connection](reference/features/connection.md) |
| PubSub, subscribe, publish, sharded channels | [pubsub](reference/features/pubsub.md) |
| Batching, transactions, pipelines | [batching](reference/features/batching.md) |
| Streams, consumer groups, XADD, XREAD | [streams](reference/features/streams.md) |
| OTel, Lua scripting, Functions API, request routing, scan, custom commands, server mgmt | [advanced](reference/features/advanced.md) |
| Error types, retry, reconnection patterns | [error-handling](reference/best-practices/error-handling.md) |
| Benchmarks, throughput, batching perf | [performance](reference/best-practices/performance.md) |
| Timeouts, connection management, cloud defaults | [production](reference/best-practices/production.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
