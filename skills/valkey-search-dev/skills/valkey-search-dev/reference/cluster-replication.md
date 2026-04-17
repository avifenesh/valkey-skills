# RDB serialization and replication

Use when reasoning about RDB format, `SafeRDB`, chunked vector data, the module type registration, or `FT.INTERNAL_UPDATE`.

Source: `src/rdb_serialization.{h,cc}`, `src/rdb_section.proto`, `src/commands/ft_internal_update.cc`, `src/coordinator/metadata_manager.cc`.

## Format

Protobuf-based RDB aux section format.

1. **Header**: encoding version check + semantic version (unsigned) + section count (unsigned).
2. **RDBSection sequence**: serialized protobuf string per section.
3. **Supplemental content**: optional chunked binary data after each section.

Encoding version at load time is `kCurrentEncVer = 1`. Semantic version tracks the minimum module version needed to read. Newer-than-local -> version mismatch error.

Module type name is `"Vk-Search"` (9 chars, Valkey max).

## Section types (`rdb_section.proto`)

```protobuf
enum RDBSectionType {
  RDB_SECTION_UNSET = 0;
  RDB_SECTION_INDEX_SCHEMA = 1;
  RDB_SECTION_GLOBAL_METADATA = 2;
}

message RDBSection {
  RDBSectionType type = 1;
  uint32 supplemental_count = 2;
  oneof contents {
    IndexSchema                 index_schema_contents   = 3;
    coordinator.GlobalMetadata  global_metadata_contents = 4;
  }
}
```

- **INDEX_SCHEMA** - one per FT.CREATE. Supplemental carries index data (contents, key-to-ID, optionally V2 mutation queue).
- **GLOBAL_METADATA** - at most one, cluster-wide metadata tree.

## Supplemental content

```protobuf
enum SupplementalContentType {
  SUPPLEMENTAL_CONTENT_INDEX_CONTENT    = 1;
  SUPPLEMENTAL_CONTENT_KEY_TO_ID_MAP    = 2;
  SUPPLEMENTAL_CONTENT_INDEX_EXTENSION  = 3;
}
```

Each supplemental begins with a `SupplementalContentHeader` (type + associated attribute), followed by `SupplementalContentChunk` messages. Empty chunk (no `binary_content`) = EOF for that supplemental.

`MutationQueueHeader` (V2) carries a `backfilling` flag for saved mutation state.

## `SafeRDB`

Wraps `ValkeyModuleIO*`, returns `absl::StatusOr` so every call-site must handle errors.

```cpp
class SafeRDB {
  explicit SafeRDB(ValkeyModuleIO *rdb);
  virtual absl::StatusOr<size_t>                   LoadSizeT();
  virtual absl::StatusOr<unsigned int>             LoadUnsigned();
  virtual absl::StatusOr<int>                      LoadSigned();
  virtual absl::StatusOr<double>                   LoadDouble();
  virtual absl::StatusOr<vmsdk::UniqueValkeyString> LoadString();
  virtual absl::Status SaveSizeT       (size_t);
  virtual absl::Status SaveUnsigned    (unsigned int);
  virtual absl::Status SaveSigned      (int);
  virtual absl::Status SaveDouble      (double);
  virtual absl::Status SaveStringBuffer(absl::string_view);
};
```

Each method calls the raw `ValkeyModule_Load*` / `Save*`, checks `ValkeyModule_IsIOError`, returns `absl::InternalError` on fail. Virtual -> test mocking.

## Iterators

Three nested iterators enforce strict stream consumption. All move-only (deleted copy). Destructors warn / debug-assert if not consumed.

- **`RDBSectionIter`** - iterates sections. After `Next()`, caller MUST call `IterateSupplementalContent()` and fully drain before the next `Next()`. Dtor asserts `remaining_ == 0`.
- **`SupplementalContentIter`** - iterates supplementals for one section. After `Next()` (header), caller MUST drain via `IterateChunks()`. Dtor asserts.
- **`SupplementalContentChunkIter`** - iterates chunks. Buffers one ahead so `HasNext()` is accurate. Empty chunk = EOF. Dtor warns.

Unknown section types - manually drain:

```cpp
auto supp = it.IterateSupplementalContent();
while (supp.HasNext()) {
  (void)supp.Next();
  auto chunk = supp.IterateChunks();
  while (chunk.HasNext()) (void)chunk.Next();
}
```

## Chunk streams

Bridge between RDB chunks and `hnswlib::InputStream` / `OutputStream` for vector index save/load.

**`RDBChunkInputStream`** wraps `SupplementalContentChunkIter`:

- `LoadChunk()` -> `unique_ptr<string>` (binary_content).
- `LoadString()` - chunk as string.
- `LoadObject<T>()` - reinterpret as trivially-copyable T with size validation.
- `AtEnd()` - all chunks consumed.

**`RDBChunkOutputStream`** wraps `SafeRDB*`:

- `SaveChunk()` - wraps in `SupplementalContentChunk` proto, `SaveStringBuffer`.
- `SaveString()`, `SaveObject<T>()`.
- `Close()` - empty-string EOF marker; auto-called by dtor if not explicit.

## Load path (`AuxLoadCallback`)

Registered as `aux_load` on the module type.

1. Encoding version check (`kCurrentEncVer = 1`).
2. Semantic version <= current module version.
3. Load section count.
4. Restore progress in `Metrics::GetStats()`: `rdb_restore_in_progress = true`, `_total_indexes = section_count`, `_completed_indexes = 0`.
5. `RDBSectionIter` per section, dispatch via `kRegisteredRDBSectionCallbacks[type]`.
6. Unknown type -> warn + drain.
7. On success: `rdb_restore_in_progress = false`, bump `rdb_load_success_cnt`.

`kRegisteredRDBSectionCallbacks` is an `absl::flat_hash_map<RDBSectionType, RDBSectionCallbacks>`. `RegisterRDBCallback` (main-thread only) registers: `load`, `save`, `section_count`, `minimum_semantic_version`.

Failure -> `rdb_load_failure_cnt++`, return `VALKEYMODULE_ERR`.

## Save path (`AuxSaveCallback`)

Registered as `aux_save2` with trigger `VALKEYMODULE_AUX_AFTER_RDB` (writes after base RDB data so aux load happens after keys are available).

1. Sum section counts from all registered callbacks.
2. Minimum semantic version across types with sections > 0.
3. Total 0 -> return immediately.
4. Header: minimum version + section count.
5. Call each save callback for types with sections > 0.

Metrics: `rdb_save_success_cnt` / `rdb_save_failure_cnt`.

## Module type (dummy)

`RegisterModuleType` creates `"Vk-Search"` solely to get aux callbacks. Module never creates instances:

```cpp
static ValkeyModuleTypeMethods tm = {
    .version           = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load          = [](...) -> void* { DCHECK(false); },
    .rdb_save          = [](...)          { DCHECK(false); },
    .aof_rewrite       = [](...)          { DCHECK(false); },
    .free              = [](...)          { DCHECK(false); },
    .aux_load          = AuxLoadCallback,
    .aux_save_triggers = VALKEYMODULE_AUX_AFTER_RDB,
    .aux_save2         = AuxSaveCallback,
};
```

## `FT.INTERNAL_UPDATE`

Replicates metadata changes primary -> replicas. Internal, not user-facing.

**Syntax**: `FT.INTERNAL_UPDATE <id> <serialized_entry> <serialized_header>`

- `id` - encoded entry identifier.
- `serialized_entry` - `GlobalMetadataEntry` proto.
- `serialized_header` - `GlobalMetadataVersionHeader` proto.

**Flow** (`FTInternalUpdateCmd`):

1. Parse both protos.
2. Replica or loading -> `CreateEntryOnReplica` applies the update.
3. `ValkeyModule_ReplicateVerbatim(ctx)` propagates to downstream replicas.
4. Reply OK.

**Error handling** (`HandleInternalUpdateFailure`):

| Failure | Counter |
|---------|---------|
| Parse | `ft_internal_update_parse_failures_cnt` |
| Process | `ft_internal_update_process_failures_cnt` |
| AOF load + `skip-corrupted-internal-update-entries` enabled | `ft_internal_update_skipped_entries_cnt` + warn |

AOF load + skip disabled -> `CHECK(false)` (abort).

**Replication path**: `MetadataManager::ReplicateFTInternalUpdate` called by `CreateEntry` / `DeleteEntry` on the primary - serializes entry+header, `ValkeyModule_Call("FT.INTERNAL_UPDATE", ...)` - triggers AOF recording. Reconciliation uses `CallFTInternalUpdateForReconciliation` for remotely-received updates.

## Replication load staging

Replica receiving RDB - metadata must not be applied piecemeal.

1. `OnReplicationLoadStart` -> `staging_metadata_due_to_repl_load_ = true`.
2. `LoadMetadata` writes to `staged_metadata_`.
3. `OnLoadingEnded` - clear `metadata_`, reconcile from staged with `prefer_incoming=true, trigger_callbacks=false`.
4. Fingerprint + version populated per `IndexSchema` via `SchemaManager::PopulateFingerprintVersionFromMetadata`.
5. Clear staged; reset `is_loading_`.

Non-replication (restart from RDB): `LoadMetadata` merges directly into `metadata_` via `ReconcileMetadata(prefer_incoming=true)` - existing state merges with loaded data.
