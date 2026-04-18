---
name: valkey
description: "Use when building apps with Valkey - caching, sessions, queues, locks, rate-limiting, leaderboards, counters, pub-sub, streams, scripting. Covers IFEQ/DELIFEQ, hash field TTL, COMMANDLOG. Not for server internals (valkey-dev) or ops (valkey-ops)."
version: 2.1.1
argument-hint: "[feature, pattern, or scenario]"
---

# Valkey Application Developer Reference

## Routing

- Conditional update, compare-and-swap, optimistic locking, CAS, WATCH/MULTI/EXEC replacement, lock release race, safe delete, atomic delete-if-equal, replace Lua script -> Conditional Ops (IFEQ/DELIFEQ)
- Per-field TTL, hash field expiration, session tokens, feature flags, EXPIRETIME/PEXPIRETIME/PERSIST, TTL audit -> Hash Field TTL
- Slow commands, large requests/replies, monitoring, debugging -> COMMANDLOG
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
- Memory fragmentation, mem_fragmentation_ratio, active defrag, jemalloc, MEMORY USAGE, MEMORY DOCTOR -> Advanced (defrag)
- Replication internals, PSYNC, partial resync, full resync, backlog sizing, diskless replication, dual-channel, replica priority, min-replicas-to-write -> Advanced (replication)
- Latency diagnosis, high p99, LATENCY LATEST, LATENCY DOCTOR, latency-monitor-threshold, slow commands, fork pauses, THP, event loop -> Advanced (latency)
- Auth, ACLs, TLS, network security -> Security
- Common mistakes, KEYS in production, missing TTL, unbounded collections -> Anti-Patterns
- Redis compatibility, migration, fork history -> Overview
- Data types, strings, hashes, lists, sets, sorted sets, streams, bitmaps, geo, HyperLogLog -> Basics (data-types)
- Transactions, MULTI/EXEC, Lua scripting, EVAL, FCALL, INFO, SCAN, CONFIG -> Basics (server-and-scripting)
- EVAL vs FCALL, EVALSHA, FUNCTION LOAD, Lua script replication, determinism, EVAL_RO, FCALL_RO, busy-script-time, lua-time-limit, script timeout, SCRIPT KILL, sliding window rate limiter, CAS Lua -> Advanced (lua-functions)
- CLIENT TRACKING, RESP3 push invalidation, RESP2 redirect, BCAST mode, OPTIN, OPTOUT, tracking-table-max-keys, __redis__:invalidate, GLIDE cache, redis-py tracking, ioredis tracking, invalidation consistency -> Advanced (client-side-caching)


## Valkey-Specific Features

| Topic | Reference |
|-------|-----------|
| SET IFEQ (8.1+), DELIFEQ (9.0+) - atomic compare-and-swap, safe lock release without Lua | [conditional-ops](reference/valkey-features-conditional-ops.md) |
| HSETEX, HGETEX, HEXPIRE, HPERSIST (9.0+) per-field TTL on hashes; also TTL/PTTL/EXPIRETIME/PEXPIRETIME/PERSIST key-level inspection | [hash-field-ttl](reference/valkey-features-hash-field-ttl.md) |
| COMMANDLOG GET/LEN/RESET (8.1+) - unified slow/large-request/large-reply logging, replaces SLOWLOG | [commandlog](reference/valkey-features-commandlog.md) |
| GEOSEARCH BYPOLYGON (9.0+) - arbitrary polygon region matching | [geospatial](reference/valkey-features-geospatial.md) |
| Numbered databases in cluster mode, atomic slot migration | [cluster-enhancements](reference/valkey-features-cluster-enhancements.md) |
| I/O threading, SIMD acceleration, prefetch, zero-copy, dual-channel replication | [performance-summary](reference/valkey-features-performance-summary.md) |


## Overview

| Topic | Reference |
|-------|-----------|
| Valkey versions, license, governance, Redis fork history, Valkey vs Redis comparison | [what-is-valkey](reference/overview-what-is-valkey.md) |
| Redis compatibility, migration strategies, what changed | [compatibility](reference/overview-compatibility.md) |


## Application Patterns

| Topic | Reference |
|-------|-----------|
| Cache-aside, write-through, write-behind, client-side caching, stampede prevention, invalidation, TTL patterns, eviction policies | [caching-strategies](reference/patterns-caching-strategies.md) |
| Session hashes, sliding TTL, session rotation, basic session store | [sessions-basics](reference/patterns-sessions-basics.md) |
| Per-field TTL sessions (Valkey 9.0+), session counting, concurrent session limits | [sessions-field-expiry](reference/patterns-sessions-field-expiry.md) |
| SET NX with TTL, safe release (DELIFEQ), Redlock algorithm, fencing tokens, lock renewal | [locks](reference/patterns-locks.md) |
| Fixed window, sliding window counter, sliding window log, token bucket, per-field rate limiting (Valkey 9.0+), algorithm comparison | [rate-limiting-advanced](reference/patterns-rate-limiting-advanced.md) |
| Simple FIFO queues (LPUSH/BRPOP), reliable queues (LMOVE), stream-based queues (XREADGROUP), consumer groups, dead letter, priority queues, queue pattern comparison | [queues-streams](reference/patterns-queues-streams.md) |
| Sorted set rankings, pagination, top-N, score updates, composite scoring, time-bucketed | [leaderboards](reference/patterns-leaderboards.md) |
| Pub/Sub patterns, sharded pub/sub, fan-out, notification systems, keyspace notifications, pub/sub vs streams comparison | [pubsub-patterns](reference/patterns-pubsub-patterns.md) |
| Prefix autocomplete, tag filtering, inverted indexes, scored search results | [search-autocomplete](reference/patterns-search-autocomplete.md) |
| Atomic counters, sharded counters, idempotency keys | [counters-atomic](reference/patterns-counters-atomic.md) |
| HyperLogLog, BITFIELD packed counters, deduplication strategies | [counters-approximate](reference/patterns-counters-approximate.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Key naming, namespaces, hot key and big key avoidance, key expiration strategies, key analysis commands | [keys](reference/best-practices-keys.md) |
| Memory reduction, encoding thresholds, TTL strategies, eviction | [memory](reference/best-practices-memory.md) |
| UNLINK vs DEL, SCAN vs KEYS, data-type iteration, pipelining, connection pooling, I/O threading, performance anti-patterns | [performance-throughput](reference/best-practices-performance-throughput.md) |
| RDB, AOF, hybrid persistence, latency impact, durability decisions | [persistence](reference/best-practices-persistence.md) |
| Hash tags, cross-slot errors, CROSSSLOT fixes | [cluster-hash-tags](reference/best-practices-cluster-hash-tags.md) |
| MOVED/ASK redirects, replica reads, pipelining in cluster | [cluster-operations](reference/best-practices-cluster-operations.md) |
| Sentinel, failover, retries, WAIT/WAITAOF, replication lag, Sentinel vs Cluster decision | [high-availability](reference/best-practices-high-availability.md) |


## Advanced Topics

| Topic | Reference |
|-------|-----------|
| Memory fragmentation, `mem_fragmentation_ratio`, active defrag config, `MEMORY USAGE`, `MEMORY DOCTOR`, Valkey 8.1 hashtable impact | [defrag](reference/advanced-memory-defrag.md) |
| Replication internals (PSYNC2), partial vs full resync triggers, backlog sizing, diskless sync, dual-channel replication (8.0+), replica chains, `min-replicas-to-write` | [replication-internals](reference/advanced-replication-internals.md) |
| End-to-end latency diagnosis, `LATENCY LATEST/HISTORY/DOCTOR`, COMMANDLOG correlation, fork pauses, THP, expiration storms, I/O thread impact, p99 playbook | [latency-diagnosis](reference/advanced-latency-diagnosis.md) |
| EVAL vs FCALL, EVALSHA, FUNCTION LOAD, script replication (effects vs commands), determinism, EVAL_RO/FCALL_RO for replica reads, `busy-script-time`, SCRIPT KILL, memory limits, SET IFEQ/DELIFEQ as Lua replacements, sliding window rate limiter | [lua-functions](reference/advanced-lua-functions.md) |
| CLIENT TRACKING protocol (RESP3 push, RESP2 redirect), default/BCAST/OPTIN/OPTOUT modes, `tracking-table-max-keys` eviction, GLIDE CacheConfig, redis-py/ioredis manual wiring, consistency guarantees, connection management, what to track vs skip | [client-side-caching](reference/advanced-client-side-caching.md) |


## Security

| Topic | Reference |
|-------|-----------|
| ACL users, key pattern restrictions, TLS encryption, security checklist | [auth-and-acl](reference/security-auth-and-acl.md) |


## Anti-Patterns

| Topic | Reference |
|-------|-----------|
| KEYS in production, DEL on big keys, missing maxmemory, hot keys, unbounded collections, severity guide, detection commands | [quick-reference](reference/anti-patterns-quick-reference.md) |


## Basics

| Topic | Reference |
|-------|-----------|
| Strings, Hashes, Lists, Sets, Sorted Sets, Streams, Pub/Sub, HyperLogLog, Bitmaps, Geo | [data-types](reference/basics-data-types.md) |
| Transactions (MULTI/EXEC), Lua scripting (EVAL/FCALL), Server commands (INFO/SCAN/CONFIG), client management, monitoring | [server-and-scripting](reference/basics-server-and-scripting.md) |
