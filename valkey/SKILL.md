---
name: valkey
description: "Use when building applications with Valkey, choosing commands and data types, implementing caching/queuing/locking/rate-limiting patterns, optimizing performance, or migrating from Redis."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey Application Developer Reference

31 reference docs covering commands, patterns, best practices, and Valkey-specific features for application developers.

Browse by topic below. Each link leads to a focused reference doc with syntax, code examples, and practical guidance.

## Routing

- Data type selection -> Overview, Commands
- Caching, sessions, queues -> Patterns
- Performance, memory, keys -> Best Practices
- Conditional ops, hash field TTL -> Valkey-Specific Features
- Client library choice -> Clients
- Auth, ACLs, TLS -> Security
- Redis migration -> Overview (compatibility)
- What NOT to do -> Anti-Patterns


## Overview

| Topic | Reference |
|-------|-----------|
| What Valkey is, versions, license, governance | [what-is-valkey](reference/overview/what-is-valkey.md) |
| Redis compatibility, migration strategies, what changes | [compatibility](reference/overview/compatibility.md) |


## Commands - Strings

| Topic | Reference |
|-------|-----------|
| SET/GET, MSET/MGET, INCR, SETNX, SET IFEQ | [strings](reference/commands/strings.md) |


## Commands - Hashes

| Topic | Reference |
|-------|-----------|
| HSET, HGET, HMGET, HGETALL, HDEL, HEXPIRE, HSETEX, HGETEX, HGETDEL | [hashes](reference/commands/hashes.md) |


## Commands - Lists

| Topic | Reference |
|-------|-----------|
| LPUSH, RPUSH, LPOP, RPOP, LRANGE, BLPOP, LPOS | [lists](reference/commands/lists.md) |


## Commands - Sets

| Topic | Reference |
|-------|-----------|
| SADD, SISMEMBER, SMEMBERS, SINTER, SUNION, SCARD | [sets](reference/commands/sets.md) |


## Commands - Sorted Sets

| Topic | Reference |
|-------|-----------|
| ZADD, ZRANGE, ZREVRANGE, ZRANK, ZINCRBY, ZSCORE, ZPOPMIN/MAX | [sorted-sets](reference/commands/sorted-sets.md) |


## Commands - Streams

| Topic | Reference |
|-------|-----------|
| XADD, XREAD, XRANGE, XGROUP, XREADGROUP, XACK, XTRIM | [streams](reference/commands/streams.md) |


## Commands - Pub/Sub

| Topic | Reference |
|-------|-----------|
| SUBSCRIBE, PUBLISH, PSUBSCRIBE, SSUBSCRIBE, SPUBLISH | [pubsub](reference/commands/pubsub.md) |


## Commands - Scripting and Functions

| Topic | Reference |
|-------|-----------|
| EVAL, EVALSHA, FUNCTION LOAD, FCALL | [scripting](reference/commands/scripting.md) |


## Commands - Transactions

| Topic | Reference |
|-------|-----------|
| MULTI, EXEC, DISCARD, WATCH | [transactions](reference/commands/transactions.md) |


## Commands - Specialized Types

| Topic | Reference |
|-------|-----------|
| HyperLogLog, Bitmaps, Geospatial, JSON, Bloom Filters | [specialized](reference/commands/specialized.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Key naming, namespaces, hash tags, cluster co-location | [keys](reference/best-practices/keys.md) |
| Encoding thresholds, hash bucketing, TTL strategies, eviction | [memory](reference/best-practices/memory.md) |
| UNLINK vs DEL, SCAN vs KEYS, pipelining, connection pooling | [performance](reference/best-practices/performance.md) |
| RDB, AOF, hybrid mode, persistence strategy selection | [persistence](reference/best-practices/persistence.md) |


## Common Patterns

| Topic | Reference |
|-------|-----------|
| Cache-aside, write-through, client-side caching, stampede prevention | [caching](reference/patterns/caching.md) |
| Session hashes, sliding TTL, per-field expiration, rotation | [sessions](reference/patterns/sessions.md) |
| Distributed locks, SET NX, DELIFEQ, Redlock | [locks](reference/patterns/locks.md) |
| Fixed window, sliding window, token bucket rate limiting | [rate-limiting](reference/patterns/rate-limiting.md) |
| FIFO lists, reliable streams, consumer groups, dead letters | [queues](reference/patterns/queues.md) |
| Sorted set leaderboards, rankings, pagination | [leaderboards](reference/patterns/leaderboards.md) |
| Pub/Sub patterns, sharded pub/sub, fan-out | [pubsub-patterns](reference/patterns/pubsub-patterns.md) |


## Valkey-Specific Features

| Topic | Reference |
|-------|-----------|
| SET IFEQ (conditional update), DELIFEQ (conditional delete) | [conditional-ops](reference/valkey-features/conditional-ops.md) |
| Per-field TTL on hashes, HSETEX, HGETEX, HEXPIRE | [hash-field-ttl](reference/valkey-features/hash-field-ttl.md) |
| Numbered databases in cluster, atomic slot migration | [cluster-enhancements](reference/valkey-features/cluster-enhancements.md) |
| Polygon geospatial queries (GEOSEARCH BYPOLYGON) | [geospatial](reference/valkey-features/geospatial.md) |
| I/O threading, SIMD, prefetch, zero-copy performance gains | [performance-summary](reference/valkey-features/performance-summary.md) |


## Client Libraries

| Topic | Reference |
|-------|-----------|
| Valkey GLIDE, ioredis, redis-py, Jedis, go-redis, when to choose | [overview](reference/clients/overview.md) |


## Security

| Topic | Reference |
|-------|-----------|
| Authentication, ACL users, key patterns, TLS, network hardening | [auth-and-acl](reference/security/auth-and-acl.md) |


## Anti-Patterns

| Topic | Reference |
|-------|-----------|
| KEYS in production, DEL on big keys, no maxmemory, hot keys | [quick-reference](reference/anti-patterns/quick-reference.md) |
