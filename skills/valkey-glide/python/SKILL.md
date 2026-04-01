---
name: valkey-glide-python
description: "Use when building Python apps with Valkey GLIDE - async/sync APIs, GlideClient, GlideClusterClient, asyncio, TLS, OpenTelemetry, batching, PubSub, streams, Lua scripting. Not for redis-py migration - use migrate-redis-py skill."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE Python Client

## Routing

| Question | Reference |
|----------|-----------|
| Install, setup, client creation, TLS, auth, reconnect | [connection](reference/features-connection.md) |
| PubSub, subscribe, publish, sharded channels | [pubsub](reference/features-pubsub.md) |
| Batching, transactions, pipelines | [batching](reference/features-batching.md) |
| Streams, consumer groups, XADD, XREAD | [streams](reference/features-streams.md) |
| OTel, Lua scripting, cluster SCAN, command routing, logging, custom commands | [advanced](reference/features-advanced.md) |
| Error types, retry, reconnection patterns | [error-handling](reference/best-practices-error-handling.md) |
| Benchmarks, throughput, batching perf | [performance](reference/best-practices-performance.md) |
| Timeouts, connection management, cloud defaults | [production](reference/best-practices-production.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
