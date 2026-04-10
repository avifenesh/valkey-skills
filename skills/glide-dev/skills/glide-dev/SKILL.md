---
name: glide-dev
description: "Use when contributing to the GLIDE client - Rust core internals, language bindings (PyO3/JNI/NAPI/CGO/FFI), protocol layer, PubSub synchronizer, cluster topology, and build system. For using GLIDE in apps, see valkey-glide instead."
version: 1.0.0
argument-hint: "[language binding or core component]"
---

# Valkey GLIDE Contributor Reference

## Routing

- Rust core, connection management, protocol -> Core Architecture
- Python bindings, PyO3, CFFI -> Language Bindings
- Java bindings, JNI -> Language Bindings
- Node.js bindings, NAPI -> Language Bindings
- Go bindings, CGO, FFI -> Language Bindings
- PubSub synchronizer, subscription management -> PubSub Internals
- Cluster topology, slot mapping, failover -> Cluster Internals
- Adding a new command -> Adding Commands
- Build environment, prerequisites, testing, test utils, cluster setup -> Build & Test

## Repository Structure

```
glide-core/     # Rust core - connection, protocol, clustering, PubSub sync
  src/client/   # Client implementation, connection pool
  src/pubsub/   # PubSub synchronizer (desired vs actual state)
  src/protobuf/ # Protobuf definitions for IPC
ffi/            # C FFI layer for Python sync and Go
logger_core/    # Rust logging infrastructure
python/         # Python wrappers (async via PyO3, sync via CFFI)
java/           # Java wrappers via JNI
node/           # Node.js wrappers via NAPI v2
go/             # Go wrappers via CGO + FFI
utils/          # Test utilities, cluster management scripts
benchmarks/     # Performance benchmarks
```

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
