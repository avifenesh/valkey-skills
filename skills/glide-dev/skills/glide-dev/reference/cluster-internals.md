# Cluster Topology Internals

Use when working on cluster slot mapping, failover handling, MOVED/ASK redirect logic, or topology refresh.

## Cluster is its own client, not a pool

Cluster and standalone are two different implementations in `glide-core/src/client/`. `ClientWrapper::Cluster` holds a `redis::cluster_async::ClusterConnection` (from the vendored `glide-core/redis-rs/` tree); `ClientWrapper::Standalone` holds GLIDE's own `StandaloneClient`. They do not share a code path. Do not describe cluster as "a pool of standalone clients" - that's a common but wrong mental model.

## Slot Map

`redis::cluster_slotmap::SlotMap` from the vendored redis-rs tracks which node owns which slot range (0-16383). It refreshes:

1. On initial connection (slot map built from `CLUSTER SLOTS` / `CLUSTER SHARDS`)
2. On `MOVED` redirect (stale slot mapping)
3. On `ASK` redirect (slot migration in progress - single-use, does NOT update the map)
4. Periodically via `periodic_topology_checks` (configured in `ConnectionRequest`; default interval `DEFAULT_PERIODIC_TOPOLOGY_CHECKS_INTERVAL = 60s` in `client/mod.rs`)

## MOVED vs ASK

- **MOVED**: slot permanently moved. Update slot map, retry on new node.
- **ASK**: slot mid-migration. Send `ASKING` + command to the indicated node. One-shot: the next command for the same slot still goes to the original owner until MOVED.

## Topology refresh

`CLUSTER SLOTS` (older) or `CLUSTER SHARDS` (Valkey 7.0+). Flow:

1. Fetch topology.
2. Build new `SlotMap`.
3. Diff against current node set - open connections to new nodes, close connections to removed nodes.
4. Trigger PubSub resynchronization for affected slots (see `pubsub-internals.md`).

Refresh path is in vendored `redis::cluster_async`; GLIDE adds the hook for PubSub resync via `PubSubSynchronizer::handle_topology_refresh(&SlotMap)` in `glide-core/src/pubsub/synchronizer.rs`.

## Routing decisions

Routing lives in vendored `redis::cluster_routing` (imported in `client/mod.rs` as `MultipleNodeRoutingInfo`, `ResponsePolicy`, `Routable`, `RoutingInfo`, `SingleNodeRoutingInfo`). It is NOT in `request_type.rs` - that file is only a command-name → `RequestType` enum with no routing logic.

Categories:

- **Single slot**: route to the node owning the slot of the command's key.
- **All primaries**: broadcast (FLUSHALL, DBSIZE, CONFIG SET).
- **All nodes**: broadcast to all primaries and replicas (PING via cluster, some diagnostics).
- **Random node**: pick any primary.
- **Response policy** determines how to aggregate multi-node responses: combine arrays, sum counts, take first value, all-succeeded-or-error.

Multi-key commands on the same cluster must target one slot (hash tags: `{same-slot}:key1`, `{same-slot}:key2`). Cross-slot multi-key is split and dispatched by GLIDE when the command allows it (e.g., MGET/MSET in cluster mode).

## Read-from-replica

`redis::cluster_slotmap::ReadFromReplicaStrategy` (imported in `client/mod.rs`). Configured via `ConnectionRequest::read_from`. Strategies include primary-preferred and AZ-affinity; the actual enum variants live in the vendored redis-rs.

## Connection lifecycle

Per-node connections are held by `ClusterConnection` (vendored). Reconnection, heartbeat, and IAM-token refresh are driven by GLIDE code in `reconnecting_connection.rs`:

- `HEARTBEAT_SLEEP_DURATION = 1s`
- `CONNECTION_CHECKS_INTERVAL = 3s` (not user-exposed; per source comment, improper tuning affects PubSub resiliency)
- `DEFAULT_RETRIES = 3`, `DEFAULT_RESPONSE_TIMEOUT = 250ms`, `DEFAULT_MAX_INFLIGHT_REQUESTS = 1000` (all in `client/mod.rs`)

There is no min/max "pool size" - per-node links are the multiplexed connection managed by `ReconnectingConnection`.
