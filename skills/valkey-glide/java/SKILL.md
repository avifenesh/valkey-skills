---
name: valkey-glide-java
description: "Java Valkey GLIDE client - CompletableFuture API, GlideClient, GlideClusterClient, Batch/ClusterBatch, TLS, OpenTelemetry, streams, Lua scripting, Valkey functions. Not for Jedis/Lettuce migration - use migrate-jedis or migrate-lettuce skill."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Java Client

## Routing

| Question | Reference |
|----------|-----------|
| Install, setup, client creation, TLS, auth, reconnect | [connection](reference/features/connection.md) |
| PubSub, subscribe, publish, sharded channels | [pubsub](reference/features/pubsub.md) |
| Batching, transactions, pipelines | [batching](reference/features/batching.md) |
| Streams, consumer groups, XADD, XREAD | [streams](reference/features/streams.md) |
| TLS details, auth (password/IAM), Lua scripting, Valkey functions, error types, CompletableFuture, custom commands, OTel | [advanced](reference/features/advanced.md) |
| Error types, retry, reconnection patterns | [error-handling](reference/best-practices/error-handling.md) |
| Benchmarks, throughput, batching perf | [performance](reference/best-practices/performance.md) |
| Timeouts, connection management, AZ affinity, OTel setup, cloud defaults | [production](reference/best-practices/production.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
