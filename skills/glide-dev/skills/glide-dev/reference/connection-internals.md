# Connection Model Internals

Use when working on GLIDE's single-connection-per-node design, multiplexing, inflight request limiting, request/connection timeouts, reconnection backoff, lazy connection, periodic health checks, or read-only mode.

## Contents

- Single Multiplexed Connection (line 19)
- Inflight Request Limiting (line 36)
- Request Timeout (line 48)
- Connection Timeout (line 54)
- Reconnection with Exponential Backoff (line 58)
- Periodic Connection Checks (line 75)
- Connection State Preservation (line 85)
- When to Create Separate Client Instances (line 97)
- Batch Retry Strategies (Cluster Non-Atomic) (line 106)
- Read-Only Mode (GLIDE 2.3) (line 113)
- Custom Commands (line 123)

## Single Multiplexed Connection

GLIDE uses one `MultiplexedConnection` per node - not a connection pool. All requests pipeline through this connection via Valkey's built-in pipelining protocol. The connection is wrapped in `ReconnectingConnection` (`client/reconnecting_connection.rs`):

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

## Inflight Request Limiting

Default limit is 1000 concurrent inflight requests per client:

```rust
pub const DEFAULT_MAX_INFLIGHT_REQUESTS: u32 = 1000;
```

The 1000 value is 20x the theoretical minimum for 50K req/s at 1ms latency (Little's Law). The `Client` struct holds `inflight_requests_allowed: Arc<AtomicIsize>`. Before each command, `reserve_inflight_request()` atomically decrements; `InflightRequestTracker` increments on drop. If no slots available, returns error: `"Reached maximum inflight requests"`.

GLIDE logs inflight usage at debug level at 10% threshold intervals (`inflight_limit / 10`).

## Request Timeout

Default: 250ms (`DEFAULT_RESPONSE_TIMEOUT`).

Blocking commands (BLPOP, BRPOP, BLMOVE, BZPOPMAX, etc.) get special treatment - GLIDE parses their timeout argument and extends the request timeout by 0.5 seconds. A timeout of 0 (block forever) disables request timeout for that command.

## Connection Timeout

Default: 2000ms (`DEFAULT_CONNECTION_TIMEOUT`). Client creation adds 500ms buffer on top.

## Reconnection with Exponential Backoff

On disconnect:
1. State transitions from `Connected` to `Reconnecting`
2. `connection_available_signal` (ManualResetEvent) is reset - callers block
3. Background task spawned for reconnection

Retry uses infinite backoff duration iterator from `RetryStrategy`. Each attempt verified with PING before accepting. Reconnection continues until success or client drop.

### Permanent vs Transient Errors

During initial connection, these errors are never retried:
- `AuthenticationFailed`
- `InvalidClientConfig`
- `RESP3NotSupported`
- Messages containing `NOAUTH` or `WRONGPASS`

## Periodic Connection Checks

### Standalone Mode

3-second interval (`CONNECTION_CHECKS_INTERVAL`). Passive monitoring via disconnect notifier, not PING. Optional active heartbeat behind `standalone_heartbeat` feature flag (1-second PING interval).

### Cluster Mode

Always enabled with 3-second interval via `builder.periodic_connections_checks()`.

## Connection State Preservation

Properties tracked and restored on reconnection:

| Property | Method | Updated By |
|----------|--------|------------|
| Database ID | `update_connection_database()` | SELECT |
| Password | `update_connection_password()` | AUTH, IAM refresh |
| Username | `update_connection_username()` | AUTH |
| Client name | `update_connection_client_name()` | CLIENT SETNAME |
| Protocol version | `update_connection_protocol()` | HELLO |

## When to Create Separate Client Instances

A single multiplexed connection cannot isolate state. Separate clients needed for:
- Blocking commands (BLPOP, BRPOP, etc.) - occupy the connection
- WATCH/MULTI/EXEC - optimistic locking requires isolated connection
- Large value transfers - delays other requests
- Database isolation - SELECT is per-connection
- Different ReadFrom strategies - locked at creation time

## Batch Retry Strategies (Cluster Non-Atomic)

- **retryServerError** - retry commands failing with retriable errors (e.g., TRYAGAIN). May cause out-of-order execution.
- **retryConnectionError** - retry entire batch on connection failure. May cause duplicate executions.

MOVED/ASK redirections always handled automatically regardless of retry config.

## Read-Only Mode (GLIDE 2.3)

`read_only` flag in `ConnectionRequest` (protobuf field 26):
1. Skips primary discovery - connects to replicas without requiring primary
2. Blocks write commands at client level
3. Defaults to `PreferReplica` if no explicit `ReadFrom`
4. Requires at least one successful connection to any node

Not compatible with `AZAffinity` or `AZAffinityReplicasAndPrimary` strategies.

## Custom Commands

`custom_command()` uses `RequestType::CustomCommand` (ID 1) - creates empty `Cmd::new()`, caller's arguments become the entire command. First element is the command name.
