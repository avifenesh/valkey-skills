---
name: valkey
description: "Use when building applications with Valkey, choosing commands and data types, implementing caching/sessions/queuing/locking/rate-limiting/leaderboard/counter/search patterns, using streams/pub-sub/scripting/transactions, optimizing performance and memory, configuring cluster/HA/persistence, securing with ACLs/TLS, selecting client libraries, using modules (Bloom/JSON/Search), leveraging Valkey-specific features (conditional ops, hash field TTL, geospatial), or migrating from Redis."
version: 1.0.0
argument-hint: "[command, pattern, or data type]"
---

# Valkey Application Developer Reference

37 reference docs covering commands, patterns, best practices, and Valkey-specific features for application developers.

Browse by topic below. Each link leads to a focused reference doc with syntax, code examples, and practical guidance.

## Routing

- Which data type, data modeling, choosing between hash/list/set/sorted set -> Commands (by type), Memory best practices
- Caching, sessions, queues, rate limiting, locks, search, counters, leaderboards -> Patterns
- Performance, pipelining, connection pooling, batch operations, memory, keys, cluster, HA -> Best Practices
- TTL, expiration, key eviction -> Strings (EX/PX), Hashes (HEXPIRE), Memory (eviction), Hash Field TTL
- INFO, SCAN, CLIENT, MEMORY, server introspection -> Commands - Server
- Bloom filters, JSON documents, full-text search modules -> Commands - Modules
- Conditional ops (SET IFEQ, DELIFEQ), hash field TTL (HSETEX/HGETEX) -> Valkey-Specific Features
- Client library choice, GLIDE vs ioredis vs redis-py -> Clients
- Auth, ACLs, TLS, network security -> Security
- Redis migration, Redis compatibility, switching from Redis -> Overview (compatibility)
- What NOT to do, common mistakes, KEYS in production -> Anti-Patterns
- Pub/Sub, real-time messaging, fan-out -> Commands - Pub/Sub, Patterns - pubsub-patterns
- Job queues, task processing, message broker -> Patterns - queues, Commands - Streams
- Event sourcing, activity feeds, append-only log -> Commands - Streams
- Autocomplete, tag search, inverted index -> Patterns - search-autocomplete
- Leaderboards, rankings, top-N -> Patterns - leaderboards
- Unique counting, deduplication, idempotency -> Patterns - counters
- Distributed locks, mutex, Redlock -> Patterns - locks
- Lua scripting, server-side functions -> Commands - Scripting
- Transactions, atomic multi-command -> Commands - Transactions
- I/O threading, SIMD, zero-copy, Valkey performance internals -> Valkey-Specific Features - performance-summary


## Overview

| Topic | Reference |
|-------|-----------|
| What Valkey is, versions, license, governance | [what-is-valkey](reference/overview/what-is-valkey.md) |
| Redis compatibility, migration strategies, what changes | [compatibility](reference/overview/compatibility.md) |


## Commands - Strings

| Topic | Reference |
|-------|-----------|
| Simple values, counters, cached objects, flags, TTL/expiration; SET/GET, MSET/MGET, INCR/DECR, SETNX, SET EX/PX, SET IFEQ, APPEND, GETRANGE | [strings](reference/commands/strings.md) |


## Commands - Hashes

| Topic | Reference |
|-------|-----------|
| Objects with named fields, user profiles, session data, config maps; HSET, HGET, HMGET, HGETALL, HDEL, HEXPIRE, HSETEX, HGETEX, HGETDEL, HINCRBY | [hashes](reference/commands/hashes.md) |


## Commands - Lists

| Topic | Reference |
|-------|-----------|
| Ordered sequences, simple queues, recent items, stacks; LPUSH, RPUSH, LPOP, RPOP, LRANGE, BLPOP, BRPOP, LPOS, LLEN, LMOVE | [lists](reference/commands/lists.md) |


## Commands - Sets

| Topic | Reference |
|-------|-----------|
| Unique collections, membership testing, intersection/union, tagging; SADD, SISMEMBER, SMEMBERS, SINTER, SUNION, SDIFF, SCARD, SRANDMEMBER | [sets](reference/commands/sets.md) |


## Commands - Sorted Sets

| Topic | Reference |
|-------|-----------|
| Ranked collections, leaderboards, priority queues, range queries, rate limiting; ZADD, ZRANGE, ZREVRANGE, ZRANK, ZINCRBY, ZSCORE, ZPOPMIN/MAX, ZRANGEBYSCORE, ZRANGEBYLEX, ZREM | [sorted-sets](reference/commands/sorted-sets.md) |


## Commands - Streams

| Topic | Reference |
|-------|-----------|
| Append-only log, event sourcing, reliable messaging, consumer groups, activity feeds; XADD, XREAD, XRANGE, XGROUP, XREADGROUP, XACK, XTRIM, XLEN, XPENDING | [streams](reference/commands/streams.md) |


## Commands - Pub/Sub

| Topic | Reference |
|-------|-----------|
| Real-time messaging, broadcast, fan-out, pattern subscriptions, sharded channels; SUBSCRIBE, PUBLISH, PSUBSCRIBE, SSUBSCRIBE, SPUBLISH, UNSUBSCRIBE | [pubsub](reference/commands/pubsub.md) |


## Commands - Scripting and Functions

| Topic | Reference |
|-------|-----------|
| Server-side Lua scripts, stored functions, atomic multi-step operations; EVAL, EVALSHA, FUNCTION LOAD, FCALL, SCRIPT EXISTS | [scripting](reference/commands/scripting.md) |


## Commands - Transactions

| Topic | Reference |
|-------|-----------|
| Atomic command batches, optimistic locking, conditional execution; MULTI, EXEC, DISCARD, WATCH | [transactions](reference/commands/transactions.md) |


## Commands - Specialized Types

| Topic | Reference |
|-------|-----------|
| Approximate unique counting (HyperLogLog), bit-level operations (Bitmaps), location-based queries (Geospatial/GEO) | [specialized](reference/commands/specialized.md) |


## Commands - Server

| Topic | Reference |
|-------|-----------|
| Server introspection, memory analysis, key scanning, client management; INFO, MEMORY USAGE, OBJECT, CLIENT, CONFIG GET, SCAN, WAIT, COPY, DBSIZE | [server](reference/commands/server.md) |


## Commands - Modules

| Topic | Reference |
|-------|-----------|
| Probabilistic membership testing (BF.*), document storage (JSON.*), full-text search and indexing (FT.*) | [modules](reference/commands/modules.md) |


## Best Practices

| Topic | Reference |
|-------|-----------|
| Key naming conventions, namespaces, separators, hash tags for cluster co-location | [keys](reference/best-practices/keys.md) |
| Reducing memory usage, encoding thresholds, hash bucketing, TTL strategies, eviction policies, maxmemory | [memory](reference/best-practices/memory.md) |
| Throughput optimization, UNLINK vs DEL, SCAN vs KEYS, pipelining, connection pooling, batch operations, latency reduction | [performance](reference/best-practices/performance.md) |
| Durability, RDB snapshots, AOF append-only file, hybrid persistence, backup strategy | [persistence](reference/best-practices/persistence.md) |
| Cluster mode, hash tags, cross-slot errors, MOVED/ASK redirects, replica reads, slot migration, CLUSTERSCAN | [cluster](reference/best-practices/cluster.md) |
| High availability, Sentinel, failover behavior, retries, reconnection, WAIT/WAITAOF, replication lag | [high-availability](reference/best-practices/high-availability.md) |


## Common Patterns

| Topic | Reference |
|-------|-----------|
| Caching strategies: cache-aside (lazy loading), write-through, write-behind, client-side caching, stampede/thundering herd prevention, cache invalidation | [caching](reference/patterns/caching.md) |
| Session storage: session hashes, sliding TTL, per-field expiration, session rotation, multi-device sessions | [sessions](reference/patterns/sessions.md) |
| Distributed locking: mutual exclusion, SET NX, lock with TTL, safe release (DELIFEQ), Redlock algorithm, lock extension | [locks](reference/patterns/locks.md) |
| Rate limiting: fixed window counter, sliding window log, sliding window counter, token bucket, API throttling | [rate-limiting](reference/patterns/rate-limiting.md) |
| Job/task queues: FIFO with lists, reliable queues with streams, consumer groups, dead letter queues, delayed jobs, message broker | [queues](reference/patterns/queues.md) |
| Leaderboards and rankings: sorted set leaderboards, real-time rankings, pagination, top-N queries, score updates | [leaderboards](reference/patterns/leaderboards.md) |
| Real-time messaging: Pub/Sub patterns, sharded pub/sub, fan-out, channel-based routing, notification systems | [pubsub-patterns](reference/patterns/pubsub-patterns.md) |
| Search and autocomplete: prefix autocomplete, tag-based filtering, SINTERCARD, inverted indexes, faceted search | [search-autocomplete](reference/patterns/search-autocomplete.md) |
| Counting and dedup: atomic counters, sharded counters, idempotency keys, HyperLogLog approximate counting, deduplication | [counters](reference/patterns/counters.md) |


## Valkey-Specific Features

| Topic | Reference |
|-------|-----------|
| Conditional update (SET IFEQ), conditional delete (DELIFEQ) - compare-and-swap without Lua scripts | [conditional-ops](reference/valkey-features/conditional-ops.md) |
| Per-field TTL on hashes: HSETEX, HGETEX, HGETDEL, HEXPIRE, HPERSIST - fine-grained expiration within a single key | [hash-field-ttl](reference/valkey-features/hash-field-ttl.md) |
| Cluster enhancements: numbered databases in cluster mode, atomic slot migration | [cluster-enhancements](reference/valkey-features/cluster-enhancements.md) |
| Polygon geospatial queries: GEOSEARCH BYPOLYGON for arbitrary region matching | [geospatial](reference/valkey-features/geospatial.md) |
| Valkey performance internals: I/O threading, SIMD acceleration, prefetch, zero-copy, dual-channel replication | [performance-summary](reference/valkey-features/performance-summary.md) |


## Client Libraries

| Topic | Reference |
|-------|-----------|
| Client library comparison: Valkey GLIDE, ioredis, redis-py, Jedis, go-redis - features, language support, when to choose each | [overview](reference/clients/overview.md) |


## Security

| Topic | Reference |
|-------|-----------|
| Authentication setup, ACL users and permissions, key pattern restrictions, TLS encryption, network hardening, protected mode | [auth-and-acl](reference/security/auth-and-acl.md) |


## Anti-Patterns

| Topic | Reference |
|-------|-----------|
| Common mistakes: KEYS in production, DEL on big keys, missing maxmemory, hot key problems, unbounded collections, missing TTL | [quick-reference](reference/anti-patterns/quick-reference.md) |
