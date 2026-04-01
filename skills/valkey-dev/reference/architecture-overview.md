# Server Architecture Overview

Use when you need a map of the Valkey codebase, the global server state, or the boot sequence.

## Contents

- Repository Layout (line 14)
- Global Server State (line 62)
- main() Boot Sequence (line 148)
- See Also (line 199)

---

## Repository Layout

```
valkey/
  src/                    Core C implementation
    server.c / server.h   Global state, main(), initialization, command dispatch
    networking.c           Client I/O, RESP parsing, response writing
    ae.c / ae.h            Event loop (async events library)
    ae_epoll.c             epoll backend (Linux)
    ae_kqueue.c            kqueue backend (macOS/BSD)
    ae_evport.c            evport backend (Solaris)
    ae_select.c            select fallback
    db.c                   Database operations
    rdb.c / aof.c          Persistence (snapshot / append-only)
    replication.c          Primary-replica synchronization
    cluster.c              Cluster mode (gossip, slots, failover)
    sentinel.c             Sentinel mode
    module.c               Module/plugin API
    t_string.c             String commands
    t_list.c               List commands
    t_set.c                Set commands
    t_zset.c               Sorted set commands
    t_hash.c               Hash commands
    t_stream.c             Stream commands
    sds.c / sds.h          Simple Dynamic Strings
    hashtable.c            Open-addressing hash table
    dict.c / dict.h        Legacy chained hash table
    quicklist.c            Doubly-linked list of listpacks
    listpack.c             Compact sequential encoding
    config.c               Configuration parsing and runtime CONFIG
    acl.c                  Access control lists
    bio.c                  Background I/O threads
    io_threads.c           Threaded read/write I/O
    object.c               robj (Valkey object) management
    entry.c                Hash field-value entry encoding
  deps/                   Vendored dependencies
    jemalloc/             Memory allocator
    lua/                  Lua 5.1 interpreter
    hdr_histogram/        Latency histogram
    linenoise/            Line editing for CLI
    libvalkey/            Client library (used by sentinel)
    fast_float/           Fast float parsing
    fpconv/               Fast float-to-string conversion
    gtest-parallel/       Parallel test runner
  tests/                  Tcl integration test suite
  utils/                  Utility scripts
```

## Global Server State

All runtime state lives in a single global `struct valkeyServer` (declared at `server.h:1771`). The struct has 800+ fields. Key groups:

### Core Runtime

| Field | Type | Purpose |
|-------|------|---------|
| `pid` | `pid_t` | Main process PID |
| `main_thread_id` | `pthread_t` | Main thread identifier |
| `el` | `aeEventLoop *` | The event loop |
| `hz` | `int` | `serverCron()` frequency in hertz (default 10) |
| `configfile` | `char *` | Absolute path to config file |
| `sentinel_mode` | `int` | True if running as Sentinel |
| `runid` | `char[41]` | Unique ID regenerated each startup |
| `shutdown_asap` | `volatile sig_atomic_t` | Signal-driven shutdown flag |

### Database

| Field | Type | Purpose |
|-------|------|---------|
| `db` | `serverDb **` | Array of database pointers (created on first use) |
| `dbnum` | `int` | Total number of initialized DBs |
| `commands` | `hashtable *` | Command table - name to `serverCommand` |
| `orig_commands` | `hashtable *` | Command table before renaming |

### Networking

| Field | Type | Purpose |
|-------|------|---------|
| `port` | `int` | TCP listening port |
| `tls_port` | `int` | TLS listening port |
| `bindaddr[]` | `char *[16]` | Bound addresses |
| `listeners[]` | `connListener[CONN_TYPE_MAX]` | TCP/Unix/TLS/RDMA listeners |
| `clients` | `list *` | All active client connections |
| `clients_to_close` | `list *` | Clients to free asynchronously |
| `clients_pending_write` | `list *` | Clients with pending output |
| `clients_pending_io_read` | `list *` | Clients queued for I/O thread reads |
| `clients_pending_io_write` | `list *` | Clients queued for I/O thread writes |
| `replicas` | `list *` | Connected replicas |
| `current_client` | `client *` | Client that triggered current command |
| `executing_client` | `client *` | Client executing current command (may differ in scripts) |
| `io_threads_num` | `int` | Configured I/O thread count |
| `maxclients` | `unsigned int` | Maximum simultaneous clients |

### Persistence

| Field | Type | Purpose |
|-------|------|---------|
| `aof_state` | `int` | `AOF_ON`, `AOF_OFF`, or `AOF_WAIT_REWRITE` |
| `aof_buf` | `sds` | Pending AOF buffer, flushed each event loop |
| `dirty` | `long long` | Changes since last save |
| `child_pid` | `pid_t` | PID of fork child (RDB/AOF rewrite) |
| `maxmemory` | `unsigned long long` | Memory limit for eviction |

### Replication

| Field | Type | Purpose |
|-------|------|---------|
| `primary_host` | `char *` | Primary's hostname (NULL if this is primary) |
| `repl_backlog` | - | Circular replication buffer |
| `primary_repl_offset` | `long long` | Global replication offset |

### The `serverDb` Struct

Each logical database (`server.h:934`) contains:

```c
typedef struct serverDb {
    kvstore *keys;                        /* The keyspace for this DB */
    kvstore *expires;                     /* Timeout of keys with a timeout set */
    kvstore *keys_with_volatile_items;    /* Keys with volatile items */
    dict *blocking_keys;                  /* Keys with clients waiting for data (BLPOP) */
    dict *blocking_keys_unblock_on_nokey; /* Keys to unblock on delete (XREADGROUP) */
    dict *ready_keys;                     /* Blocked keys that received a PUSH */
    dict *watched_keys;                   /* WATCHED keys for MULTI/EXEC CAS */
    int id;                               /* Database ID */
    struct {
        long long avg_ttl;
        unsigned long cursor;
    } expiry[ACTIVE_EXPIRY_TYPE_COUNT];   /* Per-expiry-type stats (avg TTL, cursor) */
} serverDb;
```

The keyspace uses `kvstore` (see [../valkey-specific/kvstore.md](../valkey-specific/kvstore.md)) - a slot-aware hash table that wraps the new `hashtable` implementation (see [../data-structures/hashtable.md](../data-structures/hashtable.md)).

## main() Boot Sequence

The entry point is in `server.c:7365`. The full initialization flow:

```
main()
  |
  +-- Library init (timezone, RNG seed, CRC64, hash seeds)
  +-- initServerConfig()         # Set all defaults in struct valkeyServer
  +-- ACLInit()                  # Initialize ACL subsystem
  +-- moduleInitModulesSystem()  # Prepare module infrastructure
  +-- connTypeInitialize()       # Register connection types (TCP, TLS, Unix, RDMA)
  +-- Parse argv / loadServerConfig()
  +-- System checks (Linux memory warnings, Xen clocksource)
  +-- Daemonize if configured
  +-- initServer()               # The big initialization function
  |     +-- Signal handlers, thread manager
  |     +-- Create client lists, replica lists, timeout tables
  |     +-- aeCreateEventLoop()  # Allocate event loop for maxclients + headroom
  |     +-- Allocate DB array, create default DB 0
  |     +-- evictionPoolAlloc()  # LRU/LFU eviction sampling pool
  |     +-- Pub/Sub channel stores
  |     +-- aeCreateTimeEvent(serverCron)    # Register periodic timer
  |     +-- aeCreateTimeEvent(clientsTimeProc)
  |     +-- aeSetBeforeSleepProc(beforeSleep)
  |     +-- aeSetAfterSleepProc(afterSleep)
  |     +-- scriptingEngineManagerInit()
  |
  +-- createPidFile()
  +-- clusterInit()              # If cluster mode
  +-- moduleLoadFromQueue()      # Load configured modules
  +-- ACLLoadUsersAtStartup()
  +-- initListeners()            # Bind TCP/TLS/Unix/RDMA sockets, register accept handlers
  +-- clusterInitLast()          # Cluster bus listener
  +-- InitServerLast()           # I/O threads, bio threads
  +-- loadDataFromDisk()         # RDB or AOF loading
  +-- aofOpenIfNeededOnServerStart()
  +-- aeMain(server.el)          # Enter the event loop - runs forever
  +-- aeDeleteEventLoop()        # Cleanup after shutdown
```

### Key Initialization Details

**Event loop sizing**: The event loop is created with `maxclients + CONFIG_FDSET_INCR` slots to handle client FDs plus internal FDs (listeners, pipes, cluster bus).

**Listener setup** (`initListeners` at `server.c:3104`): Iterates over configured connection types (TCP, TLS, Unix socket, RDMA), binds each to its configured address/port, and registers the accept handler. Each connection type implements its own accept callback through the `ConnectionType` abstraction.

**Timer registration**: Two time events are registered:
- `serverCron` - fires at `server.hz` frequency (default 10 Hz = every 100ms). Handles expiry, stats, replication heartbeats, rehashing, defragmentation, background task management.
- `clientsTimeProc` - variable frequency based on client count. Handles client timeouts, buffer resizing, memory accounting.
