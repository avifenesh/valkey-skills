# Event Loop Architecture

Use when you need to understand how Valkey multiplexes I/O, processes timers, or hooks into the event cycle.

## Contents

- Overview (line 20)
- Backend Selection (line 24)
- Core Data Structures (line 46)
- Key Functions (line 98)
- The AE_BARRIER Flag (line 175)
- The beforeSleep Hook (`server.c:1812`) (line 181)
- The afterSleep Hook (`server.c:2015`) (line 202)
- The epoll Backend (`ae_epoll.c`) (line 211)
- Thread Safety (line 226)
- See Also (line 230)

---

## Overview

Valkey implements its own reactor pattern via the `ae` library (`ae.c`, `ae.h`) rather than using libuv or libevent. The design is deliberately minimal - about 570 lines of C - with platform-specific I/O multiplexing backends selected at compile time.

## Backend Selection

The backend is chosen by `#include` chain in `ae.c:50-64`, preferring the fastest available:

```c
#ifdef HAVE_EVPORT
#include "ae_evport.c"     /* Solaris event ports */
#else
#ifdef HAVE_EPOLL
#include "ae_epoll.c"      /* Linux epoll */
#else
#ifdef HAVE_KQUEUE
#include "ae_kqueue.c"     /* macOS/BSD kqueue */
#else
#include "ae_select.c"     /* POSIX select (fallback) */
#endif
#endif
#endif
```

Each backend implements the same internal API: `aeApiCreate`, `aeApiResize`, `aeApiFree`, `aeApiAddEvent`, `aeApiDelEvent`, `aeApiPoll`, `aeApiName`.

## Core Data Structures

### aeEventLoop (`ae.h:104`)

```c
typedef struct aeEventLoop {
    int maxfd;                    /* highest file descriptor currently registered */
    int setsize;                  /* max number of file descriptors tracked */
    long long timeEventNextId;
    aeFileEvent *events;          /* Registered events (indexed by fd) */
    aeFiredEvent *fired;          /* Fired events (filled by aeApiPoll) */
    aeTimeEvent *timeEventHead;   /* Linked list of time events */
    int stop;                     /* Set to 1 to break the loop */
    void *apidata;                /* Backend-specific data (epoll fd, etc.) */
    aeBeforeSleepProc *beforesleep;
    aeAfterSleepProc *aftersleep;
    aeCustomPollProc *custompoll;
    pthread_mutex_t poll_mutex;   /* Protects poll operations for I/O threads */
    int flags;
} aeEventLoop;
```

### aeFileEvent (`ae.h:77`)

```c
typedef struct aeFileEvent {
    int mask;             /* AE_READABLE | AE_WRITABLE | AE_BARRIER */
    aeFileProc *rfileProc; /* Read callback */
    aeFileProc *wfileProc; /* Write callback */
    void *clientData;
} aeFileEvent;
```

File events are stored in an array indexed by file descriptor. This gives O(1) lookup.

### aeTimeEvent (`ae.h:85`)

```c
typedef struct aeTimeEvent {
    long long id;
    monotime when;                  /* Absolute fire time in microseconds */
    aeTimeProc *timeProc;
    aeEventFinalizerProc *finalizerProc;
    void *clientData;
    struct aeTimeEvent *prev;
    struct aeTimeEvent *next;
    int refcount;                   /* Prevents freeing during recursive calls */
} aeTimeEvent;
```

Time events are stored in an unsorted doubly-linked list. Finding the earliest timer is O(N), but Valkey typically has only 2-3 time events (serverCron, clientsTimeProc), so this is not a bottleneck.

## Key Functions

### aeCreateEventLoop (`ae.c:76`)

```c
aeEventLoop *aeCreateEventLoop(int setsize);
```

Allocates the event loop with capacity for `setsize` file descriptors. Called during `initServer()` with `maxclients + CONFIG_FDSET_INCR`. Initializes the monotonic clock, creates the backend (e.g., `epoll_create`), and zeros all event masks to `AE_NONE`.

### aeCreateFileEvent (`ae.c:185`)

```c
int aeCreateFileEvent(aeEventLoop *eventLoop, int fd, int mask,
                      aeFileProc *proc, void *clientData);
```

Registers a file descriptor for read/write monitoring. The `mask` is one or more of `AE_READABLE`, `AE_WRITABLE`, `AE_BARRIER`. Uses a mutex lock when `AE_PROTECT_POLL` is set (for I/O thread safety). Delegates to the backend's `aeApiAddEvent` which calls `epoll_ctl(EPOLL_CTL_ADD/MOD)` on Linux.

### aeCreateTimeEvent (`ae.c:261`)

```c
long long aeCreateTimeEvent(aeEventLoop *eventLoop, long long milliseconds,
                            aeTimeProc *proc, void *clientData,
                            aeEventFinalizerProc *finalizerProc);
```

Creates a timer that fires after `milliseconds`. The `timeProc` callback returns either `AE_NOMORE` (-1) to delete the event, or a positive number of milliseconds to reschedule. This is how `serverCron` implements its recurring timer - it returns `1000/server.hz`.

### aeMain (`ae.c:540`)

```c
void aeMain(aeEventLoop *eventLoop) {
    eventLoop->stop = 0;
    while (!eventLoop->stop) {
        aeProcessEvents(eventLoop, AE_ALL_EVENTS |
                        AE_CALL_BEFORE_SLEEP |
                        AE_CALL_AFTER_SLEEP);
    }
}
```

The server's main loop. Runs until `aeStop()` sets `stop = 1`. Each iteration processes all pending file and time events.

### aeProcessEvents (`ae.c:411`)

The heart of the event loop. Each call:

```
aeProcessEvents(eventLoop, flags)
  |
  +-- 1. Call beforesleep() if AE_CALL_BEFORE_SLEEP is set
  |
  +-- 2. Calculate poll timeout:
  |     - AE_DONT_WAIT: timeout = 0 (non-blocking)
  |     - Has time events: timeout = microseconds until earliest timer
  |     - Otherwise: timeout = infinite (block until event)
  |
  +-- 3. Call aeApiPoll() (or custompoll if set)
  |     Blocks on epoll_wait/kqueue/select
  |     Fills eventLoop->fired[] with ready descriptors
  |
  +-- 4. Call aftersleep() if AE_CALL_AFTER_SLEEP is set
  |
  +-- 5. Process fired file events:
  |     For each fired fd:
  |       - Normally: read callback first, then write callback
  |       - With AE_BARRIER: write first, then read (used for AOF fsync)
  |       - Skip if same proc and already fired for other mask
  |
  +-- 6. Process time events (processTimeEvents)
  |     Walk the linked list, fire any whose `when <= now`
  |     Reschedule or mark for deletion based on return value
  |
  +-- Return total events processed
```

## The AE_BARRIER Flag

When `AE_BARRIER` is set alongside `AE_WRITABLE`, the event loop inverts the normal read-then-write order for that fd. The write callback fires first, then the read callback.

This is used for the `appendfsync always` policy: by using `AE_BARRIER`, the write handler fires first to send replies to clients, then the read handler can trigger fsync knowing replies are already flushed.

## The beforeSleep Hook (`server.c:1812`)

Called at the start of every event loop iteration, before blocking on I/O. Handles:

1. **I/O thread coordination** - send poll job to I/O threads if enabled
2. **Peak memory tracking** - update `stat_peak_memory`
3. **I/O thread read completions** - process results from threaded reads
4. **Pending TLS data** - handle buffered TLS reads
5. **Cluster housekeeping** - `clusterBeforeSleep()`
6. **Blocked client handling** - `blockedBeforeSleep()`
7. **Fast expire cycle** - quick pass of active key expiration
8. **Module events** - fire `EVENTLOOP_BEFORE_SLEEP` hook
9. **Replica ACK requests** - send REPLCONF GETACK if needed
10. **Failover status** - check and update
11. **Client-side caching** - broadcast invalidation messages
12. **AOF flush** - write `aof_buf` to disk, fsync if needed
13. **Pending writes** - flush client output buffers (`handleClientsWithPendingWrites`)
14. **I/O thread write completions** - process results from threaded writes
15. **Async client cleanup** - free clients in the close queue
16. **Cron duration tracking** - record time spent outside poll

## The afterSleep Hook (`server.c:2015`)

Called after `aeApiPoll()` returns, before processing fired events:

1. **Module GIL** - re-acquire the module Global Interpreter Lock
2. **Time cache** - update `server.unixtime`, `server.mstime`, etc.
3. **Command time snapshot** - set `server.cmd_time_snapshot`
4. **I/O thread scaling** - `adjustIOThreadsByEventLoad()` - dynamically scale active I/O threads based on event volume

## The epoll Backend (`ae_epoll.c`)

On Linux, the backend stores an epoll fd and an events array:

```c
typedef struct aeApiState {
    int epfd;
    struct epoll_event *events;
} aeApiState;
```

- `aeApiCreate`: calls `epoll_create(1024)`, sets `CLOEXEC`
- `aeApiAddEvent`: calls `epoll_ctl` with `EPOLL_CTL_ADD` (new fd) or `EPOLL_CTL_MOD` (existing fd)
- `aeApiPoll`: calls `epoll_wait`, converts `EPOLLIN`/`EPOLLOUT`/`EPOLLERR`/`EPOLLHUP` to `AE_READABLE`/`AE_WRITABLE` masks

## Thread Safety

The event loop uses `AE_PROTECT_POLL` and a mutex (`poll_mutex`) to allow I/O threads to safely modify file events while the main thread might be in `aeApiPoll`. The `AE_LOCK`/`AE_UNLOCK` macros wrap `pthread_mutex_lock/unlock` and are used in `aeCreateFileEvent`, `aeDeleteFileEvent`, `aeResizeSetSize`, and `aePoll`.

## See Also

- [overview.md](overview.md) - Boot sequence that creates the event loop
- [networking.md](networking.md) - How client connections register file events
- [command-dispatch.md](command-dispatch.md) - What happens inside file event callbacks
- [../valkey-specific/transport-layer.md](../valkey-specific/transport-layer.md) - Connection types that register file events with the ae loop
- [../persistence/rdb.md](../persistence/rdb.md) - BGSAVE forks from the main process; the child inherits the dataset while the parent continues the event loop. The `AE_BARRIER` flag and `beforeSleep` AOF flush coordinate fsync with the event cycle.
- [../persistence/aof.md](../persistence/aof.md) - `flushAppendOnlyFile()` runs in `beforeSleep` to write `server.aof_buf` to disk each event loop iteration
- [../cluster/overview.md](../cluster/overview.md) - `clusterBeforeSleep()` is called from the `beforeSleep` hook to handle deferred cluster actions (failover, state updates, config saves)
