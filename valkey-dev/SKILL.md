---
name: valkey-dev
description: "Use when contributing to the Valkey server codebase, understanding Valkey architecture or internals, building from source, writing tests, navigating the C code, writing modules, reviewing PRs in valkey-io/valkey, debugging Valkey, or working with Valkey cluster, replication, or data structures."
version: 1.0.0
argument-hint: "[topic]"
---

# Valkey Contributor Reference

59 source-verified reference docs covering every major subsystem of the Valkey server.

Browse by subsystem below or ask about a specific topic. Each link leads to a focused reference doc with struct definitions, function signatures, and implementation details verified against the actual C source.

## Routing

- Building/compiling -> Build & Test
- Crash/hang investigation -> Architecture (event-loop), Threading, Monitoring (debug)
- Data type behavior -> Data Structures (encoding-transitions), Config
- Eviction/maxmemory/LRU/LFU -> Memory (eviction)
- Performance work -> Threading, Memory, Monitoring (latency)
- New command implementation -> Architecture (command-dispatch), Modules
- Test writing -> Build & Test (tcl-tests, unit-tests)
- Security/auth -> Security (acl, tls)
- Replication/HA -> Replication, Cluster, Sentinel

## Quick Start

    # Build
    make -j$(nproc)

    # Run tests
    ./runtest --verbose
    ./runtest-cluster
    ./runtest-moduleapi
    make test-unit

    # Debug build
    make noopt

    # Build with sanitizers
    make SANITIZER=address


## Critical Rules

1. **DCO sign-off required** - every commit needs `Signed-off-by` ([workflow](reference/contributing/workflow.md))
2. **clang-format-18** - CI rejects formatting violations ([workflow](reference/contributing/workflow.md))
3. **Tests are non-negotiable** - every contribution must include tests ([tcl-tests](reference/testing/tcl-tests.md))
4. **camelCase functions, snake_case variables** - see coding style in [workflow](reference/contributing/workflow.md)
5. **No anonymous contributions** - real identity required


## Architecture

| Topic | Reference |
|-------|-----------|
| Repository layout, valkeyServer struct, main() boot | [overview](reference/architecture/overview.md) |
| ae.c reactor pattern, epoll/kqueue, beforeSleep | [event-loop](reference/architecture/event-loop.md) |
| RESP parsing to command execution, processCommand | [command-dispatch](reference/architecture/command-dispatch.md) |
| Client lifecycle, buffers, I/O threading states | [networking](reference/architecture/networking.md) |
| RESP2/RESP3 types, inline/multibulk parsing | [resp-protocol](reference/architecture/resp-protocol.md) |


## Data Structures

| Topic | Reference |
|-------|-----------|
| Simple Dynamic Strings - 5 header variants, binary safe | [sds](reference/data-structures/sds.md) |
| Open-addressing hash table (8.1+), 64-byte buckets, SIMD | [hashtable](reference/data-structures/hashtable.md) |
| Legacy chained hash table, incremental rehashing | [dict](reference/data-structures/dict.md) |
| Compact sequential encoding for small collections | [listpack](reference/data-structures/listpack.md) |
| Doubly-linked list of listpacks, LZF compression | [quicklist](reference/data-structures/quicklist.md) |
| Probabilistic sorted structure for sorted sets | [skiplist](reference/data-structures/skiplist.md) |
| Compressed radix tree for streams and consumer groups | [rax](reference/data-structures/rax.md) |
| When Valkey switches between compact and full encodings | [encoding-transitions](reference/data-structures/encoding-transitions.md) |


## Persistence

| Topic | Reference |
|-------|-----------|
| RDB snapshot format, BGSAVE fork, RDB loading | [rdb](reference/persistence/rdb.md) |
| Multi-part AOF (BASE + INCR + manifest), fsync policies | [aof](reference/persistence/aof.md) |


## Replication

| Topic | Reference |
|-------|-----------|
| PSYNC, replication backlog, dual IDs, propagation | [overview](reference/replication/overview.md) |
| Dual-channel replication (8.0+), parallel RDB transfer | [dual-channel](reference/replication/dual-channel.md) |


## Cluster

| Topic | Reference |
|-------|-----------|
| Hash slots, gossip protocol, cluster bus, MOVED/ASK | [overview](reference/cluster/overview.md) |
| PFAIL/FAIL detection, epoch-based election, manual modes | [failover](reference/cluster/failover.md) |
| Traditional MIGRATE and atomic slot migration (9.0) | [slot-migration](reference/cluster/slot-migration.md) |


## Sentinel

| Topic | Reference |
|-------|-----------|
| Full sentinel mode - monitoring, failover, state machine | [sentinel-mode](reference/sentinel/sentinel-mode.md) |


## Memory Management

| Topic | Reference |
|-------|-----------|
| zmalloc wrapper, jemalloc integration, memory tracking | [zmalloc](reference/memory/zmalloc.md) |
| Background deletion (UNLINK), async free via BIO | [lazy-free](reference/memory/lazy-free.md) |
| Active defragmentation in 500us cycles, slab analysis | [defragmentation](reference/memory/defragmentation.md) |
| Eviction policies, LRU/LFU approximation, maxmemory enforcement | [eviction](reference/memory/eviction.md) |


## Threading

| Topic | Reference |
|-------|-----------|
| I/O thread pool, lock-free SPSC queues, read/write offload | [io-threads](reference/threading/io-threads.md) |
| Background I/O threads - fsync, lazy free, close, RDB save | [bio](reference/threading/bio.md) |
| Batch key prefetching for 50%+ pipeline throughput gain | [prefetch](reference/threading/prefetch.md) |


## Scripting

| Topic | Reference |
|-------|-----------|
| EVAL/EVALSHA, Lua integration, script caching | [eval](reference/scripting/eval.md) |
| FUNCTION LOAD/CALL, library-grouped persistent functions | [functions](reference/scripting/functions.md) |
| Pluggable scripting engine architecture, 4-version ABI | [scripting-engine](reference/scripting/scripting-engine.md) |


## Security

| Topic | Reference |
|-------|-----------|
| ACL system - users, selectors, command categories, audit | [acl](reference/security/acl.md) |
| TLS/mTLS, certificate management, background reloading | [tls](reference/security/tls.md) |


## Pub/Sub

| Topic | Reference |
|-------|-----------|
| Channel/pattern subscriptions, sharded pub/sub | [pubsub](reference/pubsub/pubsub.md) |
| Keyspace notifications, event types, config flags | [notifications](reference/pubsub/notifications.md) |


## Transactions

| Topic | Reference |
|-------|-----------|
| MULTI/EXEC/WATCH, optimistic locking, error handling | [multi-exec](reference/transactions/multi-exec.md) |
| Blocking commands (BLPOP etc.), key readiness, timeouts | [blocking](reference/transactions/blocking.md) |


## Configuration

| Topic | Reference |
|-------|-----------|
| Config parsing, runtime CONFIG SET, type system, apply callbacks | [config-system](reference/config/config-system.md) |
| Database selection, key lookup, SCAN, FLUSHDB | [db-management](reference/config/db-management.md) |
| Active/lazy expiration, hash field TTL, replica expiry | [expiry](reference/config/expiry.md) |


## Monitoring

| Topic | Reference |
|-------|-----------|
| Command logging (slow, large-request, large-reply) | [commandlog](reference/monitoring/commandlog.md) |
| Latency monitoring framework, 25+ event types, DOCTOR | [latency](reference/monitoring/latency.md) |
| Client-side caching, invalidation, broadcast mode | [tracking](reference/monitoring/tracking.md) |
| DEBUG command, crash reporting, software watchdog | [debug](reference/monitoring/debug.md) |


## Modules

| Topic | Reference |
|-------|-----------|
| ValkeyModule API lifecycle, command registration, context | [api-overview](reference/modules/api-overview.md) |
| Custom data types, RDB callbacks, blocking commands | [types-and-commands](reference/modules/types-and-commands.md) |
| Rust module SDK, valkey-module crate, C-vs-Rust comparison | [rust-sdk](reference/modules/rust-sdk.md) |


## Valkey-Specific Subsystems

| Topic | Reference |
|-------|-----------|
| Multi-index KV store, Fenwick tree, per-slot organization | [kvstore](reference/valkey-specific/kvstore.md) |
| robj with embedded key/expire, encoding management | [object-lifecycle](reference/valkey-specific/object-lifecycle.md) |
| Pluggable connection type framework (TCP/TLS/Unix/RDMA) | [transport-layer](reference/valkey-specific/transport-layer.md) |
| RDMA transport protocol, Linux-only, page-aligned buffers | [rdma](reference/valkey-specific/rdma.md) |
| Volatile set (vset) - adaptive expiry-aware set with SIMD probe | [vset](reference/valkey-specific/vset.md) |


## Build & Test

| Topic | Reference |
|-------|-----------|
| Make/CMake, flags, dependencies, cross-platform | [building](reference/build/building.md) |
| ASan, UBSan, TSan, Valgrind, Helgrind | [sanitizers](reference/build/sanitizers.md) |
| Tcl integration tests, tags, helpers, writing tests | [tcl-tests](reference/testing/tcl-tests.md) |
| Google Test C++ unit tests | [unit-tests](reference/testing/unit-tests.md) |
| CI pipeline - PR gates, daily matrix, skip tokens | [ci-pipeline](reference/testing/ci-pipeline.md) |


## Contributing

| Topic | Reference |
|-------|-----------|
| PR process, coding style, DCO, commit conventions | [workflow](reference/contributing/workflow.md) |
| TSC, maintainers, voting rules, release cadence | [governance](reference/contributing/governance.md) |
