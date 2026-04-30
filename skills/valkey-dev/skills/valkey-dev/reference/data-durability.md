# Persistence and Replication

RDB/AOF writers and replication consumers share the same RDB serialization format.

Writer classes (load-bearing for propagation / ACL / stats code): **normal** (`current_client` set, via `call()` + `alsoPropagate`), **synthetic** (cron, `current_client == NULL` - `activeExpireCycle`, `delKeysInSlot`, topology updates, module cron, HFE cleanup), **import-mode** (`server.import_mode`; active expire off, stream-driven), **replica-local** (writable-replica direct write, lives in `replicaKeysWithExpire`), **AOF-replay** (fake client, `executing_client` set, `current_client` may be NULL, routed through `mustObeyClient()`).

## RDB (`src/rdb.c`, `src/rdb.h`)

- `RDB_VERSION = 80` in `rdb.h`; 9-byte magic `VALKEY080`. Legacy `REDIS0011` still accepted on load.
- Versions 12-79 are the foreign range (`RDB_FOREIGN_VERSION_MIN = 12`, `MAX = 79`) - rejected by default via `rdbIsForeignVersion`, loadable only with explicit override. Blocks Redis CE 7.4+ RDB.
- Cross-version load is step-stoned. 9.0 RDB (version 80, `VALKEY` magic) is unreadable by 7.2/8.0 at signature check. 8.1 + `rdb-version-check=relaxed` is the only bridge. Direct 9.0 -> 7.2/8.0 downgrade is unsupported.
- Opcodes 245-255 are read-and-ignore on unknown values; type range 1-22 unknown is a hard fail. Bytes in 23-244 must error distinctly from unknown 245-255 (different diagnostic classes). Forward-compatible hints use an opcode; a new object type does not.
- `RDB_OPCODE_SLOT_INFO` is read-and-ignore only. Parse via `rdbLoadLen` to advance the stream; do NOT size hashtables from its values. Per-slot AUX is the canonical mechanism and carries three sizes (`keys`, `expires`, `keys_with_volatile_items`) - loader pre-sizes all three via `kvstoreHashtableExpand`.
- Validate signature + version before `emptyDb()` on full sync. Distinguish `RDB_INCOMPATIBLE` (pre-flush, preserves dataset) from `RDB_FAILED` (post-flush). Callers - `replicaLoadPrimaryRDBFromSocket`, `rdbLoad`, `rdbLoadRio`, `VM_RdbLoad`, `debug.c` - propagate `RDB_INCOMPATIBLE`. Coercing to generic failure empties the DB on a recoverable version mismatch.
- Version-accept predicate lives in `rdb.{c,h}`, not inlined in `cluster.c`. Duplicating drifts the two readers.
- RDB is untrusted input. Length fields from AUX / RESIZEDB / SLOT_INFO must be range-validated before driving allocations or `kvstoreHashtableExpand`. CRC64 covers transport corruption only; `lpFirst` / `lpNext` walks must assert on listpack invariant violations.
- RDB load of expired-on-wire fields materializes them (`valkey-check-rdb` and `RESTORE` pass `now=0`). `RDB_LOAD_ERR_ALL_ITEMS_EXPIRED` is the dedicated marker - do NOT fold into the generic empty-keys counter.
- Dropping expired hash fields during load propagates HDEL to replicas. Silent drop on the primary skips the keyspace event and desyncs. RESTORE deliberately keeps expired fields (intentional asymmetry).
- If all fields of a hash expire during RDB load, skip the key via `RDB_LOAD_ERR_ALL_ITEMS_EXPIRED`. Do NOT fire keyspace notifications in that path.
- `RDB_TYPE_HASH_2 = 22` (0x16) encodes a hash with per-field TTL; `HPERSIST` rewrites it to `0x04`. DUMP / DEBUG OBJECT / RESTORE reflect the current form. New RDB types gate at both ends: `rdbGetObjectType` returns -1 (skip) when target rdbver is too old; unknown type on decode aborts. No silent substitution.
- Aux fields are forward-compatible by layout. `sscanf` consumers require only fields present at introduction; extra trailing tokens must be tolerated. Both `valkey-ver` and `redis-ver` are written; loaders recognize either.
- Modules using `auxsave2` must guard with an explicit "will save" check; preamble-RDB skips creating a module context unless bytes are written.
- In-progress slot-migration imports must be included in RDB. `kvstore` iterator takes `HASHTABLE_ITER_INCLUDE_IMPORTING`; key counts combine `kvstoreSize + kvstoreImportingSize`. Client-facing reads (SCAN, KEYS, RANDOMKEY, expire, evict) still hide importing keys.
- RDB/AOF files open with mode 0666 so `server.umask` controls final mode. Hardcoding 0644 breaks backup/restore under a different user. Extends to log, config-rewrite, cluster-config, valkey-cli history.
- DUMP framing: payload + 1 type byte + 2 RDB-version bytes + 8 CRC64 bytes (11 bytes overhead). Hand-crafted RESTORE tests must pin RDB version via config.
- `rdbSaveObject` returns 0/-1, NOT a byte count. `rdbSavedObjectLen` and DEBUG OBJECT `serializedlength` share the codepath but must not treat the return as a size.
- Compression kicks in at 20+ bytes. Benchmarks claiming to exercise RDB / full-sync payload must use values above that threshold (512 bytes is standard).
- `aof.c` stays agnostic of fork caller. The `pname` string through `sendChildInfo` / `rdbSaveDb` is opaque; extend rdbflags/aofflags, don't teach `aof.c` about slot migration.
- `clusterHandleSlotExportBackgroundSaveDone` is invoked from `backgroundSaveDoneHandler` the same way as `updateReplicasWaitingBgsave`. RDB must not depend on cluster/migration modules; the check lives inside the slot-export handler and no-ops when no export is active.
- `valkey-check-rdb` `--output FILE` must use `freopen`-style redirection, not `stdout = fdopen(...)` - musl/Alpine treats `stdout` as read-only. Human-readable `[info]` / `\o/` prefix is not CSV.
- SAVE blocks the main process for the full dump; BGSAVE forks. SHUTDOWN (no flags) refuses to exit on a failed prior save; SHUTDOWN FORCE exits anyway; SHUTDOWN SAFE refuses on unsafe conditions (e.g. voting primary with slots); FORCE + SAFE exits but warns.
- LASTSAVE is ADMIN-category but historically lacks `@admin` flag. Adding it is a breaking ACL change. LASTSAVE is FAST, LOADING-safe, STALE-safe.
- Return codes: `RDB_OK`, `RDB_NOT_EXIST`, `RDB_INCOMPATIBLE`, `RDB_FAILED`.
- Diskless sync terminates the socket stream with a 40-byte random hex EOF marker, verified on receive. Diskless-load failure paths leave the DB unmodified; `repl-diskless-load=flush-before-load` (new in 8.1) opts into pre-load flush. Tests proving unmodified-on-failure must use pipelined writes with `CLIENT REPLY OFF`.

## AOF (`src/aof.c`)

- AOF preamble load applies the `rdbSaveInfo` - restore replid/offset from rsi aux; otherwise AOF-preamble-based PSYNC silently degrades to full sync after restart. If rsi is invalid, free `repl_backlog` to avoid an assert during cluster failover.
- AOF preamble is detected by reading exactly 6 bytes and matching literal `REDIS` or `VALKEY` (followed by 3-digit zero-padded RDB version). Buffer is not NUL-terminated. Absence is not an error - `loadSingleAppendOnlyFile` must `fseek` back to 0 and read AOF commands directly.
- AOF fake client (`CLIENT_ID_AOF`) is exempt from cluster-slot rejection via `mustObeyClient()`. AOF loader, primary replication link, and import-side slot-migration client all route through it. Re-validating replayed writes is a bug class.
- AOF load runs outside a normal client context - uses `executing_client`, not `current_client`. Cross-cutting logic (notifications, stats, ACL, keyspace events) must null-guard `current_client` or resolve via `executing_client`.
- New optional args in minor versions rewrite argv before propagation. HSETEX NX/XX (9.1) must strip/normalize so older replicas on the same major line can replay.
- Sync RDB can be promoted to AOF base when `aof-use-rdb-preamble` and disk-based sync are both set. Correctness is driven by the AOF manifest, not the `aof-base` aux field - external tools keying off `aof-base` must migrate to the manifest.
- `AOF_WAIT_REWRITE` state: replicas enabling AOF during full sync sit here until rewrite completes - prevents a partial AOF while the dataset is still loading.
- Fake-client AOF validation uses `commandCheckExistence` + arity check - don't silently ignore damaged entries. AOF corruption is data-integrity, not best-effort resync.
- PSYNC-from-AOF is unsupported. The only supported no-full-resync restart is RDB (or AOF preamble carrying valid replid/offset) plus intact `repl_backlog`.
- `openNewIncrAofForAppend` is not general-purpose. Early-returns on `AOF_OFF`, eagerly persists manifest, switches `server.aof_fd` on success. Callers staging a new base+incr+history atomically must not reuse it.
- AOF-rewrite/reload tests with hash-field expirations must `DEBUG SET-ACTIVE-EXPIRE 0` before `debug loadaof` and before collecting pre-rewrite state.

## Replication (`src/replication.c`)

Source uses `primary`/`replica` as primary names; `master`/`slave` are aliases kept in INFO fields, config aliases, and a few error-string constants. New code uses `primary_*`/`replica_*`.

- TTL propagation is absolute ms timestamps, not relative. Every expiry-setting command (SET EX/PX/EXAT, HEXPIRE, HSETEX, HPEXPIRE) rewrites argv to PXAT before AOF/replication so replay lifetime matches primary regardless of lag.
- "Replicate as DEL" is a contract. When a write's net effect is key removal (expired-on-arrival writes, cleanup during overwrite, HFE reaching zero fields), the wire form must be DEL so older replicas / AOF consumers understand it. Never ship a non-DEL encoding for what is semantically a delete.
- `current_client == NULL` during synthetic writes. Active expire, `delKeysInSlot`, cluster topology updates, module cron all synthesize DEL/UNLINK with no current client. Propagation / ACL / stats code must null-check or use `executing_client`.
- Conditional rejections don't propagate. HSETEX NX/XX/FNX/FXX that rejects the write streams nothing. Only the effective write is replicated.
- One `alsoPropagate` call per command, after the reply is queued. Multiple calls on one command path are a bug class.
- Primary rewrites expired-field writes. HINCRBY / HSETEX KEEPTTL / HINCRBYFLOAT on an already-expired-but-unreclaimed hash field emits HDEL first, then the user write. HINCRBYFLOAT always replicates as HSET of the final value plus field TTL.
- Blocked writers during role change disconnect or redirect synchronously. When a primary becomes a replica (`replicationSetPrimary`), write-producing blocked clients must be flushed before the replication stream reopens.
- Active expire is primary-only. `activeExpireCycle` runs only under `!server.import_mode && iAmPrimary()`. Replicas and import-mode nodes receive expirations from the stream only.
- Multi-DB sub-streams inject SELECT at boundaries (atomic slot migration substream, synthetic AOF) - emit SELECT at start and whenever the active DB changes.
- Replica read loop is bounded per event by `repl-max-reads-per-io-event` (hardcoded 25 in 9.0). Bound applies to all reads from the primary client in one iteration, not the first. `shouldRepeatReadFromPrimary` must precede `beforeNextClient` to avoid UAF ordering.
- Writable replicas don't share state with the replicated stream. Locally-written keys can type-collide with inbound writes and stall the stream. TTLs in `replicaKeysWithExpire` must be cleaned up on role-promotion via the active expire cycle (not a new config, not gated on active-expire-enabled or import-mode). Failure = memory leak proportional to TTL-bearing direct writes.
- Coordinated FAILOVER (the command, not cluster auto-failover): primary treats `PSYNC_FULLRESYNC` identically to `PSYNC_CONTINUE` - both clear failover state across sync strategies including dual-channel. Any new sync result that diverges is a bug. Writes during `FAILOVER_IN_PROGRESS` get `-REDIRECT host:port`.
- `ProcessingEventsWhileBlocked` windows skip main-thread accounting. True during RDB load, AOF load, full-sync load on replica (for -LOADING replies), slow Lua, long-running module commands. `server.el_start` is not set in `afterSleep` when the flag is true; `beforeSleep` duration accounting must guard on it.
- `propagation-error-behavior` governs replication, not RDB load. Unknown-command handling on a replica defaults to `ignore`. New write commands depending on a non-ignore behavior on replicas must document it.
- CLUSTER REPLICATE classifies as user-initiated flush. Bucket via `lazyfree-lazy-user-flush`, not `repl-replica-lazy-flush`.
- Writable replicas remain supported (if discouraged); FAILOVER is the recommended alternative but trades in-flight writes or stalls. Silent deprecation breaks operator workflow.
- `pending_repl_data` cleanup freed on bio/lazyfree thread via `freePendingReplDataBufAsync`. After hand-off, null the main-thread pointer.
- Replica "done loading RDB" signal is the log line `Done loading RDB`. Tests must match via `wait_for_log_messages {srv_idx patterns from_line maxtries delay}` with `delay ~100ms`, not 5ms * 2000 tries.
- `wait_done_loading` polls via PING and trips only after RDB load *has begun*. Up to 1000ms gap between "transfer complete" and "loading started" because the replication cron is async.

## Dual-channel replication

Grep `dualChannel` in `src/replication.c`. Full resync uses two TCP connections so the replica buffers streaming writes locally instead of the primary buffering per-replica. RDB-channel state machine on the replica (grep `REPL_DUAL_CHANNEL_`): `SEND_HANDSHAKE -> RECEIVE_AUTH_REPLY -> RECEIVE_REPLCONF_REPLY -> RECEIVE_ENDOFF -> RDB_LOAD -> RDB_LOADED`. `dualChannelFullSyncWithPrimary` drives it; `dualChannelSyncSuccess` runs on RDB-done (streams `pending_repl_data`, calls `replicationResurrectProvisionalPrimary`, `replicationSteadyStateInit`, `replicationSendAck`). `PSYNC_FULLRESYNC_DUAL_CHANNEL = 6`. Fallbacks: primary without capa does single-channel; RDB-channel connection failure falls back to single-channel; partial resync is single-channel only. Knobs: `dual-channel-replication-enabled` (default `no`, replica-side); local buffer block size ~`repl-backlog-size / 16`. 8.1 durability knobs: `rdb-version-check`, `bgsave cancel` arg, `repl-diskless-load=flush-before-load`.

- BIO thread owns the primary socket for the RDB download window; main thread takes over for the load. The two must never write concurrently (TLS session state corruption). Main-thread busy-wait on BIO is accepted (mirrors `waitForClientIO`), bounded by `connRecvTimeout`.
- Replica-side `pending_repl_data` is deliberately uncapped. Replica buffers main-channel bytes while loading RDB; primary's COB for that replica grows symmetrically, so total memory matches single-channel. Accounting lives in `server.pending_repl_data.mem/len/peak`, NOT in `mem_total_replication_buffers` - surface via its own `mem_replica_dual_channel_buffer` INFO field.
- Back-pressure: if `pending_repl_data` exceeds `client-output-buffer-limit replica` hard limit, the replica stops reading the main channel. The primary's COB for that replica then grows, bounded by the same COB limits.
- RDB bytes account via `child_info` pipe, not client write buffer. `replication_bytes_transferred` updates from `child_info_data.repl_output_bytes`. Dual-channel needs its own `child_info` field - global COW accounting masks per-child-type data.
- Abort cleanup is unconditional. `replicationAbortDualChannelSyncTransfer` must close `repl_transfer_fd` AND unlink `repl_transfer_tmpfile` on every exit path, including outside `REPL_STATE_TRANSFER`. Route every error branch through a single cleanup helper.
- Primary shutdown grace window is a correctness parameter. Too short and the primary kills the main channel before the replica sends post-RDB PSYNC, triggering chained-replica assert. If `replicaof no one` runs mid-load, `protected_rdb_channel` must be released so the shutdown replica-catch-up grace can complete.
- BIO-thread RDB receive preserves the two-loop payload read. Outer loop consumes primary pings (newline bytes) sent before bulk length is known (refreshes `last_io`); inner loop drains until EOF marker or declared byte count. Collapsing breaks primary timeout handling.
- `bio_stat_net_repl_input_bytes` merges into `server.stat_net_repl_input_bytes` only after `handleBioThreadFinishedRDBDownload`. INFO `repl_input_bytes` appears to stall until RDB receive completes - intentional.
- Dual-channel + atomic slot migration has a known full-sync vs AOF-reload race; ASM tests deflake non-deterministically without the serialization fix.
- `diskless no replicas drop during rdb pipe` test is structurally flaky - races the diskless-sync rdb child termination. Isolated CI failures are infra flake unless reproducible locally.

## Fork machinery (`src/bio.c`, fork wrappers)

- At most one background child at a time; `server.child_type` discriminates. Cancellation sends SIGUSR1 after matching child_type, deferring reaping to `checkChildrenDone` (`killRDBChild`, `killAppendOnlyChild`, `TerminateModuleForkChild`, `killSlotMigrationChild`).
- Fork-coalesce on the hot path. Multiple slot-export operations batch into a single fork; full resync, BGSAVE, AOF rewrite, slot export should coalesce with an in-flight background save rather than start a new child.
- Copy-on-write accounting is per-child-type. Replication-child byte counts (dual-channel RDB) use a dedicated `repl_output_bytes` and source from `rio->processed_bytes`, not `stat()` on a transient file (diskless has no file). Per-fork CoW log line and INFO fields must stay scoped to the specific child type - a global `cow_size` erases the per-operation footprint.
- `valkey_fork` wrapper preserves `errno` across fork. Save immediately after `fork()`, restore after post-fork hooks (mirrors ust-fork). `restartServer()` must not close arbitrary FDs at shutdown - closing FDs owned by LTTng-UST corrupts tracer state. Naming is `valkey_fork` (the `z*` prefix is reserved for zmalloc-era symbols).
- `dismissSds` / `dismissMemory` only help on > page-size allocations. Freeing small strings in a memory-pool bin can dirty the page (triggering CoW) rather than release via `madvise(DONTNEED)`.
- `DEBUG pause-after-fork 1` tests must disable before teardown AND set `repl-diskless-sync-delay` to a large value (e.g. 100) before resuming. Otherwise the replica re-pauses inside a retried sync loop and hangs teardown.
