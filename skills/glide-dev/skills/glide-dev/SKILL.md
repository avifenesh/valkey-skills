---
name: glide-dev
description: "Use when contributing to the GLIDE client - Rust core internals, language bindings (PyO3/JNI/NAPI/CGO/FFI), protocol layer, PubSub synchronizer, cluster topology, and build system. For using GLIDE in apps, see valkey-glide instead."
version: 1.1.0
argument-hint: "[language binding or core component]"
---

# Valkey GLIDE Contributor Reference

## Routing

| Question | Section below |
|----------|---------------|
| Rust core, connection management, protocol | Core Architecture |
| Python / Java / Node / Go / PHP / C# / Ruby bindings and their FFI mechanism | Language Bindings |
| PubSub synchronizer, subscription management | Core Architecture (pubsub-internals reference) |
| Cluster topology, slot mapping, failover | Core Architecture (cluster-internals reference) |
| Adding a new command across protobuf + Rust + wrappers | Language Bindings (adding-commands reference) |
| Build environment, prerequisites, testing, test utils, cluster setup | Language Bindings (build-and-test reference) |

## Repository Structure

```
glide-core/
  src/            # Real GLIDE core (what this skill describes)
    client/       # Client impl - multiplexer, not a pool
    pubsub/       # PubSub synchronizer (desired vs actual state)
    protobuf/     # Protobuf definitions for IPC
  redis-rs/       # Vendored redis-rs fork - inheritance, NOT GLIDE code
ffi/              # C FFI surface (Python sync, Go, Java JNI, PHP, C#, Ruby)
logger_core/      # Rust logging
python/           # glide-async (UDS + PyO3) and glide-sync (FFI + CFFI)
java/             # JNI wrappers (migrated from UDS to direct JNI in 2.2)
node/             # NAPI v2 wrappers, UDS-backed
go/               # CGO against ffi/
utils/            # Test utilities, cluster scripts
```

## Grep hazards (read before editing core)

These are the recurring agent mistakes. Every change touching `glide-core/` or `ffi/` should be checked against this list.

1. **GLIDE is a multiplexer, not a connection pool.** One multiplexed connection, many in-flight requests tagged with IDs. `DEFAULT_MAX_INFLIGHT_REQUESTS = 1000` is the inflight cap, not a pool size. Never say "connection pool" about the core client.
2. **Cluster client is NOT a pool of standalone clients.** `ClientWrapper` is an enum: `Standalone(StandaloneClient)` vs `Cluster { client: ClusterConnection }` - two separate types with different state machines. Cluster does not wrap standalone.
3. **`glide-core/redis-rs/` is vendored redis-rs, NOT GLIDE.** Lots of code there is inherited and not wired. Before claiming "the core does X" from `glide-core/redis-rs/**`, trace the call graph from `glide-core/src/**` outward. The real GLIDE client code is `glide-core/src/client/` (3 files: `mod.rs`, `standalone_client.rs`, `reconnecting_connection.rs`).
4. **UDS is in-process IPC, not network.** Python-async and Node talk to the Rust core over a Unix socket within the same process - just a message-passing mechanism between the language layer and the Rust runtime. Not a separate process, not a remote connection.
5. **HA/reliability and performance are both top priorities - never risk either.** HA/reliability is arbitrated first when tradeoffs force a choice, but performance is not "secondary". Every core change is measured and validated for both. No change ships if it regresses reconnect/failover behavior OR throughput/latency.
6. **Cross-language blast radius.** `glide-core/` or `ffi/` changes affect every wrapper (Python async + sync, Node, Java, Go, PHP, C#, Ruby) and both FFI modes. Validate across the matrix.
7. **Routing lives in `redis::cluster_routing` (vendored), not `request_type.rs`.** `request_type.rs` is a command-name → enum mapping, nothing more. Routing decisions come from `RoutingInfo::for_routable()` and user-specified overrides.
8. **Typo in upstream constant: `UNIX_SOCKER_DIR` (not `UNIX_SOCKET_DIR`).** In `glide-core/src/socket_listener.rs`. Grep for the misspelled name or you'll miss the socket-path source.

## Core Architecture

| Topic | Reference |
|-------|-----------|
| Three-layer design, FFI mechanisms, module structure, runtime model, command flow, key structs | [core-architecture](reference/core-architecture.md) |
| Connection model: multiplexing, inflight limiting, timeouts, reconnection, lazy connect, read-only mode | [connection-internals](reference/connection-internals.md) |
| PubSub synchronizer: desired vs actual state, reconciliation loop, resubscription | [pubsub-internals](reference/pubsub-internals.md) |
| Cluster topology: slot map, node discovery, MOVED/ASK handling, failover detection | [cluster-internals](reference/cluster-internals.md) |

## Language Bindings

| Language | Mechanism | Native Lib | IPC |
|----------|-----------|------------|-----|
| Python async | PyO3 | `python/glide-async/` | Unix socket |
| Python sync | CFFI | `ffi/` | FFI calls |
| Java | JNI | `java/src/lib.rs` | JNI calls |
| Node.js | NAPI v2 | `node/rust-client/` | Unix socket |
| Go | CGO | `ffi/` | FFI calls |
| PHP | PHP FFI | FFI extension (separate repo) | Direct FFI calls |
| C# | P/Invoke | .NET interop (separate repo) | Direct FFI calls |
| Ruby | FFI | `valkey-rb` gem (separate repo) | Direct FFI calls |

| Topic | Reference |
|-------|-----------|
| Adding commands: protobuf definition, Rust handler, language wrappers, tests | [adding-commands](reference/adding-commands.md) |
| Build and test for each language | [build-and-test](reference/build-and-test.md) |
