# Connection Model

Use when understanding GLIDE's single-connection-per-node design, multiplexing, inflight request limiting, request/connection timeouts, reconnection backoff, lazy connection, periodic health checks, read-only mode, or custom commands.

GLIDE uses a single multiplexed connection per node - not a connection pool. All requests from the application pipeline through this connection, leveraging Valkey's built-in pipelining. This eliminates connection pool management overhead and tuning complexity.

## Why Not a Connection Pool?

The reasoning is that most of a command's time is spent in flight between the application and server. An additional connection would not speed that up in the majority of cases. In less common scenarios where more parallelism is needed, the recommended approach is adding another client instance rather than a dynamic pool (see "When to Create Separate Client Instances" below). An internal connection pool for dedicated connections (WATCH, blocking commands) is planned, so users would not need separate client instances for those cases. The original intent was always for GLIDE to manage this internally.

---

## Multiplexed Connection Architecture

Each node (primary or replica) gets exactly one `MultiplexedConnection` from the `redis` crate. This connection handles concurrent requests by interleaving them on the wire using Valkey's pipelining protocol - multiple commands are sent without waiting for individual responses, and responses are matched back to their requests.

The connection is wrapped in `ReconnectingConnection` (defined in `client/reconnecting_connection.rs`), which adds state management and automatic reconnection:

```rust
struct InnerReconnectingConnection {
    state: Mutex<ConnectionState>,
    backend: ConnectionBackend,
}

enum ConnectionState {
    Connected(MultiplexedConnection),
    Reconnecting,
    InitializedDisconnected,
}
```

The three states:
- **Connected** - normal operation, commands flow through the `MultiplexedConnection`
- **Reconnecting** - a background task is attempting to re-establish the connection
- **InitializedDisconnected** - initial state when lazy connect is used and no connection has been made yet

---

## Lazy Connection Establishment

GLIDE connects eagerly by default. Lazy connection establishment - deferring connection until the first command is executed - is opt-in via the `lazy_connect` field in `ConnectionRequest` (defaults to `false`):

```rust
pub enum ClientWrapper {
    Standalone(StandaloneClient),
    Cluster { client: ClusterConnection },
    Lazy(Box<LazyClient>),
}

pub struct LazyClient {
    config: ConnectionRequest,
    push_sender: Option<mpsc::UnboundedSender<PushInfo>>,
}
```

When `lazy_connect` is true, `Client::new()` stores the configuration in a `LazyClient` wrapper and returns immediately (see `ClientWrapper` variants in [overview.md](overview.md)). On the first call to `send_command()`, the `get_or_initialize_client()` method detects the `Lazy` variant, creates the real client (standalone or cluster), and replaces the `Lazy` wrapper:

```rust
async fn get_or_initialize_client(&self) -> RedisResult<ClientWrapper> {
    {
        let guard = self.internal_client.read().await;
        if !matches!(&*guard, ClientWrapper::Lazy(_)) {
            return Ok(guard.clone()); // Already initialized
        }
    }
    // ... initialize and swap in the real client
}
```

When enabled, this reduces startup latency - the application does not block on connection establishment during client creation.

---

## Inflight Request Limiting

GLIDE limits the number of concurrent inflight requests per client to prevent overwhelming the server. The default limit is 1000.

### The Constant

From `client/mod.rs`:

```rust
/// Expected maximum request rate: 50,000 requests/second
/// Expected response time: 1 millisecond
///
/// According to Little's Law:
///   (50,000 requests/second) * (1 millisecond / 1000 milliseconds) = 50 requests
///
/// The value of 1000 provides a buffer for bursts.
pub const DEFAULT_MAX_INFLIGHT_REQUESTS: u32 = 1000;
```

The 1000 value is 20x the theoretical minimum needed for 50K req/s at 1ms latency. This headroom absorbs burst traffic without reaching the limit under normal conditions.

### How It Works

The `Client` struct holds an `inflight_requests_allowed: Arc<AtomicIsize>` counter. Before each command, `send_command()` calls `reserve_inflight_request()`:

```rust
pub fn reserve_inflight_request(&self) -> Option<InflightRequestTracker> {
    InflightRequestTracker::try_new(self.inflight_requests_allowed.clone())
}
```

The `InflightRequestTracker` atomically decrements the counter on creation and increments it on drop. If no slots are available, the command immediately returns an error:

```
"Reached maximum inflight requests"
```

### Observability

GLIDE logs inflight usage at debug level when it crosses a 10% threshold of the limit. The `inflight_log_interval` is calculated as `(inflight_limit / 10).max(1)`. Only one log message per threshold crossing - zero noise when stable.

### Configuring the Limit

Set `inflight_requests_limit` in the connection configuration. The Protobuf field is `uint32 inflight_requests_limit = 14`. If not set, `DEFAULT_MAX_INFLIGHT_REQUESTS` (1000) is used.

---

## Request Timeout

The default request timeout is 250ms:

```rust
pub const DEFAULT_RESPONSE_TIMEOUT: Duration = Duration::from_millis(250);
```

### Blocking Command Handling

Blocking commands (BLPOP, BRPOP, BLMOVE, BZPOPMAX, BZPOPMIN, BRPOPLPUSH, BLMPOP, BZMPOP, XREAD with BLOCK, XREADGROUP with BLOCK, WAIT, WAITAOF) receive special timeout treatment. GLIDE parses their timeout argument and extends the request timeout by 0.5 seconds:

```rust
const BLOCKING_CMD_TIMEOUT_EXTENSION: f64 = 0.5; // seconds
```

A timeout argument of `0` (meaning "block forever") disables the request timeout entirely for that command.

---

## Connection Timeout

The default connection timeout is 2000ms:

```rust
pub const DEFAULT_CONNECTION_TIMEOUT: Duration = Duration::from_millis(2000);
```

This applies to initial connection establishment and reconnection attempts. The outer `Client::new()` adds a 500ms buffer to the connection timeout for total client creation:

```rust
let client_creation_timeout = request.get_connection_timeout() + Duration::from_millis(500);
```

---

## Reconnection with Exponential Backoff

When a connection drops, `ReconnectingConnection::reconnect()` spawns a background task that retries with exponential backoff.

### State Transition on Disconnect

1. The connection state transitions from `Connected` to `Reconnecting`
2. The `connection_available_signal` (a `ManualResetEvent`) is reset - callers of `get_connection()` will block
3. A background task is spawned (not awaited) so reconnection continues even if the calling task is dropped

### Retry Logic

Reconnection uses an infinite backoff duration iterator from the `RetryStrategy`:

```rust
let infinite_backoff_dur_iterator = connection_clone
    .connection_options
    .connection_retry_strategy
    .unwrap()
    .get_infinite_backoff_dur_iterator();
for sleep_duration in infinite_backoff_dur_iterator {
    if connection_clone.is_dropped() { return; }
    match get_multiplexed_connection(&client, &connection_options).await {
        Ok(mut connection) => {
            // Verify with PING before accepting
            if connection.send_packed_command(&redis::cmd("PING")).await.is_err() {
                tokio::time::sleep(sleep_duration).await;
                continue;
            }
            // ... transition to Connected state
        }
        Err(_) => tokio::time::sleep(sleep_duration).await,
    }
}
```

Key behaviors:
- Reconnection continues indefinitely until success or client drop
- Each attempt is verified with a PING command before accepting the connection
- If the client is dropped (`client_dropped_flagged` is set), reconnection stops
- The `connection_available_signal` is set when reconnection succeeds, unblocking waiting callers

### Retry Strategy Configuration

The `ConnectionRetryStrategy` struct controls backoff: duration for attempt N is `factor * (exponent_base ^ N)`, with optional `jitter_percent` as a percentage of the computed duration. The `number_of_retries` field limits retries during initial connection (bounded backoff), but reconnection after a drop uses the infinite iterator.

### Permanent vs Transient Errors

During initial connection, certain errors are classified as permanent (no retries):

```rust
let is_permanent = matches!(
    e.kind(),
    redis::ErrorKind::AuthenticationFailed
        | redis::ErrorKind::InvalidClientConfig
        | redis::ErrorKind::RESP3NotSupported
) || e.to_string().contains("NOAUTH")
  || e.to_string().contains("WRONGPASS");
```

Authentication failures, invalid configuration, and protocol mismatches are never retried.

---

## Periodic Connection Checks

### Standalone Mode

For standalone clients, each `ReconnectingConnection` runs a periodic check task:

```rust
fn start_periodic_connection_check(reconnecting_connection: ReconnectingConnection) {
    task::spawn(async move {
        loop {
            reconnecting_connection
                .wait_for_disconnect_with_timeout(&CONNECTION_CHECKS_INTERVAL)
                .await;
            // ... check if connection is closed, trigger reconnect
        }
    });
}
```

The check interval is 3 seconds:

```rust
pub const CONNECTION_CHECKS_INTERVAL: Duration = Duration::from_secs(3);
```

This is a passive check - it monitors the connection's disconnect notifier rather than sending PING commands. If the connection is found to be closed, it triggers `reconnect()`.

There is also an optional active heartbeat feature (behind the `standalone_heartbeat` feature flag) that sends PING commands every second:

```rust
pub const HEARTBEAT_SLEEP_DURATION: Duration = Duration::from_secs(1);
```

### Cluster Mode

Cluster connections use the `periodic_connections_checks` setting, always enabled with the same 3-second interval:

```rust
builder = builder.periodic_connections_checks(Some(CONNECTION_CHECKS_INTERVAL));
```

---

## Connection State Preservation

GLIDE supports both RESP2 and RESP3 (configured via the `protocol` field, default RESP3). The protocol version and other connection properties are tracked and restored automatically on reconnection:

| Property | Tracked Via | Updated By |
|----------|------------|------------|
| Database ID | `update_connection_database()` | SELECT command |
| Password | `update_connection_password()` | AUTH command, IAM refresh |
| Username | `update_connection_username()` | AUTH command |
| Client name | `update_connection_client_name()` | CLIENT SETNAME command |
| Protocol version | `update_connection_protocol()` | HELLO command |

These methods update the stored `redis::Client` in the `ConnectionBackend`, ensuring that when a reconnection occurs, the new connection automatically re-establishes the previous state.

---

## When to Create Separate Client Instances

A single multiplexed connection cannot isolate state between concurrent operations. Create separate `Client` instances when:

- **Blocking commands** (BLPOP, BRPOP, BLMOVE, etc.) - these occupy the connection for their duration, blocking other commands from completing
- **WATCH/MULTI/EXEC** - optimistic locking requires an isolated connection because WATCH state is per-connection
- **Large value transfers** - streaming large values on a shared connection delays other requests
- **Database isolation** - SELECT changes the database for the entire connection; concurrent operations on different databases need separate clients
- **Different ReadFrom strategies** - read strategy is locked at client creation time with no per-command override, so applications needing both primary reads and replica reads for different commands must use separate clients. See [cluster-topology.md](cluster-topology.md) for full ReadFrom strategy details including AZ affinity.

### Automatic Pipelining

GLIDE's multiplexed connection means concurrent commands from multiple application threads are automatically pipelined over the single connection without explicit batching. For sequential commands from a single thread, the Batch API (introduced in GLIDE 2.0) provides explicit pipelining. See [batching](../features/batching.md) for detailed API patterns.

A known optimization opportunity exists: with explicit batches, flushing commands to the server before `execute()` is called would let the backend start processing earlier rather than waiting for the full batch to be assembled.

### Pipeline Consistency Gap with ReadFromPreferReplica

When a client is configured with `PreferReplica` and a non-atomic batch contains a write followed by a read to the same key (e.g., `INCR foo; GET foo`), the INCR may route to the primary while the GET routes to a replica. This introduces latency-dependent nondeterminism - the GET may return a stale value. For read-after-write consistency within a batch, use a transaction (atomic batch) or ensure the client uses `Primary` read strategy.

### Batch Retry Strategies (Cluster Non-Atomic Batches)

Two configurable retry behaviors exist for non-atomic cluster pipelines:

- **retryServerError** - retry commands failing with retriable errors (e.g., TRYAGAIN). Caveat: may cause out-of-order execution since retried commands complete later than subsequent ones that succeeded immediately.
- **retryConnectionError** - retry the entire batch on connection failure. Caveat: may cause duplicate executions since the server may have already processed some commands before the connection dropped.

MOVED/ASK redirections are always handled automatically regardless of retry configuration. On MOVED, GLIDE updates its topology map. See [cluster-topology.md](cluster-topology.md) for full redirect handling details.

---

## Read-Only Client Mode (GLIDE 2.3)

GLIDE 2.3 introduced a `read_only` flag in `ConnectionRequest` (protobuf field 26) that creates a client which blocks all write commands at the client level and does not require a primary node to be available. This is useful for connecting to replica-only topologies or building read-only application tiers.

### How It Works

The `read_only` field is defined in the connection request protobuf:

```protobuf
optional bool read_only = 26;
```

When `read_only` is true, the standalone client changes its behavior in several ways:

1. **Skips primary discovery** - the `INFO REPLICATION` check is skipped during connection. The client does not need to identify which node is the primary, so it can connect to a set of replicas without a primary present.

2. **Blocks write commands** - before executing any command, `send_command()` checks if the command is read-only. If `read_only` is true and the command is not a read command, the client immediately returns an error:

   ```
   write commands are not allowed in read-only mode
   ```

3. **Defaults to PreferReplica** - when `read_only` is true and no explicit `ReadFrom` strategy is provided, the client defaults to `PreferReplica` round-robin routing instead of the usual `Primary` default.

4. **Requires at least one connection** - in normal mode, the client requires a primary to be found. In read-only mode, the client only needs at least one successful connection to any node.

### Restrictions

- Read-only mode is not compatible with `AZAffinity` or `AZAffinityReplicasAndPrimary` read strategies. Attempting to combine them produces an `InvalidClientConfig` error: "read-only mode is not compatible with AZAffinity strategies".
- Read-only mode applies to standalone clients only. Cluster clients have their own read routing via the `ReadFrom` strategies.

### Configuration

Set `read_only=True` in the client configuration:

```python
from glide import GlideClientConfiguration, NodeAddress, GlideClient

config = GlideClientConfiguration(
    addresses=[NodeAddress("replica1.example.com", 6379)],
    read_only=True,
)
client = await GlideClient.create(config)

# Read commands work normally
value = await client.get("mykey")

# Write commands are blocked at the client level
# await client.set("mykey", "value")  # Raises error: write commands are not allowed in read-only mode
```

---

## Custom Commands

GLIDE provides a `custom_command()` method on all client types for sending arbitrary Valkey commands that are not covered by the typed API. This uses `RequestType::CustomCommand` (ID 1) in the Rust core, which creates an empty command and passes the user-provided arguments directly to the server.

### Examples

```python
# Python - standalone
result = await client.custom_command(["CLIENT", "INFO"])
# Python - cluster with routing
from glide import AllPrimaries
result = await cluster_client.custom_command(["CLIENT", "LIST"], route=AllPrimaries())
```

```java
// Java
Object result = client.customCommand(new String[]{"CLIENT", "INFO"}).get();
```

```javascript
// Node.js - standalone
const result = await client.customCommand(["CLIENT", "INFO"]);
// Node.js - cluster with routing
const clusterResult = await clusterClient.customCommand(["CLIENT", "LIST"], { route: "allPrimaries" });
```

```go
// Go
result, err := client.CustomCommand(ctx, []string{"CLIENT", "INFO"})
```

Custom commands map to `RequestType::CustomCommand = 1` in `request_type.rs`. Unlike other request types, `CustomCommand` produces an empty `Cmd::new()` - the arguments provided by the caller become the entire command (the first element is the command name itself). Use cases include module commands not in the typed API, new server commands between releases, and administrative commands. For cluster-specific routing behavior, see [cluster-topology.md](cluster-topology.md).
