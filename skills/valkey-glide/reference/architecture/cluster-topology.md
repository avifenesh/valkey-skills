# Cluster Topology Management

Use when understanding how GLIDE discovers cluster topology from seed nodes, routes commands to slots, handles MOVED/ASK redirects, splits multi-slot commands, manages cluster SCAN, configures read-from-replica strategies, or uses transactions in cluster mode.

In cluster mode, GLIDE automatically discovers the full cluster topology from seed nodes, routes commands to the correct shard, handles redirects, and keeps its view of the cluster current through periodic background checks.

---

## Seed Node Connection

When creating a cluster client, GLIDE takes a list of seed node addresses from the `ConnectionRequest.addresses` field. The `create_cluster_client()` function (in `client/mod.rs`) converts these into `redis::ConnectionInfo` objects and passes them to the cluster client builder:

```rust
let initial_nodes: Vec<_> = request
    .addresses
    .into_iter()
    .map(|address| {
        get_connection_info(&address, tls_mode, valkey_connection_info.clone(), tls_params.clone())
    })
    .collect();

let mut builder = redis::cluster::ClusterClientBuilder::new(initial_nodes)
    .connection_timeout(connection_timeout)
    .retries(DEFAULT_RETRIES);
```

The `DEFAULT_RETRIES` constant is 3:

```rust
pub const DEFAULT_RETRIES: u32 = 3;
```

This controls how many times the cluster client retries a command after receiving MOVED or ASK redirects before giving up.

---

## Topology Discovery

After connecting to the seed nodes, the underlying `redis` crate's cluster module queries the topology using `CLUSTER SLOTS` or `CLUSTER SHARDS`. GLIDE uses a consensus-based approach:

1. Multiple seed nodes are queried for their view of the cluster topology
2. The view with the highest agreement across nodes is selected
3. This prevents a single stale or partitioned node from corrupting the client's routing table

The `refresh_topology_from_initial_nodes` field in `ConnectionRequest` controls whether topology refreshes go back to the original seed nodes or use the discovered nodes. When set to `true`, topology refreshes always query the initial seed nodes - useful when seed nodes are behind a load balancer or service discovery endpoint.

---

## Proactive Background Monitoring

GLIDE runs periodic background checks to detect topology changes before they cause command failures.

### Periodic Topology Checks

The default check interval is 60 seconds:

```rust
pub const DEFAULT_PERIODIC_TOPOLOGY_CHECKS_INTERVAL: Duration = Duration::from_secs(60);
```

Configuration via the `periodic_checks` field:

```rust
pub enum PeriodicCheck {
    Enabled,                        // Use DEFAULT_PERIODIC_TOPOLOGY_CHECKS_INTERVAL (60s)
    Disabled,                       // No periodic checks
    ManualInterval(Duration),       // Custom interval
}
```

In the cluster client builder:

```rust
let periodic_topology_checks = match request.periodic_checks {
    Some(PeriodicCheck::Disabled) => None,
    Some(PeriodicCheck::Enabled) => Some(DEFAULT_PERIODIC_TOPOLOGY_CHECKS_INTERVAL),
    Some(PeriodicCheck::ManualInterval(interval)) => Some(interval),
    None => Some(DEFAULT_PERIODIC_TOPOLOGY_CHECKS_INTERVAL),
};

if let Some(interval_duration) = periodic_topology_checks {
    builder = builder.periodic_topology_checks(interval_duration);
}
```

When `periodic_checks` is not set, the default behavior is enabled with the 60-second interval. This means topology checks are on by default - you must explicitly disable them.

### Periodic Connection Checks

Separately from topology, GLIDE also monitors individual connection health. The cluster client always enables connection checks with a 3-second interval (`CONNECTION_CHECKS_INTERVAL`). This detects dropped connections and triggers reconnection before the next command fails. For the full connection health check details (standalone heartbeat, disconnect monitoring, reconnection flow), see [connection-model.md](connection-model.md).

---

## MOVED and ASK Redirect Handling

When the cluster topology changes (slots migrate between nodes), the server responds to commands with redirect errors:

- **MOVED** - the slot has permanently moved to a different node. The client should update its routing table and resend the command.
- **ASK** - the slot is being migrated. The client should send an ASKING command to the target node, then resend the original command to that node, but should not update its routing table.

GLIDE handles both redirects transparently within the `redis` crate's cluster connection layer. The `retries` parameter (default 3) limits how many redirect hops a single command will follow before returning an error.

The cluster client's `route_command` method handles routing:

```rust
ClientWrapper::Cluster { mut client } => {
    let final_routing = routing
        .or_else(|| RoutingInfo::for_routable(cmd.as_ref()))
        .unwrap_or(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random));
    client.route_command(&cmd, final_routing).await
}
```

If no explicit routing is provided, GLIDE determines routing from the command's key(s) using `RoutingInfo::for_routable()`. Commands without keys default to `SingleNodeRoutingInfo::Random`.

### Write Command Safety

When a user specifies `Random` routing for a writable command, GLIDE automatically upgrades it to `RandomPrimary` to prevent accidental writes to replicas:

```rust
if let Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random)) = routing {
    if redis::cluster_routing::is_readonly_cmd(cmd_name.as_bytes()) {
        RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random)
    } else {
        // Change to RandomPrimary for write commands
        RoutingInfo::SingleNode(SingleNodeRoutingInfo::RandomPrimary)
    }
}
```

---

## Multi-Slot Command Splitting

Several commands accept multiple keys that may reside on different slots. In cluster mode, these commands are automatically split into per-slot sub-commands, dispatched to the correct nodes in parallel, and reassembled into a single response.

The multi-slot commands handled by the `redis` crate's cluster routing layer:

| Command | Behavior |
|---------|----------|
| MGET | Split by key slot, results reassembled in original key order |
| MSET | Split by key-value pairs per slot |
| DEL | Split by key slot, results summed |
| UNLINK | Split by key slot, results summed |
| EXISTS | Split by key slot, results summed |
| TOUCH | Split by key slot, results summed |
| WATCH | Split by key slot, sent to each relevant node |
| JSON.MGET | Split by key slot, results reassembled in original key order |

### Ordering Caveat During Slot Migration

During slot migration, multi-key commands within a non-atomic batch can experience reordering. When a slot is migrating, both a multi-key command (e.g., MGET) and a single-key command (e.g., SET) targeting that slot receive ASK redirections. Upon ASK redirection, the multi-key command may return a TRYAGAIN error (triggering a retry), while the single-key SET succeeds immediately on the target node. This results in unintended command reordering - the SET completes before the MGET, even though MGET was issued first.

The routing is determined by the `RoutingInfo` and `MultipleNodeRoutingInfo` types from `redis::cluster_routing`. Commands that return counts (DEL, UNLINK, EXISTS, TOUCH) have their per-node results aggregated. Commands that return per-key values (MGET) have their results merged back in the correct order.

### Routing Types

```rust
pub enum RoutingInfo {
    SingleNode(SingleNodeRoutingInfo),
    MultiNode((MultipleNodeRoutingInfo, Option<ResponsePolicy>)),
}

pub enum SingleNodeRoutingInfo {
    Random,
    RandomPrimary,
    SpecificNode(Route),
    ByAddress { host: String, port: u16 },
    // ...
}
```

The `ResponsePolicy` enum determines how multi-node responses are combined:

- **CombineArrays** - merge arrays (MGET)
- **Aggregate(AggregateOp)** - sum, min, or max (DEL, EXISTS, etc.)
- **AllSucceeded** - require all nodes to succeed (MSET)
- **OneSucceeded** - at least one node must succeed
- **Special** - command-specific handling

---

## Cluster SCAN

Cluster SCAN is a special command that iterates across all nodes in the cluster. It cannot be sent as a regular command because the cursor must track state across multiple nodes.

GLIDE handles this through the `cluster_scan_container.rs` module:

```rust
static CONTAINER: Lazy<Mutex<HashMap<String, ScanStateRC>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
```

The flow:

1. `Client::cluster_scan()` calls `ClusterConnection::cluster_scan()` on the redis crate's cluster connection
2. The redis crate internally iterates nodes, maintaining a `ScanStateRC` (reference-counted scan state)
3. If the scan is not finished, the `ScanStateRC` is stored in the global `CONTAINER` with a nanoid-generated ID
4. The ID is returned to the language wrapper as a string cursor
5. On the next iteration, the wrapper passes the cursor ID back, which is resolved via `get_cluster_scan_cursor()`
6. When the scan completes, the cursor value is the constant `"finished"` (`FINISHED_SCAN_CURSOR`)
7. The wrapper's cursor object triggers `remove_scan_state_cursor()` on drop, cleaning up the container

This design prevents Rust from dropping the scan state when the cursor crosses the FFI boundary, since the reference-counted state is held in the global container until explicitly removed.

---

## Read From Replica Strategies

GLIDE supports multiple read routing strategies for cluster mode. For per-language configuration, setup instructions, and cost analysis, see [az-affinity](../features/az-affinity.md).

```rust
pub enum ReadFrom {
    Primary,
    PreferReplica,
    AZAffinity(String),
    AZAffinityReplicasAndPrimary(String),
}
```

These map to the redis crate's `ReadFromReplicaStrategy`:

| GLIDE ReadFrom | Strategy | Behavior |
|----------------|----------|----------|
| `Primary` | `AlwaysFromPrimary` | All reads go to primaries |
| `PreferReplica` | `RoundRobin` | Round-robin across replicas, fall back to primary if none available |
| `AZAffinity(az)` | `AZAffinity` | Prefer replicas in the specified availability zone |
| `AZAffinityReplicasAndPrimary(az)` | `AZAffinityReplicasAndPrimary` | Prefer replicas and primary in the specified AZ |

The AZ affinity strategies require Valkey 8.0+ (or ElastiCache for Valkey 7.2+) which supports the `CLIENT INFO` response including AZ information. When AZ info cannot be determined, the client falls back to `PreferReplica`. On managed services like ElastiCache, the AZ mapping is configured automatically. For self-hosted deployments, each node must have its `availability-zone` set via `CONFIG SET`.

### AZ Affinity: Quantified Cost and Latency Impact

Cross-AZ data transfer on AWS costs $0.01/GB. For a cluster with 2 shards (1 primary + 2 replicas each) on m7g.xlarge instances processing 250MB/s of read traffic where 50% crosses AZs, the monthly cross-AZ data transfer cost is approximately $3,285. With AZ affinity routing keeping all traffic within the same AZ, the total cost drops from $4,373 to $1,088.

Cross-AZ distance in AWS is typically up to 60 miles (100km), adding 500us to 1000us roundtrip latency. With AZ affinity, latency drops from approximately 800us to 300us in benchmarks from the Valkey blog.

At the time of writing, GLIDE is the only Valkey client library supporting the AZ Affinity strategies.

In standalone mode, the read routing works similarly. The `StandaloneClient` uses `round_robin_read_from_replica()` to distribute read commands:

```rust
fn round_robin_read_from_replica(
    &self,
    latest_read_replica_index: &Arc<AtomicUsize>,
) -> &ReconnectingConnection {
    let initial_index = latest_read_replica_index.load(Ordering::Relaxed);
    let mut check_count = 0;
    loop {
        check_count += 1;
        if check_count > self.inner.nodes.len() {
            return self.get_primary_connection(); // Fallback
        }
        let index = (initial_index + check_count) % self.inner.nodes.len();
        if index == self.inner.primary_index { continue; }
        // ... check if connected, return if so
    }
}
```

---

## Topology-Related Configuration Summary

| Parameter | Default | Protobuf Field | Description |
|-----------|---------|----------------|-------------|
| `periodic_checks` | Enabled (60s) | `periodic_checks_manual_interval` / `periodic_checks_disabled` | Topology refresh interval |
| `refresh_topology_from_initial_nodes` | false | `refresh_topology_from_initial_nodes` (field 18) | Always use seed nodes for refresh |
| `read_from` | Primary | `read_from` (field 5) | Read routing strategy |
| `client_az` | none | `client_az` (field 15) | Client availability zone for AZ-aware routing |
| `connection_retry_strategy` | system default | `connection_retry_strategy` (field 6) | Backoff for connection retries (see [connection-model.md](connection-model.md)) |
| `connection_timeout` | 2000ms | `connection_timeout` (field 16) | Per-connection establishment timeout (see [connection-model.md](connection-model.md)) |

---

## Error Handling in Cluster Mode

### Command-Level Errors

When a command fails in cluster mode, the error may be:

- **Redirect** (MOVED/ASK) - handled transparently, retried up to `DEFAULT_RETRIES` (3) times
- **Connection error** - triggers reconnection to the affected node; command may be retried
- **Timeout** - controlled by `request_timeout` (default 250ms, see [connection-model.md](connection-model.md)), recorded in OTel metrics
- **Application error** - returned directly to the caller (WRONGTYPE, etc.)

### Sharded PubSub Version Check

When sharded PubSub subscriptions are configured, GLIDE validates the server version at client creation time, rejecting connections to engines older than 7.0 with `"Sharded subscriptions provided, but the engine version is < 7.0"`. This explicit check prevents silent subscription failures. For the full PubSub subscription model, synchronizer architecture, and dynamic subscribe/unsubscribe, see [pubsub](../features/pubsub.md).

---

## Transactions in Cluster Mode

Transactions (MULTI/EXEC) in cluster mode require all key-based commands to route to the same slot. The pipeline is sent as a unit to a single node. Atomic transactions cannot be split across nodes - if keys span multiple slots, the transaction will fail. Non-atomic batches (pipelines) can use `PipelineRetryStrategy` to retry individual commands on redirect. See the "Batch Retry Strategies" section in [connection-model.md](connection-model.md) for retry behavior details.

---

## Multi-Database Support in Cluster Mode (Valkey 9.0)

Historically, Valkey cluster mode was restricted to database 0. Valkey 9.0 lifts this restriction, and GLIDE 2.1 added client support across all language wrappers.

### What Changed

In GLIDE 2.1 (CHANGELOG: "Add Multi-Database Support for Cluster Mode Valkey 9.0"), the following commands were moved from standalone-only to shared base client implementations, making them available on both standalone and cluster clients:

- **SELECT** - switch the active database. Previously standalone-only; moved to `CoreCommands` (Python), `BaseClient` (Node.js, Java), and `ClusterClient` (Go) in GLIDE 2.1.1.
- **COPY** - copy a key to another key, optionally across databases. The `DB` destination option is now available in cluster mode. Moved to base client in GLIDE 2.1.1.
- **MOVE** - move a key to another database. Cluster support added in GLIDE 2.1.1 across all wrappers.

### Database Persistence Across Reconnections

When `SELECT` is used in cluster mode, GLIDE persists the selected database ID and restores it automatically on reconnection. This was fixed in GLIDE 2.1.1 (CORE: "Fix SELECT Command Database Persistence Across Reconnections").

### Requirements

- Valkey server 9.0 or later
- GLIDE 2.1+
- The cluster must be configured to allow multiple databases (server-side configuration)

### Usage

Database selection works identically to standalone mode:

```python
# Python - cluster client
await cluster_client.select(4)
await cluster_client.copy("src_key", "dst_key", destination_db=2)
await cluster_client.move("mykey", 3)
```

```javascript
// Node.js - cluster client
await clusterClient.select(4);
await clusterClient.copy("src_key", "dst_key", { destinationDB: 2 });
await clusterClient.move("mykey", 3);
```

---

## Custom Commands in Cluster Mode

For the full custom commands reference (method signatures, examples, use cases), see the Custom Commands section in [connection-model.md](connection-model.md).

Cluster-specific behavior:

- Routing is determined by the command's first key argument, or defaults to a random node if no key is present
- Write safety still applies - if routing resolves to `Random`, GLIDE upgrades to `RandomPrimary` for non-read-only commands (see "Write Command Safety" above)
- Cluster clients accept an optional `route` parameter to target specific nodes (e.g., `AllPrimaries`, `RandomNode`)
- Custom commands are fully supported in batches/transactions via the batch `custom_command` method
