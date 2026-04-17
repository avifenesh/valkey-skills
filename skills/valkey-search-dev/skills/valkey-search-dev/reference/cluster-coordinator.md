# gRPC coordinator

Use when reasoning about cluster-mode fanout, the gRPC service, metadata sync, or the coordinator port.

Source: `src/coordinator/coordinator.proto`, `server.{h,cc}`, `client.{h,cc}`, `client_pool.h`, `metadata_manager.{h,cc}`, `util.h`, `grpc_suspender.h`.

## gRPC service (`coordinator.proto`)

```protobuf
service Coordinator {
  rpc GetGlobalMetadata   (GetGlobalMetadataRequest)   returns (GetGlobalMetadataResponse);
  rpc SearchIndexPartition(SearchIndexPartitionRequest)returns (SearchIndexPartitionResponse);
  rpc InfoIndexPartition  (InfoIndexPartitionRequest)  returns (InfoIndexPartitionResponse);
}
```

- **GetGlobalMetadata** - full `GlobalMetadata` from the local node. Fetched during reconciliation when fingerprint / version mismatches.
- **SearchIndexPartition** - vector / hybrid search fanout. Request: index name, query bytes, filter, LIMIT/SORTBY, K/EF, timeout, consistency flags. Response: `NeighborEntry`s with optional content.
- **InfoIndexPartition** - FT.INFO fanout. Doc/record counts, backfill, mutation queue, per-attribute memory, failures. `FanoutErrorType` enum: `OK`, `INDEX_NAME_ERROR`, `INCONSISTENT_STATE_ERROR`, `COMMUNICATION_ERROR`.

Both Search and Info RPCs carry `IndexFingerprintVersion` for consistency. Under `enable_consistency` / `require_consistency` the server also checks slot fingerprints against the cached cluster map.

## Port resolution (`util.h`)

```cpp
static constexpr int kCoordinatorPortOffset = 20294;
inline int GetCoordinatorPort(int valkey_port) {
  return valkey_port == 6378
       ? valkey_port + kCoordinatorPortOffset + 1   // avoid collision with TLS offset
       : valkey_port + kCoordinatorPortOffset;
}
```

Default 6379 -> **26673** ("COORD" on a phone keypad).

Cluster-bus message -> `HandleBroadcastedMetadata` resolves sender IP via `ValkeyModule_GetClusterNodeInfo`, constructs `ip:GetCoordinatorPort(node_port)`.

## Server (`ServerImpl`)

Wraps gRPC C++ async server. `ServerImpl::Create` binds `[::]:<port>` insecure. Channel args:

- `GRPC_ARG_ALLOW_REUSEPORT = 1`
- `GRPC_ARG_MINIMAL_STACK = 1`
- `GRPC_ARG_OPTIMIZATION_TARGET = "latency"`
- `GRPC_ARG_TCP_TX_ZEROCOPY_ENABLED = 1`

Initial bind retries up to 10x with 100 ms * attempt backoff, running `lsof` on each failure to log the holder.

`coordinator::Service` `CallbackService` methods:

- **GetGlobalMetadata** - `GRPCSuspensionGuard` -> `vmsdk::RunByMain` to read metadata.
- **SearchIndexPartition** - `GRPCSearchRequestToParameters` converts to `SearchParameters`, runs index + slot consistency checks, dispatches to reader pool via `query::SearchAsync(kRemote)`. Results serialized into `NeighborEntry`. `RemoteResponderSearch` handles completion.
- **InfoIndexPartition** - main thread, `GenerateInfoResponse` looks up `IndexSchema`, checks consistency, populates the response.

## Client (`ClientImpl`)

Retry policy (gRPC service-config JSON):

- Max 5 attempts.
- Backoff: initial 100 ms, max 1 s, multiplier 1.0.
- Retryable codes: `UNAVAILABLE`, `UNKNOWN`, `RESOURCE_EXHAUSTED`, `INTERNAL`, `DATA_LOSS`, `NOT_FOUND`.

Timeouts:

| RPC | Timeout | Source |
|-----|---------|--------|
| `GetGlobalMetadata` | 60 s | fixed |
| `SearchIndexPartition` | `coordinator-query-timeout-secs` (default 120, 1-3600) | config |
| `InfoIndexPartition` | `ft-info-rpc-timeout-ms` (default 2500) | config |

All async. Each allocates a heap struct for context/request/response/callback/latency sample. Callback fires on a gRPC background thread -> `GRPCSuspensionGuard` -> user callback -> metrics + latency sample. Bytes tracked in `coordinator_bytes_in` / `_out`.

## Client pool (`ClientPool`)

Per-address cache under a mutex, `flat_hash_map`. First access -> `ClientImpl::MakeInsecureClient` creates a channel with the shared args. Subsequent -> cached.

Each client holds its own detached thread-safe context cloned from the pool's. Pool owned by `ValkeySearch`, shared with `MetadataManager`.

## `MetadataManager`

Singleton managing cluster-wide metadata consistency.

- `metadata_` - local `GlobalMetadata` (main-thread guarded).
- `staged_metadata_` - during replication loads.
- `registered_types_` - type name -> callbacks (fingerprint, update, min_version).
- `client_pool_` - shared pool reference.

Registers for `RDB_SECTION_GLOBAL_METADATA` load/save. `RegisterType` takes:

- `FingerprintCallback` - per-entry fingerprint.
- `MetadataUpdateCallback` - create/modify/delete.
- `MinVersionCallback` - minimum module version.

Entry lifecycle:

- `CreateEntry` - fingerprint, callbacks, update tree, bump version, recompute top-level fingerprint, replicate via `FT.INTERNAL_UPDATE`, cluster-bus broadcast.
- `DeleteEntry` - tombstone (content empty, version++), replicate + broadcast.
- `GetGlobalMetadata` - deep copy of local metadata.

## HighwayHash fingerprinting

```cpp
static constexpr highwayhash::HHKey kHashKey{
    0x9736bad976c904ea, 0x08f963a1a52eece9,
    0x1ea3f3f773f3b510, 0x9290a6b4e4db3d51};
```

**Per-entry** fingerprint via the registered `FingerprintCallback` - serializes the proto `Any` and hashes. **Depends on encoding version** - different module versions may produce different fingerprints.

**Top-level** (`ComputeTopLevelFingerprint`) summarizes the tree. Per entry build a `ChildMetadataEntry` {hash(type_name), hash(id), version, fingerprint}. Sort deterministically (by type-name hash then id hash), hash the contiguous buffer.

Two-level scheme: matching top-level -> identical; divergent -> fetch full `GetGlobalMetadata` to find differences.

## Cluster-bus broadcast

Metadata changes propagate via **Valkey cluster bus**, not gRPC. `BroadcastMetadata` serializes `GlobalMetadataVersionHeader` (`top_level_fingerprint`, `top_level_version`, `top_level_min_version`) and sends with `ValkeyModule_SendClusterMessage` (receiver ID `0x00`).

Header-only (lightweight). Recipients compare version+fingerprint to decide if a full fetch is needed.

Periodic timer every ~30 s (±25% jitter) via `MetadataManagerSendMetadataBroadcast` ensures convergence under lost messages. Starts on first server cron after first `FT.CREATE`. `RegisterForClusterMessages` subscribes `MetadataManagerOnClusterMessageCallback` for message type `0x00`.

## Reconciliation

`HandleBroadcastedMetadata`:

1. Skip if RDB/AOF loading.
2. Skip if replica (primaries only).
3. Proposed version `<` local -> ignore.
4. Versions equal but fingerprints differ, OR proposed version higher -> fetch full via `GetGlobalMetadata` gRPC.
5. `ReconcileMetadata` merges.

`ReconcileMetadata` merge rules:

- Skip entries with lower proposed version.
- Equal version -> prefer higher `encoding_version` (newer module features win).
- Equal version + encoding -> fingerprint tiebreak (higher wins).
- Re-fingerprint if proposed encoding_version < local (unstable fingerprints across versions).
- Invoke registered callbacks per accepted change.
- `CallFTInternalUpdateForReconciliation` replicates accepted changes.
- Recompute top-level fingerprint + version; broadcast if fingerprint changed.

Health: `last_healthy_metadata_millis_`, `metadata_reconciliation_completed_count_`.

## Replication staging

- `OnReplicationLoadStart` -> `staging_metadata_due_to_repl_load_ = true`.
- `LoadMetadata` writes to `staged_metadata_`.
- `OnLoadingEnded` clears local metadata, reconciles from staged with `prefer_incoming=true, trigger_callbacks=false`, clears staged.

Non-replication loads (restart): `LoadMetadata` merges directly into `metadata_` via `ReconcileMetadata`.

## `use-coordinator`

Boolean, `options::GetUseCoordinator()`. Enabled -> `ValkeySearch::InitCoordinator` starts gRPC server, creates client pool, inits `MetadataManager`, registers for cluster messages + server cron. Disabled -> standalone or basic cluster without gRPC fanout.

## gRPC suspension (`GRPCSuspender` / `GRPCSuspensionGuard`)

Prevents gRPC callbacks from touching shared state during `fork()`.

- `Suspend()` - blocks until in-flight callbacks drain, prevents new ones.
- `Resume()` - releases.
- `GRPCSuspensionGuard` - RAII at the start of every gRPC callback (incr on ctor, decr on dtor).

Impl: `absl::Mutex` + two condition variables (drain wait, resume wait). Singleton via `absl::NoDestructor` to avoid destruction races with gRPC event engine threads at process exit.
