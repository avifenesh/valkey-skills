# IndexSchema

Use when reasoning about per-index state, attribute management, keyspace mutation processing, backfill, or mutation sequence numbers.

Source: `src/index_schema.{h,cc}`.

## Shape

One `IndexSchema` per `FT.CREATE`. Inherits from `KeyspaceEventSubscription` (receives key-change events) and `std::enable_shared_from_this` (safe `shared_ptr` / `weak_ptr` for background tasks).

Key owned state:

| Field | Type | Role |
|-------|------|------|
| `name_` | string | index name |
| `db_num_` | uint32_t | database number |
| `attributes_` | `flat_hash_map<string, Attribute>` | alias -> `Attribute` (holds `IndexBase`) |
| `attribute_data_type_` | `unique_ptr<AttributeDataType>` | Hash or JSON source |
| `backfill_job_` | `MainThreadAccessGuard<optional<BackfillJob>>` | active backfill state |
| `time_sliced_mutex_` | `TimeSlicedMRMWMutex` | read/write phase coordination |
| `mutations_thread_pool_` | `ThreadPool*` | borrowed writer pool |
| `tracked_mutated_records_` | `InternedStringHashMap<DocumentMutation>` | pending mutations by interned key |
| `text_index_schema_` | `shared_ptr<TextIndexSchema>` | shared text state (language, punctuation, stop words) |
| `stats_` | `Stats` | per-index counters |

## `Create()`

```cpp
static absl::StatusOr<std::shared_ptr<IndexSchema>> Create(
    ValkeyModuleCtx *ctx, const data_model::IndexSchema &proto,
    vmsdk::ThreadPool *mutations_thread_pool,
    bool skip_attributes, bool reload);
```

Steps:

1. Validate data type (Hash or JSON - JSON needs the JSON module loaded).
2. Enforce `kMaxTextFieldsCount = 64` text fields per index (text-field tracking uses 64-bit bitmasks).
3. Construct - initializes `TimeSlicedMRMWMutex` with 10 ms read / 1 ms write quota, 1 ms / 200 us grace periods.
4. `Init()` - register with `KeyspaceEventManager`, create `BackfillJob`.
5. `IndexFactory()` + `AddIndex()` per proto attribute (Tag, Numeric, Text, VectorHNSW, VectorFlat).
6. `skip_initial_scan` on the proto (and not a reload) marks backfill done immediately.

Prefix handling: if the proto has no prefixes, `""` is used (matches all). Overlapping prefixes that contain each other are deduplicated. RDB reload restores `document_cnt` from saved stats.

## Attributes

`attributes_` keyed by alias (query-facing name). Each `Attribute` holds: `alias`, `identifier` (Hash field or JSON path), `index` (`shared_ptr<IndexBase>`), `position` (into `attributes_indexed_data_size_`).

`AddIndex()` inserts the attribute, grows the size-tracking vector, updates `identifier_to_alias_`, refreshes text bitmasks.

### Text field bitmasks

| Mask | Use |
|------|-----|
| `all_text_field_mask_` | unqualified text queries |
| `suffix_text_field_mask_` | fields with suffix trie enabled |
| `stem_text_field_mask_` | fields with stemming enabled |

`GetAllTextIdentifiers(with_suffix)`, `GetAllTextFieldMask(with_suffix)`, `GetTextIdentifiersByFieldMask()` avoid iteration at query time.

## Keyspace notifications

`OnKeyspaceNotification(ctx, type, event, key)` flow:

1. `IsInCurrentDB(ctx)` filter.
2. `ProcessKeyspaceNotification(ctx, key, false)`.
3. Open key with `NOEFFECTS | READ`.
4. `GetAttributeDataType().IsProperType()` - Hash/JSON match.
5. Per attribute: `VectorExternalizer::Instance().GetRecord()`. Missing record on untracked key -> skip.
6. `NormalizeStringRecord()` for string-type records.
7. Counters: `ingest_hash_keys` / `ingest_json_keys`.
8. `ProcessMutation()`.

Deleted keys (null `key_obj`): all attributes get `DeletionType::kRecord`. The same `ProcessKeyspaceNotification()` is called from the backfill scan callback with `from_backfill=true`.

## Mutation pipeline

### Main thread (`ProcessMutation`)

1. `UpdateDbInfoKey` - update `db_key_info_`, bump `schema_mutation_sequence_number_`, adjust `document_cnt`.
2. If no writer pool: `WriterMutexLock(time_sliced_mutex_)` + `SyncProcessMutation()`.
3. Inside MULTI/EXEC: `EnqueueMultiMutation()`; batch flushes on next FT.SEARCH via `ProcessMultiQueue()`.
4. `TrackMutatedRecord()` into `tracked_mutated_records_` (interned-key); existing entries merge.
5. `ScheduleMutation()` - writer pool task. Backfill = `Priority::kLow`; real-time = `Priority::kHigh`.
6. Real user clients (not backfill, not inside MULTI) block via `ShouldBlockClient()` until mutation is visible.

### Writer thread (`ProcessSingleMutationAsync`)

1. `WriterMutexLock(time_sliced_mutex_)`.
2. `ConsumeTrackedMutatedAttribute()` - pop pending mutations for the key; multiple mutations to the same key collapse.
3. Per consumed mutation in `SyncProcessMutation`:
   - `TextIndexSchema::DeleteKeyData()`
   - `ProcessAttributeMutation()` per attribute -> `AddRecord` / `ModifyRecord` / `RemoveRecord` on the concrete index (tracks success/failure/skip).
   - All-delete case: drop from `index_key_info_`.
   - `TextIndexSchema::CommitKeyData()`.
4. Decrement `mutation_queue_size_`, sample queue delay.

## Mutation sequence numbers

`using MutationSequenceNumber = uint64_t;`

Two parallel maps:

| Map | Thread safety | Purpose |
|-----|---------------|---------|
| `db_key_info_` | main thread only (`MainThreadAccessGuard`) | seq number assigned at notification |
| `index_key_info_` | `time_sliced_mutex_` write phase | updated after the mutation completes |

Query-side: `PerformKeyContentionCheck()` compares neighbor seq numbers against `db_key_info_`; mismatch means in-flight mutation - the query is enqueued to retry after the mutation completes.

`PopulateIndexMutationSequenceNumbers()` reads `index_key_info_` under the read phase (`ABSL_SHARED_LOCKS_REQUIRED(time_sliced_mutex_)`).

## Backfill

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

`PerformBackfill()` runs on every `SchemaManager::OnServerCronCallback`:

1. No-op if `IsScanDone()`.
2. Pause if `VALKEYMODULE_CTX_FLAGS_OOM` is set.
3. Track `db_size` monotonically for progress reporting.
4. `ValkeyModule_Scan(BackfillScanCallback, batch_size)`.
5. Callback: prefix check, then `ProcessKeyspaceNotification(ctx, keyname, /*from_backfill=*/true)`.
6. Scan returns 0 -> `MarkScanAsDone()` + log duration.

Reported progress: `GetBackfillPercent() = (scanned - in_queue) / db_size`. `backfill-batch-size` controls per-tick count (default 10240). `IsBackfillInProgress()` = scan active OR `backfill_inqueue_tasks > 0`.

## `TimeSlicedMRMWMutex` timing

Time-slices between read and write phases. Asymmetric quotas prioritize query latency over mutation throughput (10:1 read vs write).

| Parameter | Value | Effect |
|-----------|-------|--------|
| `read_quota_duration` | 10 ms | max read phase when writers are waiting |
| `read_switch_grace_period` | 1 ms | read inactivity before switching to write |
| `write_quota_duration` | 1 ms | max write phase when readers are waiting |
| `write_switch_grace_period` | 200 us | write inactivity before switching to read |

Queries take `ReaderMutexLock`. Writers take `WriterMutexLock`. Multiple concurrent readers or multiple concurrent writers (on different keys) are allowed; `mutated_records_mutex_` arbitrates writers on the same key.

## `Stats`

Atomic counters feeding `FT.INFO` and coordinator fanout via `GetInfoIndexPartitionData()`.

| Counter | Type | Meaning |
|---------|------|---------|
| `subscription_add` / `_modify` / `_remove` | `ResultCnt` | success / failure / skip |
| `document_cnt` | `atomic<uint32_t>` | indexed documents |
| `backfill_inqueue_tasks` | `atomic<uint32_t>` | pending backfill tasks |
| `mutation_queue_size_` | `uint64_t` (mutex) | pending mutations |
| `mutations_queue_delay_` | `Duration` (mutex) | sampled queue wait |

`InfoIndexPartitionData` fields: `num_docs`, `num_records`, `backfill_complete_percent`, `mutation_queue_size`, `state`.
