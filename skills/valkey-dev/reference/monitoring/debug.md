# Debug Facilities

Use when investigating server crashes, inspecting internal data structures,
or using the DEBUG command for development and testing.

Source: `src/debug.c` (2646 lines)

---

## Overview

debug.c contains the DEBUG command implementation, crash reporting
infrastructure, signal handlers, stack trace collection, the software watchdog,
and various diagnostic utilities. Most facilities here are for server developers
and operators diagnosing production issues - the DEBUG command itself is not
intended for application use.

## DEBUG Command Subcommands

### Object Introspection

**DEBUG OBJECT `<key>` [fast]**

Reports low-level details about a key's value object:
- Memory address and refcount
- Encoding type (raw, int, listpack, skiplist, quicklist, hashtable, etc.)
- Serialized length (skipped with `fast` flag - can be expensive)
- LRU/LFU eviction metadata
- For quicklist: node count, average fill, listpack max, compression flag,
  and total uncompressed size (unless `fast`)

**DEBUG SDSLEN `<key>`**

Reports SDS string internals for string-type keys:
- key_sds_len, key_sds_avail, obj_alloc
- val_sds_len, val_sds_avail, val_alloc

**DEBUG LISTPACK `<key>`** / **DEBUG QUICKLIST `<key>` [detail]**

Prints internal encoding structure to stdout (not to the client).

### Data Integrity

**DEBUG DIGEST**

Computes a SHA1 digest of the entire dataset. Uses XOR-based accumulation
so key ordering does not affect the result. Hash, set, and zset elements use
XOR (order-independent); lists use mixing (order-dependent).

**DEBUG DIGEST-VALUE `<key>` [key ...]**

Computes per-key SHA1 digests. Operates on logically expired keys (bypasses
expiry checks).

### Crash Simulation

| Subcommand | Effect |
|---|---|
| `SEGFAULT` | Maps read-only memory and writes to it |
| `PANIC` | Calls serverPanic with timestamp |
| `OOM` | Attempts zmalloc(SIZE_MAX/2) |
| `ASSERT` | Triggers serverAssertWithInfo(1 == 2) |

### Persistence Testing

**DEBUG RELOAD [MERGE] [NOFLUSH] [NOSAVE]**

Saves RDB, optionally flushes, then reloads. Options control whether to save
first, whether to flush existing data, and whether duplicate keys merge or
cause a fatal error.

**DEBUG LOADAOF**

Flushes AOF buffers, empties database, reloads AOF from disk.

### Server Control

| Subcommand | Purpose |
|---|---|
| `SLEEP <seconds>` | Blocks the server (decimals allowed) |
| `SET-ACTIVE-EXPIRE <0\|1>` | Toggle background expiration |
| `PAUSE-CRON <0\|1>` | Pause periodic cron processing |
| `DICT-RESIZING <0\|1>` | Enable/disable hashtable resizing |
| `LOG <message>` | Write to server log at WARNING level |
| `ERROR <string>` | Return a RESP error (for client testing) |
| `POPULATE <count> [prefix] [size]` | Create test keys (not replicated) |
| `CHANGE-REPL-ID` | Regenerate replication IDs |
| `CONFIG-REWRITE-FORCE-ALL` | Rewrite config including all defaults |

### Memory and Allocator

**DEBUG STRUCTSIZE**

Reports sizes of core C structures: robj, dictentry, sdshdr variants. Useful
for estimating memory overhead.

**DEBUG HTSTATS `<dbid>` [full]** / **DEBUG HTSTATS-KEY `<key>` [full]**

Hash table statistics for database-level or key-level hash tables.

**DEBUG CLIENT-EVICTION**

Dumps client memory usage bucket information (requires maxmemory-clients).

**DEBUG MALLCTL `<key>` [val]** / **DEBUG MALLCTL-STR `<key>` [val]**

Direct jemalloc mallctl interface (only available with jemalloc builds).

### Protocol Testing

**DEBUG PROTOCOL `<type>`**

Returns test values for each RESP3 type: string, integer, double, bignum,
null, array, set, map, attrib, push, verbatim, true, false. Used for client
library testing.

## Crash Reporting

When a fatal signal (SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT) is received,
`sigsegvHandler()` executes. It is installed via `setupSigSegvHandler()` at
startup when `server.crashlog_enabled` is true.

### Signal Handler Flow

1. Acquires `signal_handler_lock` (error-checking mutex to detect recursive
   crashes)
2. Logs signal number, si_code, faulting address, and killing PID if applicable
3. Extracts the instruction pointer (EIP) from the signal context
4. If EIP matches the faulting address (bad function pointer call), temporarily
   redirects EIP to a safe function to prevent backtrace from crashing
5. Calls `logStackTrace()` for all threads (or current thread only if recursive)
6. Logs CPU registers
7. Calls `printCrashReport()`
8. Dumps x86 code around the faulting instruction

### printCrashReport

```c
void printCrashReport(void) {
    server.crashed = 1;
    logServerInfo();                          /* INFO all + cluster info */
    logCurrentClient(server.current_client, "CURRENT");
    logCurrentClient(server.executing_client, "EXECUTING");
    logModulesInfo();                         /* Module details (last - may crash) */
    logConfigDebugInfo();                     /* Debug-relevant config values */
    doFastMemoryTest();                       /* Non-destructive memory test */
}
```

The fast memory test (`memtest_test_linux_anonymous_maps`) reads /proc/self/maps,
identifies anonymous RW memory regions, and runs a preserving memory test on
each. This can detect RAM errors without destroying data.

### bugReportEnd

Prints the closing banner with links to the Valkey GitHub issues page, removes
the PID file if daemonized. Exit paths:
- If `use_exit_on_panic` is enabled: calls `_exit(1)` (immediate termination, no core dump)
- Otherwise: calls `abort()` or re-raises the original signal to produce a core dump

## Stack Trace Collection

### Single-Thread

`writeCurrentThreadsStackTrace()` calls `backtrace()` for up to 100 frames,
then symbolizes via either libbacktrace (if available, forking a child process
for safety) or `backtrace_symbols_fd()`.

### Multi-Thread (Linux only)

`writeStacktraces()` collects stack traces from all threads:

1. Reads /proc/<pid>/task/ to enumerate thread IDs
2. Filters threads that block or ignore the signal (reads SigBlk/SigIgn from
   /proc/<pid>/task/<tid>/status)
3. Uses `ThreadsManager_runOnThreads()` to send a signal to each thread
4. Each thread's signal handler (`collect_stacktrace_data`) captures its own
   backtrace, thread name, and TID, then writes the data to a pipe
5. The main handler reads all pipe entries and symbolizes them

The current/calling thread is marked with `*` in the output.

### libbacktrace Integration

When built with `USE_LIBBACKTRACE`, symbolization forks a child process that
uses libbacktrace for file/line resolution. The parent waits up to 500ms
before killing the child. Falls back to `backtrace_symbols_fd()` on failure.

## Software Watchdog

The watchdog detects event loop stalls by scheduling SIGALRM delivery at a
configurable interval.

### Configuration

```
CONFIG SET watchdog-period <milliseconds>  -- 0 to disable
```

The minimum period is enforced as `2 * (1000 / server.hz)` to ensure the
timer fires between event loop iterations.

### Mechanism

```c
void watchdogScheduleSignal(int period) {
    struct itimerval it;
    it.it_value.tv_sec = period / 1000;
    it.it_value.tv_usec = (period % 1000) * 1000;
    it.it_interval.tv_sec = 0;   /* Non-repeating */
    it.it_interval.tv_usec = 0;
    setitimer(ITIMER_REAL, &it, NULL);
}
```

The timer is re-armed at the top of each `serverCron()` call. If the event loop
stalls (blocked command, slow I/O, etc.), the timer fires and `sigalrmSignalHandler`
logs a "WATCHDOG TIMER EXPIRED" warning with a full stack trace of all threads.

The handler distinguishes between watchdog expiry (`info->si_pid == 0`) and
explicit SIGALRM sent by another process (e.g. for diagnostic purposes).

## Assertion Infrastructure

Three assertion variants, all producing crash reports:

```c
void _serverAssert(const char *estr, const char *file, int line);
void _serverAssertWithInfo(const client *c, const robj *o, ...);
void _serverAssertPrintObject(const robj *o);
```

`_serverAssert` logs the expression, file, and line, then captures a stack
trace and crash report. `_serverAssertWithInfo` additionally dumps client
context (flags, connection info, full argument vector) and object debug info
(type, encoding, refcount).

The `shouldRedactArg()` function controls whether command arguments appear in
crash logs. When `server.hide_user_data_from_log` is enabled, arguments are
replaced with byte lengths. AUTH/AUTH2 commands always truncate after the
command name.

## Utility Functions

**debugDelay(int usec)** - Probabilistic sub-microsecond delays. Negative
values mean "1/N chance of sleeping 1 microsecond" (e.g. -10 means 100ns
average).

**debugPauseProcess()** - Raises SIGSTOP for attaching a debugger.

**serverLogHexDump()** - Writes hex dump of arbitrary memory to the server log.

**dumpX86Calls(addr, len)** - Scans memory for E8 (CALL) opcodes and resolves
targets via dladdr. Used to understand what functions surround a crash site.

---

## See Also

- [Latency Monitoring](../monitoring/latency.md) - the software watchdog here detects event loop stalls; latency monitoring records their duration as latency events
- [Commandlog](../monitoring/commandlog.md) - `DEBUG SLEEP` triggers commandlog slow entries; `DEBUG POPULATE` can generate large-request entries
- [zmalloc](../memory/zmalloc.md) - `DEBUG STRUCTSIZE` reports core struct sizes relevant to memory overhead; `DEBUG MALLCTL` directly queries jemalloc internals
- [Active Defragmentation](../memory/defragmentation.md) - `DEBUG DICT-RESIZING` can disable hashtable resizing to isolate defrag behavior during testing
- [Configuration System](../config/config-system.md) - `DEBUG CONFIG-REWRITE-FORCE-ALL` exercises the config rewrite path with all defaults included
- [Sanitizer Builds](../build/sanitizers.md) - Debug builds with `make noopt` or `make valgrind` are essential for effective use of debug facilities. ASan and UBSan catch memory errors that crash reports help diagnose. The software watchdog and stack trace collection work best with `-fno-omit-frame-pointer` (included in sanitizer builds).
