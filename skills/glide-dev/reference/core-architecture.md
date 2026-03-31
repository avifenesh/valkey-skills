# GLIDE Core Architecture

Use when understanding the Rust core design, three-layer architecture, FFI mechanisms per language, the module structure, command flow, runtime model, or debugging connection/protocol issues.

## Three-Layer Design

```
Application Code (Python / Java / Node.js / Go / PHP / C# / Ruby)
        |
Language Wrapper (lightweight bindings)
        |
    FFI / CGO / napi-rs / JNI / PyO3 / Protobuf
        |
    Rust Core (glide-core)
        |
    Valkey / Redis OSS Server
```

The Rust core is the single source of truth for connection handling, protocol parsing, and cluster logic. Language wrappers never reimplement these behaviors - they delegate to the core through their respective FFI mechanism.

### Design Philosophy

The Rust core is not a standalone server-like component - it is an integral part of the client itself. The majority of a command's lifetime, after network time, is spent in the core. Creating a second client is expensive (new TCP connections to every cluster node, separate topology tracking), but adding concurrency within a single client is cheap.

## Request Pipeline

```
Language Client -> [socket/FFI] -> socket_listener -> Client -> Valkey Server
                                                   <- Response routing
                                                   <- Push notifications (PubSub)
```

### Socket Listener (`glide-core/src/socket_listener.rs`)

The socket listener is the entry point for IPC-based language bindings (Python async, Node.js). It:
1. Creates a Unix domain socket per client connection
2. Reads protobuf-encoded `CommandRequest` messages from the socket
3. Routes them to the appropriate `Client` method
4. Writes protobuf-encoded `Response` messages back

Key types: `CommandRequest`, `Response`, `ClosingReason`, `RotatingBuffer`

### Client (`glide-core/src/client/mod.rs`)

The client manages connections and command execution:
- **Standalone**: single connection or primary+replicas
- **Cluster**: connection pool per node, slot-based routing

Key components:
- `ClientWrapper` - holds the underlying redis-rs client
- `reconnecting_connection` - auto-reconnect with backoff
- `value_conversion` - converts redis-rs `Value` to protobuf `Response`

### Protobuf IPC (`glide-core/src/protobuf/`)

All cross-language communication uses protobuf for type safety and performance:
- `connection_request.proto` - client configuration
- `command_request.proto` - individual commands, batches, cluster scan
- `response.proto` - command responses, errors

## Module Structure

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

## FFI Mechanisms by Language

Two distinct communication paths:

### Socket IPC Path (Python async, Node.js)

```
Wrapper  -->  Unix Domain Socket  -->  socket_listener  -->  glide-core
```

The `socket_listener.rs` creates a Unix socket at `/tmp/glide-socket-{uuid}`. Requests are Protobuf-encoded `CommandRequest` messages framed by varint length prefixes. The `RotatingBuffer` (initial size 65,536 bytes) handles efficient message framing.

Key constants:
- `SOCKET_FILE_NAME`: `"glide-socket"`
- `MAX_REQUEST_ARGS_LENGTH`: 4096 (2^12) - threshold for inline vs pointer arg pass

### Direct FFI Path (Java, Go, Python sync, PHP, C#)

```
Wrapper  -->  JNI / CGO / CFFI / FFI ext / .NET interop  -->  glide-core
```

No socket involved - direct function calls through the language's FFI.

### Per-Language Bindings

| Language | Binding Crate | Mechanism | Communication |
|----------|--------------|-----------|---------------|
| Python (async) | `python/glide-async/` | PyO3 | Unix socket IPC + Protobuf |
| Python (sync) | `python/glide-sync/` | CFFI | Direct FFI via `ffi/` crate |
| Node.js | `node/rust-client/` | napi-rs (NAPI v2) | Unix socket IPC + Protobuf |
| Java | `java/src/` | JNI | Direct JNI calls + Protobuf |
| Go | via `ffi/` | CGO + cbindgen | Direct FFI calls |
| PHP | via FFI extension | PHP FFI | Direct FFI calls |
| C# | via .NET interop | P/Invoke | Direct FFI calls |

**Python Async** - `python/glide-async/src/lib.rs` uses PyO3, calls `start_socket_listener`, Python sends Protobuf over socket. Responses via `value_from_pointer(py, pointer: u64)`.

**Node.js** - `node/rust-client/src/lib.rs` uses `#[napi]` macro, socket listener path. Exports constants: `DEFAULT_REQUEST_TIMEOUT_IN_MILLISECONDS`, `DEFAULT_CONNECTION_TIMEOUT_IN_MILLISECONDS`, `DEFAULT_INFLIGHT_REQUESTS_LIMIT`.

**Java** - `java/src/lib.rs` uses JNI. Migrated from UDS+Protobuf to direct JNI in GLIDE 2.2 (Windows support). Includes own `process_command_for_compression` outside socket listener path.

**Go and Python Sync** - `ffi/src/lib.rs` provides C-compatible API with `extern "C"` functions. Go uses CGO with cbindgen headers, Python sync uses CFFI. `#[repr(C)]` structs for cross-language compatibility.

## Runtime Model

GLIDE creates a single-threaded Tokio runtime in a dedicated OS thread:

```rust
static RUNTIME: OnceCell<GlideRt> = OnceCell::new();

pub struct GlideRt {
    pub runtime: Handle,
    pub(crate) thread: Option<JoinHandle<()>>,
    shutdown_notifier: Arc<Notify>,
}
```

`get_or_init_runtime()` initializes once per process. All async operations run on this runtime. Thread named `"glide-runtime-thread"`. All GLIDE client instances in a process share one event loop.

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
10. Post-command hooks run (SELECT updates db tracking, AUTH updates credentials)
11. Result is returned to the wrapper via the FFI mechanism

## Dependencies

- `redis` crate (vendored/forked) - low-level RESP protocol, cluster routing
- `tokio` - async runtime
- `protobuf` - IPC serialization
- `telemetrylib` - OpenTelemetry integration

## Version History

| Version | Date | Key Architectural Changes |
|---------|------|---------------------------|
| 1.2 | Dec 2024 | AZ-aware routing, Vector Search + JSON module support |
| 1.3 | Feb 2025 | Go client preview |
| 2.0 | Jun 2025 | Go GA, OpenTelemetry, Batch API (replacing Transaction), Lazy Connection |
| 2.1 | Sep 2025 | Valkey 9 support, Python Sync API, Jedis compatibility layer |
| 2.2 | Nov 2025 | Java JNI migration (Windows support), IAM auth, Seed-based topology refresh |
| 2.3 | Mar 2026 | Dynamic PubSub, mTLS, Java 8 compat, uber JAR, read-only mode |
