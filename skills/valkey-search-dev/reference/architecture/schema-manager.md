# SchemaManager

Use when understanding index registry operations, CRUD for IndexSchema objects, replication staging, FlushDB/SwapDB handling, or RDB save/load of index metadata.

Source: `src/schema_manager.h`, `src/schema_manager.cc`

## Contents

- [Singleton and Construction](#singleton-and-construction)
- [Data Structure](#data-structure)
- [CreateIndexSchema](#createindexschema)
- [RemoveIndexSchema](#removeindexschema)
- [GetIndexSchema and Lookup](#getindexschema-and-lookup)
- [Staging During Replication](#staging-during-replication)
- [FlushDB Handling](#flushdb-handling)
- [SwapDB Handling](#swapdb-handling)
- [OnLoadingEnded](#onloadingended)
- [Backfill Orchestration](#backfill-orchestration)
- [RDB Save and Load](#rdb-save-and-load)
- [Fingerprinting](#fingerprinting)
- [See Also](#see-also)

## Singleton and Construction

SchemaManager is a singleton that owns all IndexSchema instances in the module. It is initialized during `ValkeySearch::Startup()`:

```cpp
SchemaManager::InitInstance(std::make_unique<SchemaManager>(
    ctx,
    server_events::SubscribeToServerEvents,   // deferred event subscription
    writer_thread_pool_.get(),                 // mutations thread pool
    use_coordinator && IsCluster()));          // coordinator mode
```

The constructor:

1. Registers RDB callbacks for `RDB_SECTION_INDEX_SCHEMA` - load, save, section count, and minimum version.
2. If coordinator is enabled, registers with `MetadataManager` for cluster-wide metadata synchronization with `ComputeFingerprint` and an `OnMetadataCallback` handler.

Server event subscription is deferred until the first index is created via `SubscribeToServerEventsIfNeeded()`. This avoids unnecessary cron/fork/flush callbacks when no indexes exist.

## Data Structure

The primary data structure is a two-level map protected by a mutex:

```cpp
mutable absl::Mutex db_to_index_schemas_mutex_;
absl::flat_hash_map<
    uint32_t,
    absl::flat_hash_map<std::string, std::shared_ptr<IndexSchema>>>
    db_to_index_schemas_;
```

The outer map is keyed by database number (`db_num`), the inner map by index name. This allows efficient per-database operations like FlushDB.

A parallel staging map exists for replication loads:

```cpp
vmsdk::MainThreadAccessGuard<...> staged_db_to_index_schemas_;
vmsdk::MainThreadAccessGuard<bool> staging_indices_due_to_repl_load_;
```

Configurable limits:

| Config | Default | Max | Purpose |
|--------|---------|-----|---------|
| `max-indexes` | 1000 | 10,000,000 | Maximum total indexes across all databases |
| `backfill-batch-size` | 10240 | INT32_MAX | Keys scanned per cron tick across all indexes |

## CreateIndexSchema

`CreateIndexSchema()` is the entry point for `FT.CREATE`:

```cpp
absl::StatusOr<coordinator::IndexFingerprintVersion>
CreateIndexSchema(ValkeyModuleCtx *ctx,
                  const data_model::IndexSchema &index_schema_proto);
```

### Non-coordinated mode (standalone/replica)

1. Check `max-indexes` limit.
2. Acquire `db_to_index_schemas_mutex_`.
3. Call `CreateIndexSchemaInternal()`:
   - Check for duplicate via `LookupInternal()`.
   - Call `IndexSchema::Create()` to build the index.
   - Insert into `db_to_index_schemas_[db_num][name]`.
   - Call `SubscribeToServerEventsIfNeeded()`.
4. Return dummy fingerprint/version (0, 0).

### Coordinated mode (cluster)

1. Check `max-indexes` limit.
2. Check for existing entry in `MetadataManager`.
3. Pack the protobuf into `google::protobuf::Any`.
4. Call `MetadataManager::CreateEntry()` which distributes across the cluster.
5. The MetadataManager calls back `OnMetadataCallback()` on each node, which:
   - Removes any existing index with the same name.
   - Calls `CreateIndexSchemaInternal()`.
   - Sets fingerprint and version on the created schema.

The return value `IndexFingerprintVersion` contains the fingerprint (highwayhash of serialized protobuf) and version number for cluster consistency.

## RemoveIndexSchema

`RemoveIndexSchema()` handles `FT.DROPINDEX`:

### Non-coordinated mode

1. Acquire mutex.
2. Call `RemoveIndexSchemaInternal()`:
   - Look up the index.
   - Move the `shared_ptr` out of the map.
   - Erase from the inner map; erase the outer entry if the DB has no remaining indexes.
   - Call `MarkAsDestructing()` on the removed schema to stop processing pending mutations.
   - Return the removed schema for cleanup.

### Coordinated mode

1. Call `MetadataManager::DeleteEntry()`.
2. MetadataManager calls back `OnMetadataCallback()` with `metadata == nullptr`, which removes the local schema.

`MarkAsDestructing()` is critical - it prevents the index from continuing to process its mutation backlog, avoiding unnecessary CPU and memory usage for a dropped index. It sets `is_destructing_` under `mutated_records_mutex_`.

## GetIndexSchema and Lookup

```cpp
absl::StatusOr<std::shared_ptr<IndexSchema>> GetIndexSchema(
    uint32_t db_num, absl::string_view name) const;
```

Acquires `db_to_index_schemas_mutex_` and delegates to `LookupInternal()`, which does a two-level map lookup. Returns `NotFoundError` if the database or name is not present.

`GetIndexSchemasInDB(db_num)` returns a copied set of index names for a given database. The copy prevents holding the mutex during iteration but makes it unsuitable for hot paths like FT.SEARCH.

Aggregate statistics methods iterate all indexes under the mutex:

| Method | Returns |
|--------|---------|
| `GetNumberOfIndexSchemas()` | Total index count |
| `GetNumberOfAttributes()` | Total attribute count across all indexes |
| `GetNumberOfTextAttributes()` | Text attributes only |
| `GetNumberOfTagAttributes()` | Tag attributes only |
| `GetNumberOfNumericAttributes()` | Numeric attributes only |
| `GetNumberOfVectorAttributes()` | Vector attributes only |
| `GetAttributeCountByType(type)` | Attributes by `AttributeType` enum |
| `GetTotalIndexedDocuments()` | Sum of document_cnt across all indexes |
| `IsIndexingInProgress()` | True if any index has an active backfill |

## Staging During Replication

During replication loads (full sync), indexes are staged to avoid disrupting query traffic on existing indexes:

### OnReplicationLoadStart

Called on `VALKEYMODULE_SUBEVENT_LOADING_REPL_START`:

```cpp
staging_indices_due_to_repl_load_ = true;
```

This flag causes `LoadIndex()` to write to `staged_db_to_index_schemas_` instead of `db_to_index_schemas_`.

### LoadIndex during staging

When `staging_indices_due_to_repl_load_` is true:

```cpp
staged_db_to_index_schemas_.Get()[db_num][name] = std::move(index_schema);
```

The existing live indexes continue serving queries during the load.

### OnLoadingEnded (swap)

When loading completes with staging active:

1. Acquire `db_to_index_schemas_mutex_`.
2. Call `RemoveAll()` to destroy all current live indexes.
3. Swap: `db_to_index_schemas_ = staged_db_to_index_schemas_.Get()`.
4. Clear the staging map and reset the staging flag.
5. Call `OnLoadingEnded()` on each loaded schema to finalize state.
6. Process vector externalizer update queue.

This atomic swap ensures queries never see a partially-loaded state. Staging is used for both diskless and disk-based replication since the overhead is negligible (disk-based sync flushes first, so no additional memory pressure).

## FlushDB Handling

`OnFlushDBCallback()` triggers on `VALKEYMODULE_SUBEVENT_FLUSHDB_END`:

### Non-coordinated mode

All indexes in the flushed database are removed via `RemoveIndexSchemaInternal()`.

### Coordinated mode

Indexes are recreated after removal because they are a cluster-level construct. The sequence:

1. Copy the index schema protobuf via `old_schema->ToProto()`.
2. Remove the old schema.
3. Recreate via `CreateIndexSchemaInternal()`.

This preserves the index definition while clearing its data. To permanently remove an index in coordinated mode, use `FT.DROPINDEX` explicitly.

## SwapDB Handling

`OnSwapDB()` handles `ValkeyModuleEvent_SwapDB`:

- **Same-DB swap** (`dbnum_first == dbnum_second`): calls `OnSwapDB()` on each schema in that DB (useful for internal bookkeeping).
- **Cross-DB swap**: inserts empty maps if missing, swaps the inner maps between the two databases via `std::swap`, then calls `OnSwapDB()` on all schemas in both DBs so they update their internal `db_num_`.

The swap uses `std::swap` on the hash maps, which is O(1).

## OnLoadingEnded

Called on `VALKEYMODULE_SUBEVENT_LOADING_ENDED` after RDB loading completes:

1. If staging was active, performs the staging-to-live swap (see above).
2. Iterates all live indexes and calls `schema->OnLoadingEnded(ctx)` on each. This lets indexes finalize post-load state (e.g., text index structures, db_num corrections after SwapDB during load).
3. Calls `VectorExternalizer::Instance().ProcessEngineUpdateQueue()`.

## Backfill Orchestration

`PerformBackfill()` is called from `SchemaManager::OnServerCronCallback()`:

```cpp
void PerformBackfill(ValkeyModuleCtx *ctx, uint32_t batch_size);
```

It iterates all indexes under the mutex and calls `schema->PerformBackfill(ctx, remaining_count)` on each. The remaining batch budget decreases as each index consumes keys, providing a global rate limit across all indexes.

The cron callback dispatches the configured `backfill-batch-size` per tick.

## RDB Save and Load

### Save

`SaveIndexes()` runs during `VALKEYMODULE_AUX_AFTER_RDB`:

1. If no indexes exist, writes nothing (auxsave2 omits empty sections).
2. Iterates all indexes and calls `schema->RDBSave(rdb)` on each.

### Load

`LoadIndex()` processes each RDB section:

1. Calls `SubscribeToServerEventsIfNeeded()` to receive the loading-ended callback.
2. Extracts the `IndexSchema` protobuf from the RDB section.
3. Calls `IndexSchema::LoadFromRDB()` to reconstruct the index.
4. If staging is active, stores in `staged_db_to_index_schemas_`.
5. Otherwise, removes any existing index with the same name, then inserts.
6. Increments `rdb_restore_completed_indexes` for progress tracking.

## Fingerprinting

`ComputeFingerprint()` uses HighwayHash to generate a 64-bit fingerprint of a serialized IndexSchema protobuf:

```cpp
static absl::StatusOr<uint64_t> ComputeFingerprint(
    const google::protobuf::Any &metadata);
```

The fingerprint is seeded by a fixed 256-bit key (`kHashKey` - four randomly generated 64-bit values). It is used by the coordinator to detect metadata divergence across cluster nodes. Note that protobuf serialization is non-deterministic across versions, so this assumes fleet-wide module version consistency.

## See Also

- [module-overview](module-overview.md) - ValkeySearch singleton and startup
- [index-schema](index-schema.md) - IndexSchema internals and mutation processing
- [thread-model](thread-model.md) - Concurrency model and fork suspension
- [coordinator](../cluster/coordinator.md) - MetadataManager cluster coordination
- [replication](../cluster/replication.md) - Staging behavior during full sync
- [build](../contributing/build.md) - Build system and protobuf code generation
