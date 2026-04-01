---
name: valkey
description: "Build applications with Valkey - choose commands, data types, and patterns. Use when implementing caching, sessions, queues, locks, rate-limiting, leaderboards, counters, search, pub-sub, streams, scripting, transactions, or migrating from Redis. Covers Valkey-specific features: SET IFEQ, DELIFEQ, hash field TTL, COMMANDLOG, polygon geo queries, cluster enhancements. Not for server internals (valkey-dev) or ops (valkey-ops)."
version: 2.0.0
argument-hint: "[feature, pattern, or scenario]"
---

# Valkey Application Developer Reference

## Routing

- Conditional update, compare-and-swap, optimistic locking, CAS, WATCH/MULTI/EXEC replacement, lock release race, safe delete, atomic delete-if-equal, replace Lua script -> Conditional Ops (IFEQ/DELIFEQ)
- Per-field TTL, hash field expiration, session tokens, feature flags -> Hash Field TTL
- Slow commands, large requests/replies, monitoring, debugging -> COMMANDLOG
- Key expiration inspection, absolute timestamps, TTL audit, PERSIST -> EXPIRETIME
- Polygon queries, geofencing, region matching -> Geospatial
- Cluster numbered databases, atomic slot migration -> Cluster Enhancements
- I/O threading, SIMD, zero-copy, dual-channel replication -> Performance Internals
- Caching, write-through, write-behind, stampede, client-side caching -> Patterns (caching)
- Sessions, sliding TTL, multi-device, session store -> Patterns (sessions)
- Distributed locks, Redlock, safe release -> Patterns (locks)
- Rate limiting, throttling, token bucket, sliding window -> Patterns (rate-limiting)
- Queues, streams, XADD, XREAD, consumer groups, dead letter, FIFO -> Patterns (queues)
- Leaderboards, rankings, sorted set, top-N, pagination -> Patterns (leaderboards)
- Pub/Sub, publish, subscribe, notifications, fan-out, sharded pub/sub -> Patterns (pubsub-patterns)
- Search, autocomplete, prefix, inverted index, tag filtering -> Patterns (search-autocomplete)
- Counters, atomic increment, HyperLogLog, idempotency, sharded counters -> Patterns (counters)
- Key naming, memory, performance, persistence, cluster, HA -> Best Practices
- Auth, ACLs, TLS, network security -> Security
- Common mistakes, KEYS in production, missing TTL, unbounded collections -> Anti-Patterns
- Redis compatibility, migration, fork history -> Overview
- Data types, strings, hashes, lists, sets, sorted sets, streams, bitmaps, geo, HyperLogLog -> Basics (data-types)
- Transactions, MULTI/EXEC, Lua scripting, EVAL, FCALL, INFO, SCAN, CONFIG -> Basics (server-and-scripting)


## Valkey-Specific Features

| Topic | Reference |
|-------|-----------|
| SET IFEQ (8.1+), DELIFEQ (9.0+) - atomic compare-and-swap, safe lock release without Lua | [conditional-ops](reference/valkey-features/conditional-ops.md) |
| HSETEX, HGETEX, HGETDEL, HEXPIRE, HPERSIST (9.0+) - per-field TTL on hashes | [hash-field-ttl](reference/valkey-features/hash-field-ttl.md) |
| COMMANDLOG GET/LEN/RESET (8.1+) - unified slow/large-request/large-reply logging, replaces SLOWLOG | [commandlog](reference/valkey-features/commandlog.md) |
| EXPIRETIME, PEXPIRETIME, PERSIST - absolute expiration timestamps, TTL inspection and removal | [expiretime](reference/valkey-features/expiretime.md) |
| GEOSEARCH BYPOLYGON (9.0+) - arbitrary polygon region matching | [geospatial](reference/valkey-features/geospatial.md) |
| Numbered databases in cluster mode, atomic slot migration | [cluster-enhancements](reference/valkey-features/cluster-enhancements.md) |
| I/O threading, SIMD acceleration, prefetch, zero-copy, dual-channel replication | [performance-summary](reference/valkey-features/performance-summary.md) |


## Overview

| Topic | Reference |
|-------|-----------|
| Valkey versions, license, governance, Redis fork history | [what-is-valkey](reference/overview/what-is-valkey.md) |
| Redis compatibility, migration strategies, what changed | [compatibility](reference/overview/compatibility.md) |


## Application Patterns

| Topic | Reference |
|-------|-----------|
| Cache-aside, write-through, write-behind, client-side caching, stampede prevention | [caching](reference/patterns/caching.md) |
| Session hashes, sliding TTL, per-field expiration (HSETEX), multi-device | [sessions](reference/patterns/sessions.md) |
| SET NX with TTL, safe release (DELIFEQ), Redlock algorithm | [locks](reference/patterns/locks.md) |
| Fixed window, sliding window, token bucket, API throttling | [rate-limiting](reference/patterns/rate-limiting.md) |
| FIFO with lists, reliable queues with streams, consumer groups, dead letter | [queues](reference/patterns/queues.md) |
| Sorted set rankings, pagination, top-N, score updates | [leaderboards](reference/patterns/leaderboards.md) |
| Pub/Sub patterns, sharded pub/sub, fan-out, notification systems | [pubsub-patterns](reference/patterns/pubsub-patterns.md) |
| Prefix autocomplete, tag filtering, inverted indexes, faceted search | [search-autocomplete](reference/patterns/search-autocomplete.md) |
| Atomic counters, sharded counters, idempotency, HyperLogLog | [counters](reference/patterns/counters.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Key naming, namespaces, hash tags for cluster co-location | [keys](reference/best-practices/keys.md) |
| Memory reduction, encoding thresholds, TTL strategies, eviction | [memory](reference/best-practices/memory.md) |
| UNLINK vs DEL, SCAN vs KEYS, pipelining, connection pooling, batching | [performance](reference/best-practices/performance.md) |
| RDB, AOF, hybrid persistence, backup strategy | [persistence](reference/best-practices/persistence.md) |
| Hash tags, cross-slot errors, MOVED/ASK, replica reads, CLUSTERSCAN | [cluster](reference/best-practices/cluster.md) |
| Sentinel, failover, retries, WAIT/WAITAOF, replication lag | [high-availability](reference/best-practices/high-availability.md) |


## Security

| Topic | Reference |
|-------|-----------|
| ACL users, key pattern restrictions, TLS encryption, protected mode | [auth-and-acl](reference/security/auth-and-acl.md) |


## Anti-Patterns

| Topic | Reference |
|-------|-----------|
| KEYS in production, DEL on big keys, missing maxmemory, hot keys, unbounded collections | [quick-reference](reference/anti-patterns/quick-reference.md) |


## Basics

| Topic | Reference |
|-------|-----------|
| Strings, Hashes, Lists, Sets, Sorted Sets, Streams, Pub/Sub, HyperLogLog, Bitmaps, Geo | [data-types](reference/basics/data-types.md) |
| Transactions (MULTI/EXEC), Lua scripting (EVAL/FCALL), Server commands (INFO/SCAN/CONFIG) | [server-and-scripting](reference/basics/server-and-scripting.md) |
