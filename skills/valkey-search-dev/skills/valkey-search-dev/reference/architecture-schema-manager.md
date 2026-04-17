# SchemaManager

Use when reasoning about the index registry, `IndexSchema` CRUD, replication staging, FlushDB/SwapDB handling, or RDB save/load of index metadata.

Source: `src/schema_manager.{h,cc}`.

## Singleton

Initialized during `ValkeySearch::Startup()`:

```cpp
SchemaManager::InitInstance(std::make_unique<SchemaManager>(
    ctx,
    server_events::SubscribeToServerEvents,   // deferred event subscription
    writer_thread_pool_.get(),
    use_coordinator && IsCluster()));
```

Constructor:

1. Registers RDB callbacks for `RDB_SECTION_INDEX_SCHEMA` (load/save/count/min-version).
2. If coordinator enabled, registers with `MetadataManager` for cluster-wide metadata sync (`ComputeFingerprint` + `OnMetadataCallback`).

Server event subscription is **deferred** until the first index is created (`SubscribeToServerEventsIfNeeded()`) - no cron/fork/flush overhead when no indexes exist.

## Data structure

Two-level map under a mutex:

```cpp
mutable absl::Mutex db_to_index_schemas_mutex_;
absl::flat_hash_map<uint32_t,
    absl::flat_hash_map<std::string, std::shared_ptr<IndexSchema>>>
    db_to_index_schemas_;   // db_num -> name -> IndexSchema
```

Parallel staging map for replication loads:

```cpp
vmsdk::MainThreadAccessGuard<...> staged_db_to_index_schemas_;
vmsdk::MainThreadAccessGuard<bool> staging_indices_due_to_repl_load_;
```

| Config | Default | Max | Purpose |
|--------|---------|-----|---------|
| `max-indexes` | 1000 | 10 000 000 | total indexes across all databases |
| `backfill-batch-size` | 10240 | INT32_MAX | keys scanned per cron tick (global budget) |

## `CreateIndexSchema` (FT.CREATE)

```cpp
absl::StatusOr<coordinator::IndexFingerprintVersion>
CreateIndexSchema(ValkeyModuleCtx *ctx, const data_model::IndexSchema &proto);
```

**Non-coordinated (standalone / replica):**

1. `max-indexes` check.
2. Lock `db_to_index_schemas_mutex_`.
3. `CreateIndexSchemaInternal()`: `LookupInternal()` for duplicate, `IndexSchema::Create()`, insert, `SubscribeToServerEventsIfNeeded()`.
4. Return `IndexFingerprintVersion(0, 0)`.

**Coordinated (cluster):**

1. `max-indexes` check.
2. `MetadataManager` existing-entry check.
3. Pack proto into `google::protobuf::Any`.
4. `MetadataManager::CreateEntry()` distributes across the cluster.
5. `OnMetadataCallback()` on each node removes any same-named index, calls `CreateIndexSchemaInternal()`, sets fingerprint + version.

Fingerprint = HighwayHash of the serialized proto.

## `RemoveIndexSchema` (FT.DROPINDEX)

**Non-coordinated:** Lock, `RemoveIndexSchemaInternal()` - move the `shared_ptr` out, erase inner (and outer if DB is empty), call `MarkAsDestructing()` on the schema, return for cleanup.

**Coordinated:** `MetadataManager::DeleteEntry()` -> `OnMetadataCallback(metadata=nullptr)` -> local removal.

`MarkAsDestructing()` stops the removed schema from processing its mutation backlog (sets `is_destructing_` under `mutated_records_mutex_`). Critical for dropped-index cleanup.

## Lookup

```cpp
absl::StatusOr<std::shared_ptr<IndexSchema>> GetIndexSchema(uint32_t db_num, absl::string_view name) const;
```

Acquires mutex -> `LookupInternal()` -> two-level lookup. Missing DB or name -> `NotFoundError`.

`GetIndexSchemasInDB(db_num)` returns a **copied** set of names (not suitable for hot paths).

Aggregates (all iterate under the mutex): `GetNumberOfIndexSchemas`, `GetNumberOfAttributes`, `GetNumberOf{Text,Tag,Numeric,Vector}Attributes`, `GetAttributeCountByType`, `GetTotalIndexedDocuments`, `IsIndexingInProgress`.

## Replication staging

Full syncs stage indexes so existing query traffic is undisturbed.

1. **`OnReplicationLoadStart`** (`VALKEYMODULE_SUBEVENT_LOADING_REPL_START`): sets `staging_indices_due_to_repl_load_ = true`.
2. **`LoadIndex`** during staging writes to `staged_db_to_index_schemas_[db_num][name]` instead of the live map.
3. **`OnLoadingEnded`** (loading finished with staging active):
   - Lock live map.
   - `RemoveAll()` destroys current live indexes.
   - `db_to_index_schemas_ = std::move(staged_db_to_index_schemas_.Get())`.
   - Clear staging map, reset flag.
   - `OnLoadingEnded()` per loaded schema.
   - `VectorExternalizer::Instance().ProcessEngineUpdateQueue()`.

Atomic swap - queries never observe partial state. Used for both diskless and disk-based replication.

## FlushDB

`OnFlushDBCallback()` on `VALKEYMODULE_SUBEVENT_FLUSHDB_END`:

- **Standalone/replica:** remove all indexes in the flushed DB.
- **Coordinated:** indexes are cluster-level. Copy proto via `old_schema->ToProto()`, remove, recreate via `CreateIndexSchemaInternal()` - preserves definition, clears data. Use `FT.DROPINDEX` to truly remove.

## SwapDB

`OnSwapDB()` for `ValkeyModuleEvent_SwapDB`:

- Same-DB (`first == second`): call `OnSwapDB()` on each schema (bookkeeping).
- Cross-DB: insert empty maps if missing, `std::swap` inner maps (O(1)), call `OnSwapDB()` on all schemas so they update their `db_num_`.

## `OnLoadingEnded`

Fires on `VALKEYMODULE_SUBEVENT_LOADING_ENDED`:

1. Staging-to-live swap if staging was active (see above).
2. `schema->OnLoadingEnded(ctx)` per live index - finalizes text index structures, corrects `db_num_` after mid-load SwapDB.
3. `VectorExternalizer::Instance().ProcessEngineUpdateQueue()`.

## Backfill orchestration

`PerformBackfill(ctx, batch_size)` runs from `OnServerCronCallback`. Iterates all indexes under the mutex, calling `schema->PerformBackfill(ctx, remaining)` with a remaining-count budget that decreases per index - global rate limit across all indexes. Per-tick budget = `backfill-batch-size`.

## RDB save/load

**Save** (`VALKEYMODULE_AUX_AFTER_RDB`): `SaveIndexes()` writes nothing if no indexes (auxsave2 omits empty sections); otherwise `schema->RDBSave(rdb)` per index.

**Load**: per RDB section:

1. `SubscribeToServerEventsIfNeeded()`.
2. Extract `IndexSchema` proto.
3. `IndexSchema::LoadFromRDB()`.
4. If staging active, store in `staged_db_to_index_schemas_`.
5. Else remove any same-named existing, then insert.
6. Bump `rdb_restore_completed_indexes`.

## Fingerprinting

`ComputeFingerprint(const google::protobuf::Any&)` -> `absl::StatusOr<uint64_t>` via HighwayHash seeded by the fixed `kHashKey` (four 64-bit constants). Used by the coordinator to detect cross-node metadata divergence. **Assumes fleet-wide module-version consistency** - protobuf serialization is not deterministic across versions.
