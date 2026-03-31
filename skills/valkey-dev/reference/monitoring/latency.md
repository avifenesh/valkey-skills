# Latency Monitoring

Use when diagnosing latency spikes, understanding which server subsystems are
introducing delays, or generating latency reports with LATENCY DOCTOR.

Source: `src/latency.c`, `src/latency.h`

## Contents

- Overview (line 22)
- Configuration (line 30)
- Data Structures (line 40)
- Core Function: latencyAddSample (line 85)
- Instrumentation Macros (line 99)
- Event Types and Their Callers (line 111)
- Duration Stats (line 140)
- Client Commands (line 157)
- See Also (line 195)

---

## Overview

The latency monitoring framework samples operations that exceed a configurable
threshold (in milliseconds) and stores them in per-event time series. Each event
type (fork, command, aof-write, etc.) maintains an independent circular buffer
of 160 samples. The framework also includes a diagnostic report generator
(LATENCY DOCTOR) and per-command latency histograms using HdrHistogram.

## Configuration

```
CONFIG SET latency-monitor-threshold <milliseconds>
```

Default is 0 (disabled). When disabled, the monitoring macros short-circuit
and add no overhead. The threshold applies globally to all event types - any
operation taking longer than this value is recorded.

## Data Structures

### Sample (`latency.h`)

```c
struct latencySample {
    int32_t time;     /* Unix timestamp, forced to 4 bytes. */
    uint32_t latency; /* Latency in milliseconds. */
};
```

### Time Series (`latency.h`)

```c
#define LATENCY_TS_LEN 160

struct latencyTimeSeries {
    int idx;                                      /* Index of the next sample to store. */
    uint32_t max;                                 /* All-time max latency for this event. */
    uint32_t sum;                                 /* Cumulative sum of all samples. */
    uint32_t cnt;                                 /* Total number of samples ever added. */
    struct latencySample samples[LATENCY_TS_LEN]; /* Circular buffer. */
};
```

### Statistics (`latency.h`)

```c
struct latencyStats {
    uint32_t all_time_high;
    uint32_t avg;
    uint32_t min;
    uint32_t max;
    uint32_t mad;       /* Mean absolute deviation. */
    uint32_t samples;   /* Number of non-zero samples in the buffer. */
    time_t period;      /* Seconds since first event. */
};
```

### Storage

All time series are stored in `server.latency_events`, a dict keyed by event
name string. Series are created on demand when the first sample arrives for a
given event.

## Core Function: latencyAddSample

```c
void latencyAddSample(const char *event, ustime_t latency_us);
```

Accepts latency in microseconds, converts to milliseconds internally. If two
samples arrive in the same second, only the higher value is kept (the existing
sample is updated rather than a new slot consumed). This keeps the circular
buffer from being dominated by bursts within a single second.

The function also maintains running `max`, `sum`, and `cnt` fields that persist
across buffer wraparound. The `max` field is never reset except by LATENCY RESET.

## Instrumentation Macros

```c
latencyStartMonitor(var)              /* Capture ustime() into var */
latencyEndMonitor(var)                /* Replace var with elapsed time */
latencyAddSampleIfNeeded(event, var)  /* Record if >= threshold */
latencyRemoveNestedEvent(event_var, nested_var)  /* Subtract nested timing */
```

The start/end/sample macros short-circuit when `server.latency_monitor_threshold == 0`.
`latencyRemoveNestedEvent` executes unconditionally (no threshold check).

## Event Types and Their Callers

Events are identified by string names. The server instruments these call sites:

| Event | Source file | What it measures |
|---|---|---|
| `command` | server.c | Slow command execution (O(N) commands, etc.) |
| `fast-command` | server.c | Command that should be fast but exceeded threshold |
| `fork` | server.c | fork() for RDB/AOF background save |
| `expire-cycle` | expire.c | Active expiration sweep |
| `expire-del` | db.c | Individual key deletion during expiration |
| `eviction-cycle` | evict.c | Full eviction loop |
| `eviction-del` | evict.c | Individual key eviction deletion |
| `eviction-lazyfree` | evict.c | Lazy free during eviction |
| `aof-write` | aof.c | AOF write syscall |
| `aof-write-pending-fsync` | aof.c | AOF write while fsync pending |
| `aof-write-active-child` | aof.c | AOF write with active child process |
| `aof-write-alone` | aof.c | AOF write with no child/fsync contention |
| `aof-fsync-always` | aof.c | AOF fsync in always mode |
| `aof-fstat` | aof.c | fstat call on AOF file |
| `aof-rename` | aof.c | AOF atomic rename |
| `aof-rewrite-diff-write` | latency.c (DOCTOR only) | Recognized by LATENCY DOCTOR but not currently instrumented |
| `rdb-unlink-temp-file` | rdb.c | Unlinking temporary RDB file |
| `active-defrag-cycle` | defrag.c | Active defragmentation cycle |
| `command-unblocking` | blocked.c | Unblocking a blocked client |
| `while-blocked-cron` | server.c | Cron tasks during blocked operation |
| `module-acquire-GIL` | server.c | Module acquiring the global lock |
| `cluster-config-*` | cluster_legacy.c | Various cluster config persistence steps |

## Duration Stats

Separate from the latency monitor, Valkey also tracks cumulative duration
metrics via `durationAddSample()`:

```c
typedef enum {
    EL_DURATION_TYPE_EL = 0,  /* Whole event loop */
    EL_DURATION_TYPE_CMD,     /* Command execution */
    EL_DURATION_TYPE_AOF,     /* AOF flush in event loop */
    EL_DURATION_TYPE_CRON,    /* serverCron + beforeSleep excluding IO/AOF */
    EL_DURATION_TYPE_NUM
} DurationType;
```

These track count, sum, and max for each type, reported via INFO.

## Client Commands

### LATENCY LATEST

Returns one entry per active event: `[event, timestamp, latency_ms, max_ms, sum_ms, count]`.

### LATENCY HISTORY `<event>`

Returns all non-zero samples for the event as `[timestamp, latency_ms]` pairs,
ordered oldest to newest from the circular buffer.

### LATENCY GRAPH `<event>`

Generates an ASCII sparkline chart showing latency over time, with labels
indicating how long ago each sample was recorded (e.g. "3s", "2m", "1h").

### LATENCY DOCTOR

Runs `createLatencyReport()` which analyzes all events, computes statistics
via `analyzeLatencyForEvent()`, and produces human-readable advice. It checks
for THP (Transparent Huge Pages), evaluates fork rate quality, and suggests
specific configuration changes (hz tuning, commandlog thresholds, fsync policy,
disk contention mitigation, etc.).

### LATENCY RESET [event ...]

Deletes time series for specified events (or all if none specified). Returns
the count of reset events.

### LATENCY HISTOGRAM [command ...]

Returns per-command latency distributions using HdrHistogram. Each command
entry includes total call count and a histogram of latency buckets in
microseconds. Buckets use logarithmic scaling (base 2, starting at 1024ns).
If no commands are specified, all commands with data are returned.

---

## See Also

- [Commandlog](../monitoring/commandlog.md) - records individual slow/large commands; LATENCY DOCTOR may suggest adjusting the commandlog threshold (`commandlog-execution-slower-than`)
- [Active Defragmentation](../memory/defragmentation.md) - the `active-defrag-cycle` latency event tracks defrag overhead
- [Key Expiration](../config/expiry.md) - the `expire-cycle` and `expire-del` events measure active expiration cost
- [AOF Persistence](../persistence/aof.md) - multiple AOF-related latency events (aof-write, aof-fsync-always, aof-write-pending-fsync)
- [Debug Facilities](../monitoring/debug.md) - the software watchdog detects event loop stalls that would also appear as latency spikes
- [Building Valkey](../build/building.md) - the vendored `deps/hdr_histogram/` library provides per-command latency histograms accessed via `LATENCY HISTOGRAM`. Build with `make noopt` for debugging latency issues with a debugger attached.
