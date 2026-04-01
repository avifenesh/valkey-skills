# RDB Serialization and Replication

Use when working on RDB persistence, snapshot serialization, the protobuf-based RDB format, AOF replication of metadata, or the FT.INTERNAL_UPDATE command.

Source: `src/rdb_serialization.h`, `src/rdb_serialization.cc`, `src/rdb_section.proto`, `src/commands/ft_internal_update.cc`, `src/coordinator/metadata_manager.cc`

## Contents

- RDB Format Overview (line 21)
- RDB Section Types (line 33)
- Supplemental Content (line 62)
- SafeRDB Wrapper (line 78)
- Iterator Classes (line 101)
- Chunk Streaming (line 124)
- RDB Load Path (line 138)
- RDB Save Path (line 170)
- Module Type Registration (line 184)
- FT.INTERNAL_UPDATE Command (line 201)
- Staging During Replication Loads (line 225)

## RDB Format Overview

valkey-search uses a protobuf-based RDB aux section format. The format structure:

1. **Header**: encoding version check + semantic version (unsigned int) + section count (unsigned int)
2. **RDBSection sequence**: each section is a serialized protobuf string
3. **Supplemental content**: optional chunked binary data following each section

The encoding version is checked at load time (`kCurrentEncVer = 1`). The semantic version tracks the minimum module version needed to read the RDB. If the RDB was written by a newer module, loading fails with a version mismatch error.

The module type name is `"Vk-Search"` (9 chars, matching Valkey's module type name length requirement).

## RDB Section Types

Defined in `rdb_section.proto`:

```protobuf
enum RDBSectionType {
  RDB_SECTION_UNSET = 0;
  RDB_SECTION_INDEX_SCHEMA = 1;
  RDB_SECTION_GLOBAL_METADATA = 2;
}
```

**RDB_SECTION_INDEX_SCHEMA** - Contains an `IndexSchema` protobuf with the full schema definition and attribute list. Each `FT.CREATE` index produces one section. Supplemental content carries the actual index data (index content, key-to-ID mappings, and optionally the mutation queue in V2 format).

**RDB_SECTION_GLOBAL_METADATA** - Contains the `coordinator.GlobalMetadata` protobuf with the cluster-wide metadata tree. At most one section of this type exists per RDB.

The `RDBSection` message wraps these:

```protobuf
message RDBSection {
  RDBSectionType type = 1;
  uint32 supplemental_count = 2;
  oneof contents {
    IndexSchema index_schema_contents = 3;
    coordinator.GlobalMetadata global_metadata_contents = 4;
  }
}
```

## Supplemental Content

Supplemental content provides chunked binary data without requiring full in-memory serialization. Each section declares its `supplemental_count`. Three types exist:

```protobuf
enum SupplementalContentType {
  SUPPLEMENTAL_CONTENT_INDEX_CONTENT = 1;
  SUPPLEMENTAL_CONTENT_KEY_TO_ID_MAP = 2;
  SUPPLEMENTAL_CONTENT_INDEX_EXTENSION = 3;
}
```

Each supplemental section starts with a `SupplementalContentHeader` identifying the type and associated attribute. The data follows as a sequence of `SupplementalContentChunk` messages. An empty chunk (no `binary_content` field) signals EOF for that supplemental section.

`MutationQueueHeader` (V2) carries a `backfilling` flag for the saved mutation queue state.

## SafeRDB Wrapper

`SafeRDB` wraps `ValkeyModuleIO*` and converts raw Valkey I/O operations into `absl::StatusOr` results, forcing error handling at every call site:

```cpp
class SafeRDB {
 public:
  explicit SafeRDB(ValkeyModuleIO *rdb);
  virtual absl::StatusOr<size_t> LoadSizeT();
  virtual absl::StatusOr<unsigned int> LoadUnsigned();
  virtual absl::StatusOr<int> LoadSigned();
  virtual absl::StatusOr<double> LoadDouble();
  virtual absl::StatusOr<vmsdk::UniqueValkeyString> LoadString();
  virtual absl::Status SaveSizeT(size_t val);
  virtual absl::Status SaveUnsigned(unsigned int val);
  virtual absl::Status SaveSigned(int val);
  virtual absl::Status SaveDouble(double val);
  virtual absl::Status SaveStringBuffer(absl::string_view buf);
};
```

Each method calls the underlying `ValkeyModule_Load*` or `ValkeyModule_Save*` function, then checks `ValkeyModule_IsIOError`. On error, it returns `absl::InternalError` with a descriptive message. The virtual methods allow test mocking.

## Iterator Classes

Three nested iterator classes enforce strict consumption of the RDB stream:

**RDBSectionIter** - Iterates over sections. After calling `Next()`, the caller must call `IterateSupplementalContent()` and fully consume the returned iterator before calling `Next()` again. Destructor asserts `remaining_ == 0`.

**SupplementalContentIter** - Iterates over supplemental content for one section. After `Next()` returns the header, the caller must call `IterateChunks()` and fully consume the chunk iterator. Destructor asserts `remaining_ == 0`.

**SupplementalContentChunkIter** - Iterates over binary chunks. Buffers one chunk ahead so `HasNext()` is accurate. An empty chunk signals EOF. Destructor warns if not fully consumed.

All iterators are move-only (deleted copy constructors). The destructors log warnings and fire debug assertions if the stream was not fully consumed - this catches programming errors where supplemental data is accidentally skipped.

For unknown section types, `PerformRDBLoad` manually drains all supplemental content:

```cpp
auto supp_it = it.IterateSupplementalContent();
while (supp_it.HasNext()) {
  auto _ = supp_it.Next();
  auto chunk_it = supp_it.IterateChunks();
  while (chunk_it.HasNext()) { auto _ = chunk_it.Next(); }
}
```

## Chunk Streaming

Two adapter classes bridge the RDB chunk format to the `hnswlib::InputStream`/`OutputStream` interfaces used by vector indexes:

**RDBChunkInputStream** - Wraps `SupplementalContentChunkIter`. `LoadChunk()` returns each chunk's `binary_content` as a `unique_ptr<string>`. Provides convenience methods:
- `LoadString()` - loads a chunk and returns its content as a string
- `LoadObject<T>()` - loads a chunk and reinterprets it as a trivially-copyable type T, with size validation
- `AtEnd()` - checks if all chunks have been consumed

**RDBChunkOutputStream** - Wraps `SafeRDB*`. `SaveChunk()` serializes each chunk as a `SupplementalContentChunk` protobuf and writes it via `SaveStringBuffer`. Provides:
- `SaveString()` - saves a string_view as a chunk
- `SaveObject<T>()` - saves a trivially-copyable object as a chunk
- `Close()` - writes an empty string (EOF marker); called automatically by destructor if not already closed

## RDB Load Path

`AuxLoadCallback` is the entry point, registered as `aux_load` in the module type. It wraps the `ValkeyModuleIO*` in a `SafeRDB` and calls `PerformRDBLoad`:

1. Validate encoding version (`kCurrentEncVer = 1`)
2. Load and validate semantic version (must not exceed current module version)
3. Load section count
4. Initialize restore progress tracking in `Metrics::GetStats()`:
   - `rdb_restore_in_progress = true`
   - `rdb_restore_total_indexes = section_count`
   - `rdb_restore_completed_indexes = 0`
5. Iterate sections via `RDBSectionIter`
6. For each section, look up the registered callback in `kRegisteredRDBSectionCallbacks` by section type
7. Call the load callback with the section protobuf and supplemental content iterator
8. For unregistered types, log a warning and drain all supplemental data
9. Set `rdb_restore_in_progress = false` on success

Callbacks are dispatched via a static map:

```cpp
extern absl::flat_hash_map<data_model::RDBSectionType, RDBSectionCallbacks>
    kRegisteredRDBSectionCallbacks;
```

`RegisterRDBCallback` populates this map (main-thread only). Each entry provides:
- `load` - per-section load callback
- `save` - single callback for all sections of this type
- `section_count` - returns how many sections to write
- `minimum_semantic_version` - returns the minimum version needed

On load success, `rdb_load_success_cnt` increments. On failure, `rdb_load_failure_cnt` increments and `VALKEYMODULE_ERR` is returned.

## RDB Save Path

`AuxSaveCallback` is the entry point, registered as `aux_save2` with trigger `VALKEYMODULE_AUX_AFTER_RDB`. It calls `PerformRDBSave`:

1. Aggregate section counts from all registered callbacks
2. Compute the minimum semantic version across all types that have sections to save
3. If total section count is 0, return immediately (nothing to write)
4. Write the header: minimum version (unsigned) + section count (unsigned)
5. Call each save callback in sequence for types with sections > 0

The save triggers `AFTER_RDB` ensures data is written after the base RDB data, so aux load happens after keys are available.

On success, `rdb_save_success_cnt` increments. On failure, `rdb_save_failure_cnt` increments.

## Module Type Registration

`RegisterModuleType` creates a dummy data type (`"Vk-Search"`) solely to get aux callbacks. The `rdb_load`, `rdb_save`, `aof_rewrite`, and `free` callbacks all assert-fail if called - the module never creates instances of this type. Only `aux_load` and `aux_save2` are meaningful.

```cpp
static ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load = [](ValkeyModuleIO*, int) -> void* { DCHECK(false); },
    .rdb_save = [](ValkeyModuleIO*, void*) { DCHECK(false); },
    .aof_rewrite = [](ValkeyModuleIO*, ValkeyModuleString*, void*) { DCHECK(false); },
    .free = [](void*) { DCHECK(false); },
    .aux_load = AuxLoadCallback,
    .aux_save_triggers = VALKEYMODULE_AUX_AFTER_RDB,
    .aux_save2 = AuxSaveCallback,
};
```

## FT.INTERNAL_UPDATE Command

`FT.INTERNAL_UPDATE` replicates metadata changes from primary to replicas. It is an internal command - not user-facing.

**Arguments**: `FT.INTERNAL_UPDATE <id> <serialized_entry> <serialized_header>`
- `id` - the encoded metadata entry identifier
- `serialized_entry` - protobuf-serialized `GlobalMetadataEntry`
- `serialized_header` - protobuf-serialized `GlobalMetadataVersionHeader`

**Processing flow** (`FTInternalUpdateCmd`):
1. Parse `GlobalMetadataEntry` from argv[2]
2. Parse `GlobalMetadataVersionHeader` from argv[3]
3. If the node is a replica or is loading, call `CreateEntryOnReplica` to apply the metadata update
4. Call `ValkeyModule_ReplicateVerbatim(ctx)` to propagate to downstream replicas
5. Reply OK

**Error handling**: `HandleInternalUpdateFailure` provides resilient error recovery:
- Parse failures increment `ft_internal_update_parse_failures_cnt`
- Process failures increment `ft_internal_update_process_failures_cnt`
- During AOF loading, if `skip-corrupted-internal-update-entries` config is enabled, corrupted entries are skipped with a warning (incrementing `ft_internal_update_skipped_entries_cnt`)
- If skip is disabled during AOF loading, the process aborts via `CHECK(false)`

**Replication path**: `MetadataManager::ReplicateFTInternalUpdate` is called by `CreateEntry` and `DeleteEntry` on the primary. It serializes the entry and header, then calls `ValkeyModule_Call` to invoke `FT.INTERNAL_UPDATE`, which triggers AOF recording. During reconciliation, `CallFTInternalUpdateForReconciliation` does the same for remotely-received updates.

## Staging During Replication Loads

When a replica receives an RDB from its primary, metadata must not be applied piecemeal:

1. `OnReplicationLoadStart` - sets `staging_metadata_due_to_repl_load_ = true`
2. During load, `LoadMetadata` writes to `staged_metadata_` instead of the live `metadata_`
3. `OnLoadingEnded` - clears `metadata_`, reconciles from `staged_metadata_` with `prefer_incoming = true` and `trigger_callbacks = false`
4. Fingerprint and version are populated to each `IndexSchema` via `SchemaManager::PopulateFingerprintVersionFromMetadata`
5. Staged metadata is cleared; `is_loading_` is reset

For non-replication loads (server restart from RDB), `LoadMetadata` merges directly into `metadata_` via `ReconcileMetadata` with `prefer_incoming = true`, allowing the existing state (if any) to be merged with the loaded data.
