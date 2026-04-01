# AOF (Append-Only File) Persistence

Use when you need to understand how Valkey logs every write command for durability, the multi-part AOF architecture, the rewrite process, or fsync policies.

Source file: `src/aof.c`

## Contents

- Multi-Part AOF Architecture (line 21)
- How Commands Are Appended (line 65)
- Fsync Policies (line 97)
- AOF Loading and Recovery (line 138)
- AOF Rewrite (BGREWRITEAOF) (line 168)
- Hybrid RDB+AOF Preamble Mode (line 217)
- AOF State Machine (line 237)
- Key Configuration Parameters (line 249)
- See Also (line 265)

---

## Multi-Part AOF Architecture

Since Valkey 7.0, AOF uses a manifest-based system with multiple files instead of a single monolithic file. All files live in the `appendonlydir/` directory (configured by `appenddirname`).

### File Types

| Type | Suffix | Description |
|------|--------|-------------|
| BASE | `.base.rdb` or `.base.aof` | Snapshot at the time of last AOF rewrite |
| INCR | `.incr.aof` | Incremental write commands since last rewrite |
| HISTORY | (same suffixes) | Previous BASE/INCR files awaiting deletion |

### Manifest File

The manifest tracks all active AOF files. Format: one line per file.

```
file appendonly.aof.2.base.rdb seq 2 type b
file appendonly.aof.4.incr.aof seq 4 type i
file appendonly.aof.5.incr.aof seq 5 type i
```

Type codes: `b` = base, `i` = incremental, `h` = history.

### Key Structures

```c
aofManifest *aofManifestCreate(void);
// Contains:
//   aofInfo *base_aof_info;       // Current BASE file (at most one)
//   list *incr_aof_list;          // Ordered list of INCR files
//   list *history_aof_list;       // Files pending deletion
```

```c
typedef struct aofInfo {
    sds file_name;
    long long file_seq;
    aof_file_type file_type;  // 'b', 'i', or 'h'
} aofInfo;
```

---

## How Commands Are Appended

### feedAppendOnlyFile

```c
void feedAppendOnlyFile(int dictid, robj **argv, int argc);
```

Called from `propagateNow()` in `server.c` whenever a write command needs to be persisted. This is the same propagation path used for replication.

Steps:
1. If timestamps are enabled, prepend a `#TS:<unix_time>\r\n` annotation
2. If the target DB differs from the last SELECT, prepend a `SELECT <db>` command
3. Convert the command to RESP format via `catAppendOnlyGenericCommand()`
4. Append to `server.aof_buf` (an in-memory sds buffer)

The buffer is flushed to disk by `flushAppendOnlyFile()` before re-entering the event loop.

### RESP Command Format

`catAppendOnlyGenericCommand()` produces standard RESP multi-bulk format:

```c
sds catAppendOnlyGenericCommand(sds dst, int argc, robj **argv);
// Example output for SET foo bar:
// *3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n
```

Commands are stored in the same RESP wire format used by replication - there is no AOF-specific translation.

---

## Fsync Policies

Controlled by the `appendfsync` configuration. Implemented in `flushAppendOnlyFile()`.

### AOF_FSYNC_ALWAYS

```c
if (server.aof_fsync == AOF_FSYNC_ALWAYS) {
    valkey_fsync(server.aof_fd);  // fdatasync() on Linux
}
```

Fsync after every write. Maximum durability (at most one command lost on crash). Highest latency impact since fsync blocks the main thread.

### AOF_FSYNC_EVERYSEC (default)

```c
if (server.aof_fsync == AOF_FSYNC_EVERYSEC &&
    server.mstime - server.aof_last_fsync >= 1000) {
    if (!sync_in_progress) {
        aof_background_fsync(server.aof_fd);
    }
}
```

Background fsync via BIO thread every second. The write itself (to kernel buffer) happens in the main thread, but fsync is offloaded. At most ~1 second of data loss on crash.

Write postponement logic: if a background fsync is still running when the next write is due, the write is delayed up to 2 seconds. After that, the write proceeds anyway and `server.aof_delayed_fsync` is incremented.

```c
void aof_background_fsync(int fd) {
    bioCreateFsyncJob(fd, server.primary_repl_offset, 1);
}
```

### AOF_FSYNC_NO

No explicit fsync. Relies on the OS to flush data to disk (every ~30 seconds on Linux). Best performance, worst durability.

---

## AOF Loading and Recovery

### loadAppendOnlyFiles

```c
int loadAppendOnlyFiles(aofManifest *am);
```

Called on startup when `appendonly yes` is configured.

1. Check for old single-file AOF format and upgrade if needed (`aofUpgradePrepare()`)
2. Load the BASE file first (if it exists) via `loadSingleAppendOnlyFile()`
3. Load each INCR file in sequence order
4. Only the last file is allowed to be truncated (recoverable); truncation in earlier files is fatal

### loadSingleAppendOnlyFile

1. Open the file and check for RDB preamble (first 6 bytes are `REDIS0` or `VALKEY`)
2. If RDB preamble detected: load via `rdbLoadRio()`, then continue reading AOF commands after the RDB section
3. If pure AOF: create a fake client, parse RESP commands, and execute them one by one
4. Track `valid_up_to` offset for truncation recovery

### Recovery Behavior

- If the last INCR file is truncated at a command boundary, the server logs a warning and continues
- If truncated mid-command, the server truncates the file to the last valid offset
- If any file other than the last is truncated, the server refuses to start

---

## AOF Rewrite (BGREWRITEAOF)

The rewrite process compacts the AOF by writing the current dataset state as a new BASE file, replacing the accumulation of incremental commands.

### rewriteAppendOnlyFileBackground

```c
int rewriteAppendOnlyFileBackground(void);
```

The background rewrite process, documented in the source:

```
1) The user calls BGREWRITEAOF
2) The server calls this function, that forks():
   2a) the child rewrites the append only file in a temp file.
   2b) the parent opens a new INCR AOF file to continue writing.
3) When the child finishes '2a' it exits.
4) The parent will trap the exit code, if it's OK, it will:
   4a) get a new BASE file name and mark the previous as HISTORY
   4b) rename the temp file to the new BASE file name
   4c) mark the rewritten INCR AOFs as history type
   4d) persist AOF manifest file
   4e) Delete the history files via bio
```

### Detailed Steps

1. **Pre-fork**: Flush current AOF buffer, open a new INCR file (`openNewIncrAofForAppend()`). This ensures commands arriving during the rewrite go to a fresh INCR file.

2. **Fork**: `serverFork(CHILD_TYPE_AOF)` creates the child process.

3. **Child process** calls `rewriteAppendOnlyFile()`:
   - If `aof-use-rdb-preamble` is enabled (default: yes): writes an RDB snapshot via `rdbSaveRio()` with `RDBFLAGS_AOF_PREAMBLE`
   - If disabled: calls `rewriteAppendOnlyFileRio()` which iterates all databases and reconstructs each key as write commands (RPUSH, SADD, ZADD, HSET, etc.)
   - Uses variadic commands (up to `AOF_REWRITE_ITEMS_PER_CMD` items per command) to minimize command count
   - Writes to temp file `temp-rewriteaof-bg-<pid>.aof`, then fflush/fsync/close

4. **Parent process**: continues writing to the new INCR file while the child works. No AOF rewrite buffer is needed (unlike pre-7.0 versions) because incremental data goes directly to the new INCR file.

5. **Completion** (`backgroundRewriteDoneHandler()`):
   - Rename temp file to new BASE file name
   - If in `AOF_WAIT_REWRITE` state (replica during full sync), also rename the temporary INCR file
   - Mark old BASE and INCR files as HISTORY in the manifest
   - Persist the updated manifest atomically
   - Delete HISTORY files via background I/O thread

---

## Hybrid RDB+AOF Preamble Mode

When `aof-use-rdb-preamble yes` (the default), the BASE file produced during AOF rewrite is an RDB snapshot. The INCR files that follow contain RESP commands.

On loading, `loadSingleAppendOnlyFile()` detects the RDB magic bytes at the start of the BASE file and loads it via `rdbLoadRio()`. Any INCR files after the BASE are loaded as RESP commands.

This gives the fast loading speed of RDB for the bulk of the data, with the append-only durability guarantees of AOF for recent changes.

```c
// In rewriteAppendOnlyFile():
if (server.aof_use_rdb_preamble) {
    rdbSaveRio(REPLICA_REQ_NONE, RDB_VERSION, &aof, &error,
               RDBFLAGS_AOF_PREAMBLE, NULL);
} else {
    rewriteAppendOnlyFileRio(&aof);
}
```

---

## AOF State Machine

| State | Meaning |
|-------|---------|
| `AOF_OFF` | AOF disabled |
| `AOF_ON` | Normal AOF operation |
| `AOF_WAIT_REWRITE` | Waiting for the first AOF rewrite to complete (used during replica full sync to enable AOF after the RDB load) |

The `AOF_WAIT_REWRITE` state is entered when a replica transitions to having AOF enabled. It uses a temporary INCR file to accumulate commands until the first BGREWRITEAOF completes, at which point the files are renamed and the manifest is written.

---

## Key Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `appendonly` | no | Enable AOF persistence |
| `appendfilename` | appendonly.aof | Base name for AOF files |
| `appenddirname` | appendonlydir | Directory for AOF files |
| `appendfsync` | everysec | Fsync policy: always, everysec, no |
| `no-appendfsync-on-rewrite` | no | Skip fsync during BGSAVE/AOFRW |
| `auto-aof-rewrite-percentage` | 100 | Trigger AOFRW when AOF grows by this percentage |
| `auto-aof-rewrite-min-size` | 64mb | Minimum AOF size before auto-rewrite triggers |
| `aof-use-rdb-preamble` | yes | Use RDB format for the BASE file |
| `aof-timestamp-enabled` | no | Include timestamp annotations in AOF |

---
