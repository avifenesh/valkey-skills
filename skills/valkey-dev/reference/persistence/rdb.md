# RDB Snapshot Persistence

Use when you need to understand how Valkey creates point-in-time snapshots, the binary RDB file format, or the BGSAVE fork-based persistence model.

Source files: `src/rdb.c`, `src/rdb.h`

## Contents

- RDB File Format (line 18)
- BGSAVE Flow (line 137)
- RDB Loading on Startup (line 195)
- rdbSaveInfo - Replication Metadata in RDB (line 240)
- Diskless Replication (line 255)
- See Also (line 269)

---

## RDB File Format

An RDB file is a compact binary representation of the entire dataset. The layout:

```
[Magic + Version]  9 bytes: "VALKEY080" or "REDIS0011"
[Aux Fields]       Key-value metadata pairs (server version, timestamp, memory usage, etc.)
[Functions]        Lua function libraries (if any)
[DB 0]             Database selector + key-value pairs
[DB 1]             ...
[DB N]             ...
[EOF opcode]       Single byte: 0xFF
[CRC64 checksum]   8 bytes, little-endian
```

### Magic String and Version

```c
// rdb.h
#define RDB_VERSION 80

// rdbSaveRio() constructs the magic:
const char *magic_prefix = rdbUseValkeyMagic(rdbver) ? "VALKEY" : "REDIS0";
snprintf(magic, sizeof(magic), "%s%03d", magic_prefix, rdbver);
// Result: "VALKEY080" (9 bytes) for RDB version 80+
```

RDB version 11 is the last legacy Redis version (used by Valkey 7.x/8.x). Versions 12-79 are reserved as a "foreign" range to avoid collisions. Valkey 9.0+ uses RDB version 80 with the `VALKEY` magic.

### Length Encoding

All lengths in RDB use a variable-length encoding (defined in `rdb.h`):

```
00|XXXXXX           -> 6-bit length (0-63), 1 byte
01|XXXXXX XXXXXXXX  -> 14-bit length, 2 bytes
10|000000 [32-bit]  -> 32-bit length in network byte order, 5 bytes
10|000001 [64-bit]  -> 64-bit length in network byte order, 9 bytes
11|XXXXXX           -> Special encoding follows (see RDB_ENC_*)
```

Special encodings (when top 2 bits = `11`):

| Value | Constant | Meaning |
|-------|----------|---------|
| 0 | `RDB_ENC_INT8` | 8-bit signed integer |
| 1 | `RDB_ENC_INT16` | 16-bit signed integer |
| 2 | `RDB_ENC_INT32` | 32-bit signed integer |
| 3 | `RDB_ENC_LZF` | LZF-compressed string |

### Aux Fields

Written by `rdbSaveInfoAuxFields()`. Each aux field is:

```
[RDB_OPCODE_AUX = 0xFA] [key-string] [value-string]
```

Standard aux fields include: `valkey-ver`, `redis-bits`, `ctime`, `used-mem`, `aof-base`, `repl-id`, `repl-offset`, `repl-stream-db`.

### Database Section

Each database is preceded by:

```
[RDB_OPCODE_SELECTDB = 0xFE] [db-number]
[RDB_OPCODE_RESIZEDB = 0xFB] [db-size] [expires-size]
```

### Key-Value Pair Encoding

Written by `rdbSaveKeyValuePair()`:

```c
int rdbSaveKeyValuePair(rio *rdb, robj *key, robj *val,
                        long long expiretime, int dbid, int rdbver);
```

Each key-value pair layout:

```
[EXPIRETIME_MS opcode + 8-byte ms timestamp]  (optional)
[IDLE opcode + LRU idle seconds]              (optional, if maxmemory-policy is LRU)
[FREQ opcode + 1-byte LFU counter]           (optional, if maxmemory-policy is LFU)
[type byte]                                    RDB type (see below)
[key string]                                   Length-prefixed string
[value]                                        Type-specific encoding
```

### RDB Object Types

Defined in `enum RdbType` (rdb.h):

| Type | Value | Description |
|------|-------|-------------|
| `RDB_TYPE_STRING` | 0 | String value |
| `RDB_TYPE_LIST` | 1 | Legacy list |
| `RDB_TYPE_SET` | 2 | Set (hashtable encoding) |
| `RDB_TYPE_ZSET_2` | 5 | Sorted set with binary doubles |
| `RDB_TYPE_HASH` | 4 | Hash (hashtable encoding) |
| `RDB_TYPE_SET_INTSET` | 11 | Set as compact integer set |
| `RDB_TYPE_LIST_QUICKLIST_2` | 18 | List as quicklist v2 |
| `RDB_TYPE_HASH_LISTPACK` | 16 | Hash in listpack encoding |
| `RDB_TYPE_ZSET_LISTPACK` | 17 | Sorted set in listpack encoding |
| `RDB_TYPE_SET_LISTPACK` | 20 | Set in listpack encoding |
| `RDB_TYPE_STREAM_LISTPACKS_3` | 21 | Stream (latest format) |
| `RDB_TYPE_HASH_2` | 22 | Hash with field-level expiration (RDB 80, Valkey 9.0) |

### EOF and Checksum

```
[RDB_OPCODE_EOF = 0xFF]
[8-byte CRC64 checksum, little-endian]
```

The checksum is computed incrementally via `rdb->update_cksum = rioGenericUpdateChecksum` and written at the end. If `server.rdb_checksum` is disabled, the checksum is zero and the loader skips verification.

---

## BGSAVE Flow

### Entry Point

```c
int rdbSaveBackground(int req, char *filename, rdbSaveInfo *rsi, int rdbflags);
```

### Steps

1. **Pre-check**: `hasActiveChildProcess()` returns true if another child (RDB, AOF rewrite, or module) is already running. Only one child process at a time.

2. **Fork**: `serverFork(CHILD_TYPE_RDB)` calls `fork()`.

3. **Child process**:
   - Sets process title to `valkey-rdb-bgsave`
   - Sets CPU affinity from `server.bgsave_cpulist`
   - Calls `rdbSave()` which writes to a temp file `temp-<pid>.rdb`
   - `rdbSave()` calls `rdbSaveInternal()` which opens the file, initializes a `rio` with it, calls `rdbSaveRio()`, then fflush/fsync/fclose
   - On success, atomically `rename()` the temp file to the configured filename
   - Reports COW (copy-on-write) memory usage via `sendChildCowInfo()`
   - Exits with code 0 (success) or 1 (failure)

4. **Parent process**:
   - Records `server.rdb_save_time_start` and `server.rdb_child_type = RDB_CHILD_TYPE_DISK`
   - Continues serving clients normally
   - Periodically checks child status in `checkChildrenDone()` (called from server cron)
   - When child exits, `backgroundSaveDoneHandler()` is invoked

5. **Completion** (`backgroundSaveDoneHandlerDisk()`):
   - On success: adjusts `server.dirty`, updates `server.lastsave`
   - On signal kill: removes temp file, logs warning
   - Calls `updateReplicasWaitingBgsave()` to notify replicas waiting for a full sync

### rdbSaveRio - The Core Serialization

```c
int rdbSaveRio(int req, int rdbver, rio *rdb, int *error,
               int rdbflags, rdbSaveInfo *rsi);
```

This is the function that writes the entire RDB content:

1. Write 9-byte magic string (`VALKEY080` or `REDIS0011`)
2. Write aux fields via `rdbSaveInfoAuxFields()`
3. Write module aux data (before-RDB hook)
4. Write function libraries via `rdbSaveFunctions()`
5. For each database (0 to `server.dbnum`): write SELECTDB, RESIZEDB hints, then iterate all keys calling `rdbSaveKeyValuePair()`
6. Write module aux data (after-RDB hook)
7. Write `RDB_OPCODE_EOF`
8. Write CRC64 checksum

### Incremental Fsync

When `server.rdb_save_incremental_fsync` is enabled (default), `rioSetAutoSync(&rdb, REDIS_AUTOSYNC_BYTES)` triggers periodic fsync during writing to avoid a large burst of I/O at the end. The constant `REDIS_AUTOSYNC_BYTES` defaults to 4 MB.

---

## RDB Loading on Startup

### Entry Point

```c
int rdbLoad(char *filename, rdbSaveInfo *rsi, int rdbflags);
```

### Steps

1. Open the file, get its size via `fstat()`
2. Initialize a `rio` from the file handle
3. Call `rdbLoadRio()` which delegates to `rdbLoadRioWithLoadingCtx()`
4. Close file, stop loading progress tracking, reclaim page cache in background

### rdbLoadRioWithLoadingCtx - The Core Deserialization

```c
int rdbLoadRioWithLoadingCtx(rio *rdb, int rdbflags, rdbSaveInfo *rsi,
                              rdbLoadingCtx *rdb_loading_ctx);
```

1. Read 9-byte magic, determine if `REDIS` or `VALKEY` magic
2. Parse version number from bytes 7-9, validate with `rdbIsVersionAccepted()`
3. If `RDBFLAGS_EMPTY_DATA` is set, flush existing data first
4. Enter main loop reading one opcode at a time:
   - `RDB_OPCODE_EXPIRETIME` / `EXPIRETIME_MS`: stash expire for next key
   - `RDB_OPCODE_FREQ` / `IDLE`: stash LFU/LRU info for next key
   - `RDB_OPCODE_SELECTDB`: switch active database
   - `RDB_OPCODE_RESIZEDB`: pre-size hash tables
   - `RDB_OPCODE_AUX`: parse aux fields (repl-id, repl-offset, version, etc.)
   - `RDB_OPCODE_EOF`: break out of loop
   - Object types (0-22): load key string, load value via `rdbLoadObject()`, insert into database

### Return Values

| Constant | Meaning |
|----------|---------|
| `RDB_OK` | Successful load |
| `RDB_NOT_EXIST` | File does not exist (ENOENT) |
| `RDB_INCOMPATIBLE` | Invalid magic or unsupported version |
| `RDB_FAILED` | Corruption or I/O error |

---

## rdbSaveInfo - Replication Metadata in RDB

```c
typedef struct rdbSaveInfo {
    int repl_stream_db;                    // DB to SELECT in primary client
    int repl_id_is_set;                    // True if repl_id field is set
    char repl_id[CONFIG_RUN_ID_SIZE + 1];  // Replication ID
    long long repl_offset;                 // Replication offset
} rdbSaveInfo;
```

Populated by `rdbPopulateSaveInfo()`. When a primary saves an RDB, it embeds its replication ID and offset as aux fields. When a replica loads this RDB, it can attempt PSYNC with the same replication ID and offset, potentially avoiding a full resync if it reconnects.

---

## Diskless Replication

For replicas that support EOF markers (`REPLICA_CAPA_EOF`), the primary can send the RDB directly over the socket without writing to disk. This is handled by `rdbSaveToReplicasSockets()` and `rdbSaveRioWithEOFMark()`, which wraps the RDB stream with:

```
$EOF:<40-byte random hex marker>\r\n
[RDB data]
<same 40-byte marker>
```

The replica reads until it finds the EOF marker, knowing the transfer is complete without needing a content-length header.

---

## See Also

- [Replication Overview](../replication/overview.md) - RDB used for full resync
- [Dual-Channel Replication](../replication/dual-channel.md) - RDB transfer over dedicated channel
- [AOF Persistence](aof.md) - aof-use-rdb-preamble writes RDB as AOF BASE file
- [Data Structure Encoding](../data-structures/encoding-transitions.md) - RDB types correspond to in-memory encodings
- [Hashtable](../data-structures/hashtable.md) - Hashtable-encoded types serialized via hashtable API
- [Listpack](../data-structures/listpack.md) - Listpack-encoded objects serialized as raw byte blobs
- [Architecture Event Loop](../architecture/event-loop.md) - BGSAVE fork monitored by serverCron
