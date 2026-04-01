# gRPC Coordinator

Use when working on cluster-mode search fanout, the gRPC service layer, metadata synchronization between shards, or the coordinator port configuration.

Source: `src/coordinator/coordinator.proto`, `src/coordinator/server.h`, `server.cc`, `client.h`, `client.cc`, `client_pool.h`, `metadata_manager.h`, `metadata_manager.cc`, `util.h`, `grpc_suspender.h`

## Contents

- gRPC Service Definition (line 22)
- Port Offset and Address Resolution (line 45)
- Server Implementation (line 66)
- Client Implementation (line 86)
- Client Pool (line 102)
- MetadataManager Overview (line 108)
- Fingerprinting with HighwayHash (line 127)
- Cluster Bus Broadcast (line 143)
- Reconciliation Protocol (line 153)
- Staging During Replication (line 175)
- use-coordinator Config (line 188)
- gRPC Suspension Guard (line 194)

## gRPC Service Definition

The `Coordinator` service in `coordinator.proto` defines three RPCs:

```protobuf
service Coordinator {
  rpc GetGlobalMetadata(GetGlobalMetadataRequest)
      returns (GetGlobalMetadataResponse) {}
  rpc SearchIndexPartition(SearchIndexPartitionRequest)
      returns (SearchIndexPartitionResponse) {}
  rpc InfoIndexPartition(InfoIndexPartitionRequest)
      returns (InfoIndexPartitionResponse) {}
}
```

**GetGlobalMetadata** - Returns the full `GlobalMetadata` protobuf from the local node. Called during reconciliation when a remote node detects a fingerprint or version mismatch. The request is empty; the response contains the entire metadata tree.

**SearchIndexPartition** - Fans out a vector or hybrid search to a remote shard. The request carries the index name, query bytes, filter predicates, LIMIT/SORTBY parameters, K/EF for vector search, timeout, and consistency flags. The response returns scored `NeighborEntry` results with optional attribute contents.

**InfoIndexPartition** - Fans out `FT.INFO` to a remote shard. The response includes doc counts, record counts, backfill progress, mutation queue size, per-attribute memory, and indexing failures. The `FanoutErrorType` enum distinguishes OK, INDEX_NAME_ERROR, INCONSISTENT_STATE_ERROR, and COMMUNICATION_ERROR.

Both SearchIndexPartition and InfoIndexPartition carry an `IndexFingerprintVersion` for consistency checks. If `enable_consistency` or `require_consistency` is set, the server also checks slot fingerprints against the cached cluster map.

## Port Offset and Address Resolution

Defined in `src/coordinator/util.h`:

```cpp
static constexpr int kCoordinatorPortOffset = 20294;
```

The gRPC port is computed as `valkey_port + 20294`. For the default Valkey port 6379, this yields **26673** - which spells COORD on a telephone keypad. A special case handles TLS port 6378, adding an extra +1 to avoid collision.

```cpp
inline int GetCoordinatorPort(int valkey_port) {
  if (valkey_port == 6378) {
    return valkey_port + kCoordinatorPortOffset + 1;
  }
  return valkey_port + kCoordinatorPortOffset;
}
```

When a cluster bus message arrives from a remote node, `HandleBroadcastedMetadata` resolves the sender's IP via `ValkeyModule_GetClusterNodeInfo` and constructs the gRPC address as `ip:GetCoordinatorPort(node_port)`.

## Server Implementation

`coordinator::ServerImpl` wraps the gRPC C++ async server. `ServerImpl::Create` binds to `[::]:<port>` with insecure credentials.

Channel arguments for performance:
- `GRPC_ARG_ALLOW_REUSEPORT = 1` - enables SO_REUSEADDR
- `GRPC_ARG_MINIMAL_STACK = 1` - reduces per-connection overhead
- `GRPC_ARG_OPTIMIZATION_TARGET = "latency"` - latency-optimized transport
- `GRPC_ARG_TCP_TX_ZEROCOPY_ENABLED = 1` - zero-copy sends

If the initial bind fails, the server retries up to 10 times with increasing backoff (100ms * attempt), running `lsof` diagnostics on each failure to log what process holds the port.

`coordinator::Service` implements the three RPCs as `CallbackService` methods:

- **GetGlobalMetadata** - Acquires a `GRPCSuspensionGuard`, then dispatches to the main thread via `vmsdk::RunByMain` to read metadata. Returns the full `GlobalMetadata` protobuf.

- **SearchIndexPartition** - Converts the gRPC request to internal `SearchParameters` via `GRPCSearchRequestToParameters`, performs index and optional slot consistency checks, then enqueues the search on the reader thread pool via `query::SearchAsync` in `kRemote` mode. Results are serialized back into `NeighborEntry` messages. A `RemoteResponderSearch` subclass handles completion callbacks.

- **InfoIndexPartition** - Dispatches to the main thread, calls `GenerateInfoResponse` which looks up the IndexSchema locally, performs consistency checks, and populates the response with doc counts, backfill status, mutation queue size, and per-attribute stats.

## Client Implementation

`coordinator::ClientImpl` wraps a gRPC stub with retry and timeout policies.

The retry policy (defined as JSON service config):
- Max 5 attempts
- Initial backoff 100ms, max 1s, multiplier 1.0
- Retryable codes: UNAVAILABLE, UNKNOWN, RESOURCE_EXHAUSTED, INTERNAL, DATA_LOSS, NOT_FOUND

Timeouts:
- `GetGlobalMetadata` - 60 seconds
- `SearchIndexPartition` - configurable via `coordinator-query-timeout-secs` (default 25s, range 1-3600s)
- `InfoIndexPartition` - configurable via `ft-info-rpc-timeout-ms` (default 2500ms)

All RPCs are async. Each allocates a heap struct containing the context, request, response, callback, and latency sample. The callback fires on a gRPC background thread, acquires a `GRPCSuspensionGuard`, invokes the user callback, and records success/failure metrics plus latency samples. Byte counts for requests and responses are tracked in `coordinator_bytes_out` and `coordinator_bytes_in`.

## Client Pool

`coordinator::ClientPool` caches gRPC clients by address in a mutex-protected `flat_hash_map`. On first access to a given address, `ClientImpl::MakeInsecureClient` creates a channel with shared channel arguments (retry policy, minimal stack, latency optimization, zero-copy). Subsequent calls return the cached client.

Each client holds its own detached thread-safe context cloned from the pool's context. The pool is owned by `ValkeySearch` and shared with `MetadataManager`.

## MetadataManager Overview

`coordinator::MetadataManager` is a singleton managing cluster-wide metadata consistency. It maintains:

- `metadata_` - the local `GlobalMetadata` protobuf (main-thread guarded)
- `staged_metadata_` - temporary storage during replication loads
- `registered_types_` - map of type names to callbacks (fingerprint, update, min_version)
- `client_pool_` - reference to the shared gRPC client pool

The manager registers itself for `RDB_SECTION_GLOBAL_METADATA` load/save callbacks during construction. Type registration via `RegisterType` provides:
- A `FingerprintCallback` for computing entry fingerprints
- A `MetadataUpdateCallback` invoked when entries are created, modified, or deleted
- A `MinVersionCallback` to determine minimum module version requirements

Entry lifecycle:
- `CreateEntry` - computes fingerprint, triggers callbacks, updates the local metadata tree, increments the version, recomputes the top-level fingerprint, replicates via `FT.INTERNAL_UPDATE`, and broadcasts via cluster bus
- `DeleteEntry` - sets a tombstone (entry with no content, incremented version), then replicates and broadcasts
- `GetGlobalMetadata` - returns a deep copy of the local metadata

## Fingerprinting with HighwayHash

Metadata integrity uses HighwayHash (Google's SIMD-accelerated hash) for deterministic fingerprinting. The hash key is a fixed 256-bit constant:

```cpp
static constexpr highwayhash::HHKey kHashKey{
    0x9736bad976c904ea, 0x08f963a1a52eece9,
    0x1ea3f3f773f3b510, 0x9290a6b4e4db3d51};
```

**Per-entry fingerprints** are computed by the registered `FingerprintCallback`, which serializes the protobuf `Any` content and hashes it. This depends on the encoding version - different module versions may produce different fingerprints.

**Top-level fingerprint** (`ComputeTopLevelFingerprint`) summarizes the entire metadata tree. It creates a `ChildMetadataEntry` struct per entry containing the HighwayHash of the type name, HighwayHash of the ID, version, and fingerprint. These are sorted deterministically (by type name hash, then ID hash) and hashed as a contiguous byte array.

This two-level scheme enables quick equality checks: if top-level fingerprints match, the metadata is identical. If they diverge, the full `GetGlobalMetadata` RPC is triggered to identify specific differences.

## Cluster Bus Broadcast

Metadata changes propagate via Valkey's cluster bus, not gRPC. `BroadcastMetadata` serializes the `GlobalMetadataVersionHeader` (containing `top_level_fingerprint`, `top_level_version`, `top_level_min_version`) and sends it with `ValkeyModule_SendClusterMessage` using receiver ID `0x00`.

The broadcast is lightweight - only the version header, not the full metadata. Recipients compare versions and fingerprints to decide whether to fetch the full metadata via gRPC.

A periodic timer fires every ~30 seconds (with +/-25% jitter) via `MetadataManagerSendMetadataBroadcast` to ensure convergence even if point-to-point messages are lost. The timer is started on the first server cron tick after the first `FT.CREATE`.

Registration: `RegisterForClusterMessages` subscribes `MetadataManagerOnClusterMessageCallback` for message type `0x00`.

## Reconciliation Protocol

When `HandleBroadcastedMetadata` receives a version header from a remote node:

1. **Skip if loading** - metadata updates are paused during RDB/AOF loading
2. **Skip if replica** - only primaries process metadata broadcasts
3. **Version check** - if the proposed version is less than local, ignore it
4. **Fingerprint comparison** - if versions match but fingerprints differ, or if the proposed version is higher, fetch the full metadata via `GetGlobalMetadata` gRPC RPC from the sender
5. **Merge** - `ReconcileMetadata` merges the remote metadata into the local copy

The merge algorithm in `ReconcileMetadata`:
- For each entry in the proposed metadata, compare with the existing entry
- Skip if the proposed version is lower
- At equal versions, prefer higher `encoding_version` (newer module features win)
- At equal versions and encoding versions, use fingerprint as a tiebreaker (higher fingerprint wins)
- Re-fingerprint entries if the encoding version is lower than the local version (unstable fingerprints across module versions)
- Trigger registered callbacks for each accepted change
- Call `CallFTInternalUpdateForReconciliation` to replicate accepted changes
- Recompute the top-level fingerprint and version; broadcast if the fingerprint changed

Health tracking: `last_healthy_metadata_millis_` records the timestamp of the last successful reconciliation. `metadata_reconciliation_completed_count_` increments on each success.

## Staging During Replication

During replica RDB loads, metadata is staged rather than applied immediately:

- `OnReplicationLoadStart` sets `staging_metadata_due_to_repl_load_ = true`
- `LoadMetadata` writes to `staged_metadata_` instead of `metadata_`
- `OnLoadingEnded` clears the local metadata and reconciles from the staged copy with `prefer_incoming = true` and `trigger_callbacks = false`
- After applying, the staged metadata is cleared

This prevents partial metadata from being visible during the load and ensures the replica's metadata is a consistent snapshot from the primary.

For non-replication loads (e.g., restart from RDB), `LoadMetadata` merges directly into `metadata_` via `ReconcileMetadata`.

## use-coordinator Config

The `use-coordinator` boolean config (exposed via `options::GetUseCoordinator()`) controls whether the coordinator layer is active. When enabled, `ValkeySearch::InitCoordinator` starts the gRPC server, creates the client pool, initializes the `MetadataManager`, and registers for cluster messages and server cron events.

When disabled, the module operates in standalone or basic cluster mode without gRPC fanout. Search and info commands execute only against the local shard.

## gRPC Suspension Guard

`GRPCSuspender` and `GRPCSuspensionGuard` prevent gRPC callbacks from accessing shared mutexes during `fork()` (used by Valkey for BGSAVE/BGREWRITEAOF).

- `GRPCSuspender::Suspend()` - blocks until all in-flight gRPC callbacks complete, then prevents new ones from starting
- `GRPCSuspender::Resume()` - releases suspended callbacks
- `GRPCSuspensionGuard` - RAII guard acquired at the start of every gRPC callback; increments count on construction, decrements on destruction

The suspender uses `absl::Mutex` with two condition variables: one for waiting until in-flight tasks drain, another for blocked callbacks waiting to resume. The singleton uses `absl::NoDestructor` to avoid destruction races with gRPC event engine threads at process exit.

## See Also

- [replication.md](replication.md) - RDB serialization and FT.INTERNAL_UPDATE
- [metrics.md](metrics.md) - coordinator metrics tracking
- [../architecture/module-overview.md](../architecture/module-overview.md) - overall module architecture
- [../architecture/thread-model.md](../architecture/thread-model.md) - thread model and fork suspension
- [../architecture/schema-manager.md](../architecture/schema-manager.md) - SchemaManager and index CRUD
- [../query/execution.md](../query/execution.md) - search execution flow and cluster fanout dispatch
- [../query/ft-search.md](../query/ft-search.md) - FT.SEARCH command handling (SearchMode::kRemote)
