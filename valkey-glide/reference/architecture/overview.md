# Architecture Overview

Use when understanding GLIDE's overall design, the three-layer architecture, FFI mechanisms per language, the Rust core's module structure, or the command flow from wrapper to server.

Valkey GLIDE uses a three-layer architecture where a shared Rust core handles all protocol and connection logic, while thin language wrappers provide idiomatic APIs for each supported language.

---

## Three-Layer Design

```
Application Code (Python / Java / Node.js / Go / PHP / C#)
        |
Language Wrapper (lightweight bindings)
        |
    FFI / CGO / napi-rs / JNI / PyO3 / Protobuf
        |
    Rust Core (glide-core)
        |
    Valkey / Redis OSS Server
```

Each layer has a distinct responsibility. The Rust core is the single source of truth for connection handling, protocol parsing, and cluster logic. Language wrappers never reimplement these behaviors - they delegate to the core through their respective FFI mechanism.

### Design Philosophy: The Rust Core as an Integral Part

The Rust core is not a standalone server-like component - it is an integral part of the client itself. The majority of a command's lifetime, after network time, is spent in the core. The language wrapper acts as the client and uses the Rust core as its "arm" to perform tasks. The "core" is a development term, not an end-user term.

This leads to a key mental model for client instances: creating a second client is expensive (new TCP connections to every cluster node, separate topology tracking), but adding concurrency within a single client is cheap. The factory metaphor captures this - if the manager is not happy with the pace, he wants another robotic arm, not another manager.

### Progressive Complexity Concern

A known usability ledge exists in GLIDE's current design. A developer starts with a single client where multi-slot MGET works transparently across slots. But advanced features (batches, transactions, WATCH) require understanding the single-connection model and potentially creating separate clients (see "When to Create Separate Client Instances" in [connection-model.md](connection-model.md)). These correctness problems - such as read-after-write inconsistency with `PreferReplica`, or WATCH interference between threads - may not surface during development but only once deployed to a real cluster environment with replicas and failovers.

---

## What the Rust Core Handles

The `glide-core` crate (at `glide-core/src/`) is the engine. Its module structure:

| Module | File | Responsibility |
|--------|------|----------------|
| `client` | `client/mod.rs` | Top-level `Client` struct, command dispatch, lazy init |
| `client::types` | `client/types.rs` | `ConnectionRequest`, `ReadFrom`, `TlsMode`, `ConnectionRetryStrategy` |
| `client::reconnecting_connection` | `client/reconnecting_connection.rs` | `ReconnectingConnection` with state machine and backoff |
| `client::standalone_client` | `client/standalone_client.rs` | `StandaloneClient` with primary/replica topology |
| `socket_listener` | `socket_listener.rs` | Unix socket IPC for Python/Node.js wrappers |
| `cluster_scan_container` | `cluster_scan_container.rs` | Cross-layer cursor lifecycle for cluster SCAN |
| `request_type` | `request_type.rs` | Command enum mapping to Redis `Cmd` objects |
| `scripts_container` | `scripts_container.rs` | Lua script SHA1 caching for EVALSHA |
| `compression` | `compression.rs` | Optional Zstd/LZ4 compression for values |
| `errors` | `errors.rs` | Error types and message formatting |
| `pubsub` | `pubsub/` | PubSub synchronization and resubscription |
| `iam` | `iam/` | AWS IAM token management for ElastiCache/MemoryDB |
| `otel_db_semantics` | `otel_db_semantics.rs` | OpenTelemetry span attribute population |
| `rotating_buffer` | `rotating_buffer.rs` | Efficient protobuf message framing for socket IPC |

The core handles:

- **RESP protocol parsing** - both RESP2 and RESP3, via the `redis` crate's `MultiplexedConnection`
- **Connection management** - single multiplexed connection per node, lazy establishment, reconnection (details in [connection-model.md](connection-model.md))
- **Cluster topology** - seed node discovery, periodic background checks, MOVED/ASK redirect handling (details in [cluster-topology.md](cluster-topology.md))
- **Slot-based routing** - automatic routing via `RoutingInfo::for_routable()`, multi-slot splitting (details in [cluster-topology.md](cluster-topology.md))
- **Error and retry logic** - exponential backoff with jitter, permanent vs transient error classification
- **Inflight request limiting** - default 1000 per client (`DEFAULT_MAX_INFLIGHT_REQUESTS`) (details in [connection-model.md](connection-model.md))
- **OpenTelemetry** - per-command spans with DB semantic attributes, timeout/retry/MOVED error metrics. Each command generates a top-level span covering the entire lifecycle and a nested `send_command` span measuring actual network time, separating client-side queuing latency from server communication delays. Three built-in metrics are emitted: timeouts, retries, and MOVED errors. Production sampling at 1-5% is recommended. (details in [opentelemetry](../features/opentelemetry.md))
- **Compression** - optional Zstd or LZ4 for values above a configurable threshold (details in [compression](../features/compression.md))
- **IAM authentication** - automatic token refresh for AWS ElastiCache and MemoryDB (details in [tls-auth](../features/tls-auth.md))

---

## What Language Wrappers Handle

Language wrappers are thin. Their responsibilities:

- **Idiomatic API surface** - async/await in Python, `CompletableFuture` in Java, Promises in Node.js, synchronous in Go/PHP
- **Type conversion** - converting Redis `Value` variants to native language types
- **Configuration building** - constructing `ConnectionRequest` protobuf or struct from user-facing config objects
- **PubSub message delivery** - routing push messages to language-specific callback mechanisms

Wrappers never implement connection pooling, retry logic, cluster routing, or protocol parsing.

---

## FFI Mechanisms by Language

Each wrapper uses a different mechanism to bridge to the Rust core. There are two distinct communication paths:

### Socket IPC Path (Python async, Node.js)

```
Wrapper  -->  Unix Domain Socket  -->  socket_listener  -->  glide-core
```

The `socket_listener.rs` module creates a Unix socket at `/tmp/glide-socket-{uuid}`. Requests are Protobuf-encoded `CommandRequest` messages framed by varint length prefixes. Responses are Protobuf-encoded `Response` messages written back on the same socket. The `RotatingBuffer` (initial size 65,536 bytes) handles efficient message framing.

Key constants from `socket_listener.rs`:
- `SOCKET_FILE_NAME`: `"glide-socket"`
- `MAX_REQUEST_ARGS_LENGTH`: 4096 (2^12) - threshold for inline vs pointer arg passing

### Direct FFI Path (Java, Go, Python sync, PHP, C#)

```
Wrapper  -->  JNI / CGO / CFFI / FFI ext / .NET interop  -->  glide-core
```

No socket involved. The wrapper calls Rust functions directly through the language's foreign function interface.

### Per-Language Details

| Language | Binding Crate | Mechanism | Communication |
|----------|--------------|-----------|---------------|
| Python (async) | `python/glide-async/` | PyO3 | Unix socket IPC + Protobuf |
| Python (sync) | `python/glide-sync/` | CFFI | Direct FFI via `ffi/` crate |
| Node.js | `node/rust-client/` | napi-rs (NAPI v2) | Unix socket IPC + Protobuf |
| Java | `java/src/` | JNI | Direct JNI calls + Protobuf |
| Go | via `ffi/` | CGO + cbindgen | Direct FFI calls |
| PHP | via FFI extension | PHP FFI | Direct FFI calls |
| C# | via .NET interop | P/Invoke | Direct FFI calls |

### Python Async (PyO3 + Socket IPC)

The `python/glide-async/src/lib.rs` binding uses PyO3 to expose Rust functions to Python. It calls `start_socket_listener` to create a Unix socket, then the Python layer sends Protobuf-encoded commands over that socket. Response values are passed back via `value_from_pointer(py: Python, pointer: u64)` which takes a u64 raw pointer and reconstructs the Python object from the heap.

### Node.js (napi-rs + Socket IPC)

The `node/rust-client/src/lib.rs` binding uses the `#[napi]` macro from napi-rs. It also uses the socket listener path. The binding exports constants directly from glide-core:
- `DEFAULT_REQUEST_TIMEOUT_IN_MILLISECONDS` (from `DEFAULT_RESPONSE_TIMEOUT`)
- `DEFAULT_CONNECTION_TIMEOUT_IN_MILLISECONDS` (from `DEFAULT_CONNECTION_TIMEOUT`)
- `DEFAULT_INFLIGHT_REQUESTS_LIMIT` (from `DEFAULT_MAX_INFLIGHT_REQUESTS`)

### Java (JNI + Protobuf)

The `java/src/lib.rs` binding uses JNI directly. Commands are serialized as Protobuf, passed through JNI, and deserialized in the Rust layer. The Java binding includes its own `process_command_for_compression` function that handles compression outside the socket listener path.

The Java client underwent a significant architectural change in GLIDE 2.2: migration from Unix Domain Socket + Protobuf communication to direct JNI-based communication. This was primarily driven by Windows support - UDS is not available on Windows. Post-migration, the JNI async bridge required fixes for swallowed errors where CompletableFutures could be left dangling, shutdown race conditions and registry leaks, and the removal of the Java-side inflight counter in GLIDE 2.2.9 to make Rust the sole authority for inflight tracking.

### Go and Python Sync (FFI crate)

The `ffi/src/lib.rs` crate provides a C-compatible API using `extern "C"` functions. Go uses CGO with C headers generated by cbindgen. Python sync uses CFFI. Key exported functions include `store_script`, `drop_script`, and the client lifecycle functions. The FFI crate uses `#[repr(C)]` structs for cross-language compatibility.

---

## Key Structs and Types

### Client Layer (`client/mod.rs`)

```rust
pub struct Client {
    internal_client: Arc<RwLock<ClientWrapper>>,
    request_timeout: Duration,
    inflight_requests_allowed: Arc<AtomicIsize>,
    inflight_requests_limit: isize,
    inflight_log_interval: isize,
    iam_token_manager: Option<Arc<IAMTokenManager>>,
    compression_manager: Option<Arc<CompressionManager>>,
    pubsub_synchronizer: Arc<dyn PubSubSynchronizer>,
    otel_metadata: OTelMetadata,
}

pub enum ClientWrapper {
    Standalone(StandaloneClient),
    Cluster { client: ClusterConnection },
    Lazy(Box<LazyClient>),
}
```

The `ClientWrapper::Lazy` variant enables deferred connection - the client starts as `Lazy` and transitions to `Standalone` or `Cluster` on the first command via `get_or_initialize_client()`.

### Connection Configuration (`client/types.rs`)

```rust
pub struct ConnectionRequest {
    pub addresses: Vec<NodeAddress>,
    pub cluster_mode_enabled: bool,
    pub read_from: Option<ReadFrom>,
    pub tls_mode: Option<TlsMode>,
    pub request_timeout: Option<u32>,
    pub connection_timeout: Option<u32>,
    pub connection_retry_strategy: Option<ConnectionRetryStrategy>,
    pub inflight_requests_limit: Option<u32>,
    pub lazy_connect: bool,
    pub periodic_checks: Option<PeriodicCheck>,
    pub pubsub_subscriptions: Option<PubSubSubscriptionInfo>,
    pub compression_config: Option<CompressionConfig>,
    pub tcp_nodelay: bool,
    // ... additional fields
}
```

### Protobuf Wire Format (`protobuf/connection_request.proto`)

The Protobuf schema defines the wire format used by socket-IPC wrappers (Python async, Node.js). It mirrors the Rust `ConnectionRequest` struct. Key message types: `ConnectionRequest`, `AuthenticationInfo`, `ConnectionRetryStrategy`, `CompressionConfig`.

---

## Runtime Model

GLIDE creates a single-threaded Tokio runtime in a dedicated OS thread, managed by the `GlideRt` struct:

```rust
static RUNTIME: OnceCell<GlideRt> = OnceCell::new();

pub struct GlideRt {
    pub runtime: Handle,
    pub(crate) thread: Option<JoinHandle<()>>,
    shutdown_notifier: Arc<Notify>,
}
```

The `get_or_init_runtime()` function initializes this runtime once per process. All async operations (connection, command dispatch, reconnection, topology checks) run on this runtime. The runtime thread is named `"glide-runtime-thread"`.

This single-runtime model means all GLIDE client instances in a process share one event loop, regardless of how many clients are created.

---

## Command Flow

1. Application calls a command method on the language wrapper
2. Wrapper serializes the command (Protobuf for socket IPC, direct struct for FFI)
3. Rust core receives the command in `Client::send_command()`
4. Core checks for IAM token refresh if IAM auth is configured
5. Core calls `get_or_initialize_client()` (handles lazy init on first call)
6. Core reserves an inflight slot via `reserve_inflight_request()`
7. Core determines routing (`RoutingInfo::for_routable()` or user-specified)
8. Command is dispatched to `StandaloneClient` or `ClusterConnection`
9. Response is optionally decompressed and type-converted
10. Post-command hooks run (SELECT updates db tracking, AUTH updates credentials, etc.)
11. Result is returned to the wrapper via the FFI mechanism

---

## Version History and Architectural Evolution

| Version | Date | Key Architectural Changes |
|---------|------|---------------------------|
| 1.2 | Dec 2024 | AZ-aware routing, Vector Search + JSON module support |
| 1.3 | Feb 2025 | Go client preview |
| 2.0 | Jun 2025 | Go GA, OpenTelemetry, Batch API (replacing Transaction/ClusterTransaction), Lazy Connection |
| 2.1 | Sep 2025 | Valkey 9 support, Python Sync API, Jedis compatibility layer |
| 2.2 | Nov 2025 | Java JNI migration (Windows support), IAM auth, Seed-based topology refresh |
| 2.3 | Mar 2026 | Dynamic PubSub, mTLS, Java 8 compat, uber JAR, read-only mode |
