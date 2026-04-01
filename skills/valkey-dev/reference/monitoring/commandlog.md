# Commandlog

Use when investigating slow commands, oversized requests, or oversized replies
in a running Valkey instance.

Source: `src/commandlog.c`, `src/commandlog.h`

## Contents

- Overview (line 22)
- Log Types (line 29)
- Data Structures (line 45)
- Configuration (line 76)
- How Commands Are Logged (line 90)
- Client Commands (line 123)
- Timing Measurement (line 149)
- Memory Management (line 160)
- See Also (line 171)

---

## Overview

The commandlog (evolved from the legacy slowlog) records commands that exceed
configurable thresholds across three dimensions: execution time, request size,
and reply size. Entries are stored in memory and accessed via the COMMANDLOG and
SLOWLOG commands - nothing is written to disk or the server log file.

## Log Types

Defined in `server.h` as an enum:

```c
typedef enum {
    COMMANDLOG_TYPE_SLOW = 0,
    COMMANDLOG_TYPE_LARGE_REQUEST,
    COMMANDLOG_TYPE_LARGE_REPLY,
    COMMANDLOG_TYPE_NUM
} commandlog_type;
```

Each type has its own independent entry list, entry ID counter, threshold, and
max length. All three are stored in `server.commandlog[COMMANDLOG_TYPE_NUM]`.

## Data Structures

### Per-type state (`server.h`)

```c
typedef struct commandlog {
    list *entries;
    long long entry_id;
    long long threshold;
    unsigned long max_len;
} commandlog;
```

### Entry structure (`commandlog.h`)

```c
typedef struct commandlogEntry {
    robj **argv;
    int argc;
    long long id;    /* Unique entry identifier. */
    long long value; /* Microseconds for slow; bytes for large-request/large-reply. */
    time_t time;     /* Unix time at which the command was executed. */
    sds cname;       /* Client name. */
    sds peerid;      /* Client network address. */
} commandlogEntry;
```

Truncation limits prevent unbounded memory growth:
- `COMMANDLOG_ENTRY_MAX_ARGC` = 32 (extra args replaced with "... (N more arguments)")
- `COMMANDLOG_ENTRY_MAX_STRING` = 128 bytes per argument (truncated with "... (N more bytes)")

## Configuration

| Config directive | Alias | Default | Unit | Type |
|---|---|---|---|---|
| `commandlog-execution-slower-than` | `slowlog-log-slower-than` | 10000 | microseconds | slow |
| `commandlog-request-larger-than` | - | 1048576 | bytes | large-request |
| `commandlog-reply-larger-than` | - | 1048576 | bytes | large-reply |
| `commandlog-slow-execution-max-len` | `slowlog-max-len` | 128 | entries | slow |
| `commandlog-large-request-max-len` | - | 128 | entries | large-request |
| `commandlog-large-reply-max-len` | - | 128 | entries | large-reply |

Setting a threshold to -1 disables that log type. Setting max-len to 0 also
disables it.

## How Commands Are Logged

Entry point is `commandlogPushCurrentCommand()`, called after every command
completes. It checks all three types in sequence:

```c
void commandlogPushCurrentCommand(client *c, struct serverCommand *cmd) {
    if (cmd->flags & CMD_SKIP_COMMANDLOG) return;

    robj **argv = c->original_argv ? c->original_argv : c->argv;
    int argc = c->original_argv ? c->original_argc : c->argc;

    long duration = c->duration;
    unsigned long long net_input_bytes_curr_cmd = c->net_input_bytes_curr_cmd;
    unsigned long long net_output_bytes_curr_cmd = c->net_output_bytes_curr_cmd;

    c = scriptIsRunning() ? scriptGetCaller() : c;

    commandlogPushEntryIfNeeded(c, argv, argc, duration, COMMANDLOG_TYPE_SLOW);
    commandlogPushEntryIfNeeded(c, argv, argc, net_input_bytes_curr_cmd, COMMANDLOG_TYPE_LARGE_REQUEST);
    commandlogPushEntryIfNeeded(c, argv, argc, net_output_bytes_curr_cmd, COMMANDLOG_TYPE_LARGE_REPLY);
}
```

Key behaviors:
- Commands flagged `CMD_SKIP_COMMANDLOG` (e.g. those with sensitive data) are
  never logged.
- If the command argv was rewritten internally, the original argv is logged.
- During script execution, metrics come from the executing client but identity
  (peerid, cname) comes from the script caller.
- The list is kept trimmed: when an entry is added to the head, excess entries
  are removed from the tail.

## Client Commands

### SLOWLOG (legacy, operates on slow type only)

```
SLOWLOG GET [<count>]     -- default 10, -1 for all
SLOWLOG LEN
SLOWLOG RESET
```

### COMMANDLOG (new, requires explicit type)

```
COMMANDLOG GET <count> <type>    -- type: slow | large-request | large-reply
COMMANDLOG LEN <type>
COMMANDLOG RESET <type>
```

Each GET entry is a 6-element array:
1. Unique ID (monotonically increasing per type)
2. Unix timestamp
3. Value (microseconds for slow, bytes for large-request/large-reply)
4. Command arguments array
5. Client IP:port
6. Client name

## Timing Measurement

The `value` field for slow commands is `c->duration`, which is measured in
microseconds by the server's command execution pipeline. The server records
`ustime()` before and after `call()` to compute the elapsed duration. This
is wall-clock time, not CPU time.

For large-request and large-reply types, the value is the byte count of the
network I/O for that specific command (`c->net_input_bytes_curr_cmd` and
`c->net_output_bytes_curr_cmd`).

## Memory Management

String objects in entries are duplicated (not shared) to avoid races with
FLUSHALL ASYNC. Shared refcount objects are stored directly. Entry cleanup
frees all argv objects, the peerid/cname SDS strings, and the entry itself.

Initialization in `commandlogInit()` creates one linked list per type with a
custom free method that calls `commandlogFreeEntry`.

---
