# IndexSchema Class

Use when understanding per-index state, attribute management, keyspace mutation processing, backfill, or the mutation sequence number system.

Source: `src/index_schema.h`, `src/index_schema.cc`

## Contents

- [Class Overview](#class-overview)
- [Creation and Initialization](#creation-and-initialization)
- [Attribute Map](#attribute-map)
- [Keyspace Notification Handling](#keyspace-notification-handling)
- [Mutation Processing Pipeline](#mutation-processing-pipeline)
- [Mutation Sequence Numbers](#mutation-sequence-numbers)
- [Backfill Job](#backfill-job)
- [TimeSlicedMRMWMutex Usage](#timeslicedmrmwmutex-usage)
- [Statistics and Info](#statistics-and-info)

## Class Overview

`IndexSchema` is the central per-index object in valkey-search. One instance exists for each `FT.CREATE` index. It inherits from `KeyspaceEventSubscription` (to receive keyspace notifications) and `std::enable_shared_from_this` (to safely pass `shared_ptr`/`weak_ptr` to background tasks).

```
IndexSchema
  |-- KeyspaceEventSubscription   (receives key change events)
  |-- enable_shared_from_this     (safe async references)
```

Key state owned by each IndexSchema:

| Field | Type | Purpose |
|-------|------|---------|
| `name_` | string | Index name from FT.CREATE |
| `db_num_` | uint32_t | Valkey database number |
| `attributes_` | flat_hash_map<string, Attribute> | Field name to Attribute (holds IndexBase) |
| `attribute_data_type_` | `unique_ptr<AttributeDataType>` | Hash or JSON data source |
| `backfill_job_` | `MainThreadAccessGuard<optional<BackfillJob>>` | Active backfill scan state |
| `time_sliced_mutex_` | TimeSlicedMRMWMutex | Read/write phase coordination |
| `mutations_thread_pool_` | ThreadPool* | Writer pool reference (not owned) |
| `tracked_mutated_records_` | `InternedStringHashMap<DocumentMutation>` | Pending mutations keyed by interned string |
| `text_index_schema_` | `shared_ptr<TextIndexSchema>` | Shared text index state (language, punctuation, stop words) |
| `stats_` | Stats | Per-index counters |

## Creation and Initialization

The static factory `IndexSchema::Create()` builds a new IndexSchema from a protobuf definition:

```cpp
static absl::StatusOr<std::shared_ptr<IndexSchema>> Create(
    ValkeyModuleCtx *ctx,
    const data_model::IndexSchema &index_schema_proto,
    vmsdk::ThreadPool *mutations_thread_pool,
    bool skip_attributes, bool reload);
```

Steps in `Create()`:

1. **Validate data type** - determines Hash or JSON. JSON requires the JSON module to be loaded.
2. **Count text fields** - enforces a maximum of 64 text fields per index (`kMaxTextFieldsCount`). This limit exists because text field tracking uses 64-bit bitmasks.
3. **Construct** - calls private constructor which initializes the `TimeSlicedMRMWMutex` with options (10ms read quota, 1ms write quota, 200us write grace period).
4. **Init** - `Init()` registers with `KeyspaceEventManager` for keyspace notifications and creates the `BackfillJob`.
5. **Add indexes** - iterates protobuf attributes, calls `IndexFactory()` to create concrete index objects (Tag, Numeric, Text, VectorHNSW, VectorFlat), then `AddIndex()` to register each.
6. **SkipInitialScan** - if the protobuf has `skip_initial_scan` set and this is not a reload, the backfill is immediately marked as done.

The constructor extracts key prefixes from the protobuf. If none are specified, an empty prefix `""` is used (matches all keys). Duplicate prefixes that are prefixes of each other are deduplicated.

For reload (RDB load), the constructor restores `document_cnt` from the saved protobuf stats.

## Attribute Map

Each field in an index is represented by an `Attribute` object stored in `attributes_`:

```cpp
absl::flat_hash_map<std::string, Attribute> attributes_;
```

The map is keyed by attribute alias (the name used in queries). Each Attribute holds:

- **alias** - query-facing name
- **identifier** - the actual Hash field name or JSON path
- **index** - `shared_ptr<IndexBase>` to the concrete index (VectorHNSW, Tag, etc.)
- **position** - index into `attributes_indexed_data_size_` for size tracking

`AddIndex()` inserts an attribute, grows `attributes_indexed_data_size_`, maps identifier to alias in `identifier_to_alias_`, and updates text field bitmasks.

Text field tracking uses 64-bit bitmasks:

| Bitmask | Purpose |
|---------|---------|
| `all_text_field_mask_` | All text fields - used for unqualified text queries |
| `suffix_text_field_mask_` | Fields with suffix trie enabled |
| `stem_text_field_mask_` | Fields with stemming enabled |

`GetAllTextIdentifiers(with_suffix)` and `GetAllTextFieldMask(with_suffix)` return these precomputed sets for query-time field resolution without iteration. `GetTextIdentifiersByFieldMask()` converts a bitmask back to identifier strings.

## Keyspace Notification Handling

`OnKeyspaceNotification()` is called by `KeyspaceEventManager` when a subscribed key changes:

```cpp
void OnKeyspaceNotification(ValkeyModuleCtx *ctx, int type,
                            const char *event, ValkeyModuleString *key);
```

The flow:

1. **DB check** - `IsInCurrentDB(ctx)` ensures the event is for this index's database.
2. **Delegate** - calls `ProcessKeyspaceNotification(ctx, key, false)`.
3. **Open key** - opens the key with `NOEFFECTS | READ` flags.
4. **Type check** - `GetAttributeDataType().IsProperType()` verifies Hash vs JSON match.
5. **Per-attribute extraction** - for each attribute, fetches the field value via `VectorExternalizer::Instance().GetRecord()`. If the record is missing and the key is not tracked, skips it.
6. **Normalize** - string-type records go through `NormalizeStringRecord()`.
7. **Metrics** - increments `ingest_hash_keys` or `ingest_json_keys`.
8. **Process** - calls `ProcessMutation()` with the collected attribute data.

For deleted keys (where `key_obj` is null), all attributes get `DeletionType::kRecord`.

The same `ProcessKeyspaceNotification()` is called from the backfill scan callback with `from_backfill=true`.

## Mutation Processing Pipeline

Mutations flow through a multi-stage pipeline that separates main-thread bookkeeping from background index updates:

### Main thread (`ProcessMutation`)

1. **UpdateDbInfoKey** - updates `db_key_info_` map with attribute sizes, increments `schema_mutation_sequence_number_`, updates `document_cnt`.
2. **Sync fallback** - if no writer thread pool, acquires `WriterMutexLock` on `time_sliced_mutex_` and calls `SyncProcessMutation()` directly.
3. **Multi/exec batching** - if inside MULTI/EXEC, calls `EnqueueMultiMutation()` instead of immediate scheduling. The batch is flushed on the next FT.SEARCH via `ProcessMultiQueue()`.
4. **Track** - `TrackMutatedRecord()` stores the mutation in `tracked_mutated_records_` (keyed by interned string). If the key already has a pending mutation, the new data merges into the existing entry.
5. **Schedule** - `ScheduleMutation()` pushes a task to the writer thread pool. Backfill mutations use `Priority::kLow`, real-time mutations use `Priority::kHigh`.
6. **Client blocking** - real user clients (not from backfill, not inside MULTI) get blocked until their mutation is visible. The `ShouldBlockClient()` function checks context flags.

### Writer thread (`ProcessSingleMutationAsync`)

1. **Acquire write phase** - `WriterMutexLock lock(&time_sliced_mutex_)`.
2. **Consume loop** - `ConsumeTrackedMutatedAttribute()` pops pending mutations for this key. Multiple mutations to the same key collapse.
3. **SyncProcessMutation** - for each consumed mutation:
   - Deletes existing text index data for the key via `TextIndexSchema::DeleteKeyData()`
   - Calls `ProcessAttributeMutation()` per attribute
   - If all attributes are deletes, removes from `index_key_info_`
   - Commits text index data via `TextIndexSchema::CommitKeyData()`
4. **ProcessAttributeMutation** - routes to `AddRecord`, `ModifyRecord`, or `RemoveRecord` on the concrete index, tracking success/failure/skip stats.
5. **Stat update** - decrements `mutation_queue_size_`, samples queue delay.

## Mutation Sequence Numbers

The mutation sequence number system provides consistency guarantees for queries that may race with in-flight mutations:

```cpp
using MutationSequenceNumber = uint64_t;
```

Two parallel maps track sequence numbers:

| Map | Thread safety | Purpose |
|-----|---------------|---------|
| `db_key_info_` | Main thread only (`MainThreadAccessGuard`) | Assigned on main thread when mutation is received |
| `index_key_info_` | `time_sliced_mutex_` (write phase) | Updated on writer thread after mutation completes |

The flow:

1. Main thread receives a mutation, increments `schema_mutation_sequence_number_`, stores in `db_key_info_[key].mutation_sequence_number_`.
2. Writer thread processes the mutation, updates `index_key_info_[key].mutation_sequence_number_`.
3. Queries call `PerformKeyContentionCheck()` to compare sequence numbers of neighbor results against `db_key_info_`. If they differ, the query result may be stale due to an in-flight mutation - the query is enqueued to retry after that mutation completes.

`PopulateIndexMutationSequenceNumbers()` reads from `index_key_info_` during the read phase of the time-sliced mutex. It requires `ABSL_SHARED_LOCKS_REQUIRED(time_sliced_mutex_)`.

## Backfill Job

When an index is created, it must scan existing keys to populate the index. The `BackfillJob` struct manages this:

```cpp
struct BackfillJob {
    vmsdk::UniqueValkeyDetachedThreadSafeContext scan_ctx;
    vmsdk::UniqueValkeyScanCursor cursor;
    uint64_t scanned_key_count{0};
    uint64_t db_size;
    vmsdk::StopWatch stopwatch;
    bool paused_by_oom{false};
    bool IsScanDone() const { return scan_ctx.get() == nullptr; }
    void MarkScanAsDone() { scan_ctx.reset(); cursor.reset(); }
};
```

`PerformBackfill()` is called from `SchemaManager::OnServerCronCallback()` on every cron tick:

1. **Check completion** - returns 0 if no backfill job or scan is done.
2. **OOM check** - pauses if `VALKEYMODULE_CTX_FLAGS_OOM` is set.
3. **DB size tracking** - monotonically increases `db_size` for accurate progress reporting.
4. **Scan loop** - calls `ValkeyModule_Scan()` with `BackfillScanCallback` up to `batch_size` keys.
5. **Callback** - for each scanned key, checks prefix match, then calls `ProcessKeyspaceNotification(ctx, keyname, true)`.
6. **Completion** - when `ValkeyModule_Scan` returns 0, calls `MarkScanAsDone()` and logs duration.

Progress is reported via `GetBackfillPercent()` which computes `(scanned - in_queue) / db_size`. The `backfill-batch-size` config controls keys processed per cron tick (default 10240).

`IsBackfillInProgress()` returns true when the scan cursor is active OR there are still queued backfill tasks (`backfill_inqueue_tasks > 0`).

## TimeSlicedMRMWMutex Usage

Each IndexSchema owns a `vmsdk::TimeSlicedMRMWMutex` (`time_sliced_mutex_`) that coordinates concurrent reads (queries) and writes (mutations) to the index data:

- **Read phase** - query threads acquire shared read access via `ReaderMutexLock`. Multiple queries execute concurrently during the read phase. Access to `index_key_info_` and index data structures is safe.
- **Write phase** - writer threads acquire shared write access via `WriterMutexLock`. Multiple mutations execute concurrently during the write phase (on different keys). The `mutated_records_mutex_` provides exclusion between writers accessing the same key's tracked records.

The mutex time-slices between phases with configurable quotas:

| Parameter | Value | Effect |
|-----------|-------|--------|
| `read_quota_duration` | 10ms | Maximum read phase duration when writes are waiting |
| `read_switch_grace_period` | 1ms | Inactivity before switching from read to write |
| `write_quota_duration` | 1ms | Maximum write phase duration when reads are waiting |
| `write_switch_grace_period` | 200us | Inactivity before switching from write to read |

This asymmetry (10:1 read vs write quota) prioritizes query latency over mutation throughput.

## Statistics and Info

The `Stats` struct tracks per-index metrics with atomic counters:

| Counter | Type | Meaning |
|---------|------|---------|
| `subscription_add` | ResultCnt | Records added (success/failure/skipped) |
| `subscription_modify` | ResultCnt | Records modified |
| `subscription_remove` | ResultCnt | Records removed |
| `document_cnt` | atomic<uint32_t> | Current indexed document count |
| `backfill_inqueue_tasks` | atomic<uint32_t> | Backfill tasks waiting in writer pool |
| `mutation_queue_size_` | uint64_t (mutex-guarded) | Mutations pending processing |
| `mutations_queue_delay_` | Duration (mutex-guarded) | Sampled queue wait time |

`RespondWithInfo()` formats these for `FT.INFO` responses. `GetInfoIndexPartitionData()` aggregates stats into the `InfoIndexPartitionData` struct for coordinator fanout, including `num_docs`, `num_records`, `backfill_complete_percent`, `mutation_queue_size`, and `state`.
</uint32_t></uint32_t>