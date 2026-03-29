# Valkey Development and Contribution Guide

A deep technical guide for contributors to the Valkey server codebase - covering architecture, internals, build system, testing, governance, and the full contribution workflow.

---

## 1. Codebase Architecture

### Repository Layout

```
valkey/
  src/                    Core C implementation
    server.c / server.h   Global server state, main(), initialization
    networking.c           Client I/O, RESP parsing, response writing
    ae.c / ae.h            Event loop (async events library)
    ae_epoll.c             epoll backend (Linux)
    ae_kqueue.c            kqueue backend (macOS/BSD)
    ae_evport.c            evport backend (Solaris)
    ae_select.c            select fallback
    db.c                   Database operations (GET, SET, DEL dispatch)
    rdb.c / rdb.h          RDB snapshot persistence
    aof.c                  AOF append-only file persistence
    replication.c          Primary-replica synchronization
    cluster.c / cluster.h  Cluster mode (gossip, slots, failover)
    sentinel.c             Sentinel mode
    module.c               Module/plugin API
    t_string.c             String type commands
    t_list.c               List type commands
    t_set.c                Set type commands
    t_zset.c               Sorted set commands
    t_hash.c               Hash type commands
    t_stream.c             Stream type commands
    sds.c / sds.h          Simple Dynamic Strings
    hashtable.c            New open-addressing hash table (8.1+)
    dict.c / dict.h        Legacy chained hash table
    quicklist.c            Doubly-linked list of listpacks
    listpack.c             Compact sequential encoding
    intset.c               Compact sorted integer sets
    skiplist.c             Probabilistic sorted structure
    rax.c / rax.h          Radix tree (used by streams)
    ziplist.c              Legacy compact encoding (deprecated)
    zmalloc.c / zmalloc.h  Memory allocator wrapper
    lazyfree.c             Background object deletion
    bio.c                  Background I/O threads
    memory_prefetch.c      Batch key prefetching optimization
    config.c               Configuration parsing and runtime CONFIG
    acl.c                  Access control lists
    scripting.c            Lua scripting engine
    eval.c                 EVAL command implementation
    object.c               robj (Valkey object) management
    notify.c               Keyspace notifications
    pubsub.c               Pub/Sub messaging
    geo.c                  Geospatial commands
    hyperloglog.c          HyperLogLog probabilistic counting
    bitops.c               Bit operations
    multi.c                MULTI/EXEC transactions
    blocked.c              Blocking command support
    debug.c                DEBUG command and crash reporting
    unit/                  C-level unit tests
  deps/                   Vendored dependencies
    jemalloc/             Memory allocator
    lua/                  Lua 5.1 interpreter
    hdr_histogram/        Latency histogram
    linenoise/            Line editing for CLI
    libvalkey/            Valkey client library (used by sentinel)
  tests/                  Tcl integration test suite
    unit/                 Tcl unit tests (per-command, per-feature)
    integration/          Integration tests
    sentinel/             Sentinel-specific tests
    cluster/              Cluster-specific tests (runtest-cluster)
    modules/              Module API tests (runtest-moduleapi)
    support/              Test helper utilities
    assets/               Test fixtures (ACL files, certs, etc.)
  utils/                  Utility scripts
    gen-test-certs.sh     Generate TLS test certificates
    install_server.sh     Production setup (Debian/Ubuntu)
  .github/workflows/     CI pipeline definitions
```

### Global Server State

The entire runtime state lives in a single global `struct valkeyServer` declared in `src/server.h`, containing approximately 800+ fields:

- `server.el` - Event loop (`aeEventLoop *`)
- `server.db` - Array of `serverDb` structures (one per logical database)
- `server.clients` - Linked list of connected clients
- `server.replicas` - Linked list of connected replicas
- `server.cluster` - Cluster state (`clusterState *`)
- `server.aof_state` - AOF persistence state
- `server.saveparams` - RDB save triggers
- `server.repl_backlog` - Circular replication buffer
- `server.io_threads` - I/O thread pool state
- `server.maxmemory` - Memory limit for eviction

Each `serverDb` has its own keyspace implemented using `kvstore`, and all stored values are wrapped in the `robj` structure providing type, encoding, refcount, and LRU/LFU metadata.

### The Main Event Loop

Valkey uses the reactor pattern via its own `ae` library (not libuv or libevent). The core loop in `ae.c`:

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

Each iteration:

1. `beforeSleep()` - Flushes pending writes, handles AOF fsync, processes blocked clients, handles cluster tasks
2. `aeApiPoll()` - Blocks on the platform I/O multiplexer (epoll on Linux, kqueue on macOS/BSD, select as fallback)
3. **File events** - Socket read/write callbacks fire for ready descriptors
4. **Time events** - `serverCron()` fires every 100ms for periodic maintenance (expiry, stats, replication heartbeats, rehashing, defragmentation)

Platform backends are selected at compile time via `ae_epoll.c`, `ae_kqueue.c`, `ae_evport.c`, or `ae_select.c`. The `ae` library provides `aeCreateFileEvent()` and `aeCreateTimeEvent()` for registration.

### Command Dispatch

When a client sends a command:

1. `readQueryFromClient()` reads data into the client's `querybuf`
2. `processInputBuffer()` parses RESP protocol, extracting `argc`/`argv`
3. `processCommand()` looks up the command in the global command table
4. The command's `proc` function pointer is called with the client context
5. Reply is buffered in the client's `reply` list
6. `sendReplyToClient()` writes the response back

The command table maps command names to `serverCommand` structures containing the implementation function, arity, flags (write/read/admin/fast), key positions, and ACL categories.

### Networking Layer (`networking.c`)

- `acceptTcpHandler()` - Accepts new connections, creates `client` structs
- `processInputBuffer()` - Parses RESP2/RESP3 wire format
- `sendReplyToClient()` - Writes buffered replies to sockets
- `freeClient()` - Cleanup on disconnect

Each client maintains: `querybuf` (input buffer), `reply` (output buffer list), `flags` (state flags), `db` (selected database pointer), `authenticated` (ACL state).

---

## 2. Core Data Structures

### SDS - Simple Dynamic Strings (`sds.c/sds.h`)

SDS is the fundamental string type used throughout Valkey. It is a binary-safe string with O(1) length retrieval and automatic memory management.

**Header variants** (selected by string length):
- `SDS_TYPE_5` - Strings up to 31 bytes (flags byte only)
- `SDS_TYPE_8` - Up to 255 bytes (1-byte len + 1-byte alloc)
- `SDS_TYPE_16` - Up to 65535 bytes
- `SDS_TYPE_32` - Up to 4GB
- `SDS_TYPE_64` - Larger strings

The memory layout is: `[header][string data][null terminator]`. The pointer returned to callers points at the string data, so it is compatible with C string functions. The header is accessed by subtracting from the pointer.

Key operations: `sdsnew()`, `sdscat()`, `sdscpy()`, `sdsrange()`, `sdsfree()`. SDS tracks both allocated space and used length, implementing preallocation to amortize repeated appends.

### Hashtable (new, 8.1+) (`hashtable.c`)

Valkey 8.1 replaced the legacy `dict` with a new open-addressing hash table. Design:

- **64-byte buckets** aligned to CPU cache lines, each holding up to 7 elements
- **Metadata per bucket**: 1 bit child-bucket indicator, 7 bits slot occupancy, 7 bytes of secondary hash values (one byte per slot)
- **Secondary hash**: Uses 8 unused bits from the 64-bit hash for fast mismatch elimination (99.6% of false positives eliminated without key comparison)
- **Child bucket chaining**: When a bucket fills, the last slot converts to a pointer to a child bucket with identical layout
- **Lookup cost**: 2 memory accesses (bucket + `serverObject`) vs 4 in old dict
- **Memory savings**: ~20 bytes per key-value pair without TTL, ~30 bytes with TTL
- Supports incremental rehashing, SCAN iteration, and random element sampling

This table is used as the main key-value store and as the backing structure for Hash, Set, and Sorted Set types (replacing `dict` in all those roles).

### Dict (legacy, pre-8.1) (`dict.c/dict.h`)

The legacy chained hash table with two tables for incremental rehashing. Each `dictEntry` contains a key pointer, value union, next pointer, and metadata. During rehash, new inserts go to table[1] while lookups check both tables. One bucket is migrated per operation to avoid blocking.

### Skiplist (`skiplist.c`)

Used internally by sorted sets for O(log N) range operations. Each node has a probabilistic number of levels (max 32), with each level containing a forward pointer and a span value. Valkey extends the standard skiplist with a backward pointer for reverse traversal and span tracking for rank computation.

Level assignment uses a power-law distribution (probability 0.25 per additional level), so most nodes are level 1 and very few reach high levels.

### Listpack (`listpack.c`)

A compact, contiguous memory structure storing elements sequentially. Each element is encoded with a length prefix enabling bidirectional traversal. Used as the small-encoding for Lists, Hashes, Sets, and Sorted Sets. Advantages: cache-friendly, zero pointer overhead, minimal per-element overhead.

### Quicklist (`quicklist.c`)

A doubly-linked list where each node contains a listpack. Combines memory efficiency of listpack with O(1) push/pop at both ends. Nodes can be optionally LZF-compressed (controlled by `list-compress-depth`). The `quicklist-packed-threshold` controls when large elements get their own uncompressed node.

### Intset (`intset.c`)

A compact sorted array of integers used for small Sets containing only integer values. Supports 16-bit, 32-bit, and 64-bit integer encodings, upgrading automatically when a larger integer is added.

### Rax - Radix Tree (`rax.c/rax.h`)

A compressed radix tree used primarily by Streams. Stream IDs are stored as keys in the rax, with listpack-encoded entries as values. Also used for cluster slot-to-node mappings and other internal indexes. Memory-sparse with O(k) lookup where k is key length.

### Encoding Transitions

Valkey automatically selects compact encodings for small collections and transitions to full-featured structures when thresholds are exceeded:

| Type | Small Encoding | Large Encoding | Transition Triggers |
|------|---------------|----------------|-------------------|
| String | EMBSTR (<=44 bytes) or INT | RAW | Length > 44 bytes or non-numeric |
| List | LISTPACK | QUICKLIST | Element count or element size exceeds config |
| Set | INTSET or LISTPACK | HASHTABLE | Non-integer added or count exceeds `set-max-intset-entries` |
| Sorted Set | LISTPACK | SKIPLIST + HASHTABLE | Count exceeds `zset-max-listpack-entries` or element size exceeds `zset-max-listpack-value` |
| Hash | LISTPACK | HASHTABLE | Count exceeds `hash-max-listpack-entries` or value size exceeds `hash-max-listpack-value` |
| Stream | Rax + Listpack | (same, grows naturally) | N/A |

---

## 3. Persistence

### RDB Snapshots (`rdb.c`)

RDB produces point-in-time binary snapshots of the entire dataset.

**Mechanism**:
1. `BGSAVE` triggers `rdbSaveBackground()`
2. Server `fork()`s a child process
3. Child serializes the dataset to `dump.rdb` using copy-on-write semantics
4. Parent continues serving clients; only modified pages incur copy overhead
5. Child signals completion; parent replaces the old RDB file

**Automatic triggers**: Configured via `save <seconds> <changes>` directives (e.g., `save 900 1` means save after 900 seconds if at least 1 key changed).

**RDB format**: Binary, architecture-agnostic, version-stamped (version 12 for Valkey 9.x). Contains: magic bytes, version, auxiliary fields (Valkey version, ctime, used-mem), database selectors, key-value pairs with type-specific encoding, EOF marker, CRC64 checksum.

**Advantages**: Compact, fast restarts, supports partial resync after restart.
**Disadvantages**: Data loss between snapshots, fork can be expensive on large datasets.

### AOF - Append Only File (`aof.c`)

AOF logs every write command in RESP format for crash recovery.

**Multi-part AOF architecture** (Valkey 7.0+):
- **BASE file**: An RDB or AOF snapshot at a point in time
- **INCR files**: Incremental command logs since the BASE
- **Manifest file**: Tracks all AOF files and their relationships

**Fsync policies**:
- `appendfsync always` - Fsync after every write (safest, slowest)
- `appendfsync everysec` - Background fsync every second (recommended default)
- `appendfsync no` - Let the OS decide (fastest, least safe)

**AOF rewriting** (`BGREWRITEAOF`):
1. Fork a child process
2. Child generates a new compact BASE file (can be RDB format with `aof-use-rdb-preamble yes`)
3. Parent buffers new writes in the rewrite buffer
4. After child completes, parent appends the rewrite buffer as a new INCR file
5. Manifest is atomically updated

**Loading on startup**: Valkey reads the manifest, loads the BASE file first, then replays INCR files in order.

### Hybrid RDB+AOF

With `aof-use-rdb-preamble yes`, the AOF BASE is written in RDB format (fast loading) while incremental changes are still RESP-formatted. This combines the fast startup of RDB with the durability of AOF.

---

## 4. Replication

### PSYNC Protocol

Replicas connect to primaries using the `PSYNC` command, providing their replication ID and offset:

1. **Partial resync**: If the primary has sufficient backlog and recognizes the replication ID, it sends only the missed commands
2. **Full resync**: Otherwise, the primary creates an RDB snapshot, transfers it, then streams subsequent commands

**Replication IDs**: Each primary has a pseudo-random replication ID. After failover, the promoted replica keeps the old primary's ID as a secondary ID, enabling other replicas to partial-resync against it.

**Replication backlog**: A circular buffer (`server.repl_backlog`) storing recent write commands. Size controlled by `repl-backlog-size`. Replicas that disconnect for longer than the backlog covers require full resync.

### Dual-Channel Replication (Valkey 8.0+)

A major improvement over the traditional single-connection sync:

1. Replica sends `rdb-channel-repl` capability during handshake
2. If full sync needed, primary replies with `+RDBCHANNELSYNC`
3. Replica opens a second connection dedicated to RDB transfer
4. The main connection immediately attaches to the replication stream
5. RDB and live command stream flow simultaneously on separate channels

Benefits: Reduced memory pressure on primary, faster sync completion, the primary process is freed from RDB transfer duty.

### Diskless Replication

With `repl-diskless-sync yes`, the primary streams the RDB directly to replica sockets without writing to disk first. Useful when disk I/O is the bottleneck but network is fast.

### Key Expiration in Replication

Replicas do not independently expire keys. The primary synthesizes `DEL` commands for expired keys and propagates them. This avoids clock synchronization issues.

---

## 5. Cluster Mode

### Hash Slot Distribution

Valkey Cluster partitions the keyspace into 16,384 hash slots:

```
HASH_SLOT = CRC16(key) % 16384
```

Each node owns a subset of slots. Hash tags `{...}` allow grouping related keys to the same slot for multi-key operations.

### Cluster Bus (Gossip Protocol)

Every node connects to every other node via a binary protocol on port `data_port + 10000`. This full-mesh topology uses gossip to propagate state:

- **PING/PONG**: Heartbeat messages carrying partial cluster state (a random subset of known nodes)
- **MEET**: Introduces a new node to the cluster
- **FAIL**: Broadcasts hard failure detection
- **PUBLISH**: Cluster-wide pub/sub messages

Only one thread executes `epoll_wait` at any time to prevent race conditions.

### Failure Detection

Two-phase detection:
1. **PFAIL** (Possible Failure): Set when a node is unreachable for `NODE_TIMEOUT` milliseconds
2. **FAIL**: Escalated when the majority of primary nodes report PFAIL within `NODE_TIMEOUT * 2`

### Failover and Configuration Epochs

When a primary fails, its replicas compete for promotion:
1. Replicas wait based on their replication offset rank (most current waits least)
2. A replica requests votes from other primaries
3. Majority approval triggers promotion
4. The new primary increments its `configEpoch` above all others
5. "Last failover wins" conflict resolution via epoch comparison

### MOVED and ASK Redirections

- **MOVED slot node**: Permanent slot reassignment; client should update its slot mapping
- **ASK slot node**: Temporary redirect during migration; client sends the next query to the target after issuing `ASKING`

### Atomic Slot Migration (Valkey 9.0+)

Replaces legacy key-by-key migration. Entire slots are migrated atomically using AOF format transfer, eliminating redirect storms and large-key latency spikes during resharding.

### Multi-Database Clustering (Valkey 9.0+)

Valkey 9.0 adds full support for numbered databases (`SELECT 0-15`) in cluster mode, enabling data separation within clustered deployments.

---

## 6. Memory Management

### zmalloc Wrapper (`zmalloc.c`)

All Valkey allocations go through `zmalloc()`, which wraps the configured allocator (jemalloc by default on Linux, libc malloc otherwise). zmalloc tracks total allocated memory for reporting and eviction decisions.

Thread-local counters (introduced in Valkey 8.0) eliminate atomic operation overhead - each thread updates a local counter, with the global total computed on demand by summing thread-local values.

### jemalloc Integration

jemalloc provides arena-based allocation that reduces fragmentation. Valkey configures jemalloc with custom settings optimized for its allocation patterns. The `MEMORY DOCTOR` command reports jemalloc statistics and fragmentation analysis.

### Active Defragmentation

When memory becomes fragmented, Valkey's active defrag subsystem relocates allocations:

1. Runs during the `serverCron` 100ms timer
2. Computes a duty cycle based on fragmentation level (e.g., 10% CPU = 10ms of work per 100ms cycle)
3. jemalloc identifies allocations on underutilized pages
4. Valkey copies data to new allocations, freeing the fragmented pages
5. Valkey 8.1 reduced cycle time to 500us with increased frequency, eliminating >1ms tail latencies

Configuration: `activedefrag yes`, `active-defrag-threshold-lower`, `active-defrag-cycle-min`, `active-defrag-cycle-max`.

### Lazy Freeing (`lazyfree.c`)

Large objects (big lists, sets, hashes) are freed asynchronously by BIO threads to prevent blocking the main thread. Commands like `UNLINK` (async `DEL`) and `FLUSHDB ASYNC` use this mechanism.

### Eviction Policies

When `maxmemory` is reached:
- `volatile-lru` / `allkeys-lru` - Evict least recently used
- `volatile-lfu` / `allkeys-lfu` - Evict least frequently used
- `volatile-ttl` - Evict keys with shortest TTL
- `volatile-random` / `allkeys-random` - Random eviction
- `noeviction` - Return errors on writes

LRU/LFU tracking uses the 24-bit field in each `robj` structure, sampling random keys rather than maintaining a full LRU list.

---

## 7. Threading Model

### Main Thread

Handles all command execution, event loop processing, and database operations. Single-threaded execution guarantees atomicity without locks.

### I/O Threads (Valkey 8.0+)

Optional worker threads for socket I/O operations when `io-threads > 1`:

**Job types**:
- Reading and parsing commands from client sockets
- Writing responses back to clients
- Polling for I/O events on TCP connections
- Memory deallocation

**Design principles**:
- Main thread orchestrates all jobs, ensuring no race conditions
- At most one thread executes `epoll_wait` at any time
- Thread affinity maintained - same I/O thread handles the same client when possible for cache locality
- Dynamic thread count adjustment based on load

**Performance**: 230% throughput increase in Valkey 8.0 (360K to 1.19M RPS), with average latency dropping 69.8% (1.792ms to 0.542ms). Tested with 8 I/O threads, 650 clients on AWS C7g.16xlarge.

### Background I/O Threads (`bio.c`)

Three dedicated background threads:
- `BIO_CLOSE_FILE` - File descriptor cleanup
- `BIO_AOF_FSYNC` - Asynchronous fsync operations
- `BIO_LAZY_FREE` - Memory deallocation of large objects

### Child Processes

Fork-based operations for persistence:
- `BGSAVE` forks for RDB snapshot creation
- `BGREWRITEAOF` forks for AOF compaction
- Both leverage copy-on-write for minimal parent impact

### Memory Access Amortization (`memory_prefetch.c`)

A key optimization in Valkey 8.0+ that interleaves memory access across batched commands:

1. Commands from I/O threads are grouped into batches
2. `dictPrefetch` preloads memory addresses for all key lookups in the batch
3. While one key's memory is being fetched, the CPU works on prefetching the next
4. Reduces the `lookupKey` bottleneck (which consumed >40% of main thread time) by >80%

Result: ~50% throughput improvement from 780K to 1.19M SET commands/second.

### Pipeline Prefetching (Valkey 9.0+)

Instead of parsing one command at a time, Valkey 9.0 parses multiple pipelined commands from the query buffer and batch-prefetches all accessed keys before execution. Yields up to 40% additional throughput for pipelined workloads.

---

## 8. RESP Protocol

### Overview

RESP (REdis Serialization Protocol) is the wire protocol for client-server communication. It prioritizes simplicity, fast parsing, and human readability. All parts are terminated by `\r\n` (CRLF).

### RESP2 Data Types

| Type | Prefix | Example |
|------|--------|---------|
| Simple String | `+` | `+OK\r\n` |
| Error | `-` | `-ERR unknown command\r\n` |
| Integer | `:` | `:1000\r\n` |
| Bulk String | `$` | `$5\r\nhello\r\n` |
| Array | `*` | `*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n` |
| Null Bulk String | `$` | `$-1\r\n` |
| Null Array | `*` | `*-1\r\n` |

### RESP3 Additions

| Type | Prefix | Description |
|------|--------|-------------|
| Null | `_` | Explicit null value |
| Boolean | `#` | `#t\r\n` or `#f\r\n` |
| Double | `,` | Floating-point numbers |
| Big Number | `(` | Beyond 64-bit range |
| Bulk Error | `!` | Length-prefixed errors |
| Verbatim String | `=` | Data with encoding hint |
| Map | `%` | Key-value pairs |
| Set | `~` | Unordered unique elements |
| Push | `>` | Server-initiated out-of-band data |

### Request Format

Clients send commands as RESP arrays of bulk strings. The `HELLO` command negotiates protocol version (RESP2 or RESP3) at connection start.

### Inline Commands

For telnet compatibility, Valkey accepts space-separated commands without RESP framing. Since valid RESP always starts with `*`, the server auto-detects inline format.

---

## 9. Build System

### Makefile Build (Primary)

```bash
# Basic build
make

# Build with all features
make BUILD_TLS=yes USE_SYSTEMD=yes USE_LIBBACKTRACE=yes

# Debug build (no optimizations)
make noopt

# 32-bit build
make 32bit

# Choose memory allocator
make MALLOC=jemalloc    # Default on Linux
make MALLOC=libc        # Use system malloc

# Verbose output
make V=1

# Clean everything including dependencies
make distclean
```

**Build targets**:
- `valkey-server` - Main server
- `valkey-cli` - Command-line client
- `valkey-benchmark` - Benchmarking tool
- `valkey-sentinel` - Sentinel executable (symlink to valkey-server)
- `valkey-check-rdb` - RDB file validator
- `valkey-check-aof` - AOF file validator

**Optional features**:

| Flag | Purpose |
|------|---------|
| `BUILD_TLS=yes` | TLS support (requires OpenSSL) |
| `BUILD_TLS=module` | TLS as loadable module |
| `BUILD_RDMA=yes` | RDMA support (experimental, Linux) |
| `BUILD_RDMA=module` | RDMA as loadable module |
| `USE_SYSTEMD=yes` | systemd notify integration |
| `USE_LIBBACKTRACE=yes` | Enhanced stack traces in crash reports |
| `BUILD_LUA=no` | Remove Lua scripting engine |
| `PROG_SUFFIX="-alt"` | Add suffix to binary names |
| `USE_REDIS_SYMLINKS=no` | Skip redis-* compatibility symlinks |

**Installation**:
```bash
make install                    # Install to /usr/local/bin
make PREFIX=/opt/valkey install # Custom install path
```

### CMake Build (Experimental)

```bash
mkdir build-release && cd build-release
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/valkey
make
sudo make install

# Debug build
cmake .. -DCMAKE_BUILD_TYPE=Debug

# With sanitizers
cmake .. -DBUILD_SANITIZER=address   # AddressSanitizer
cmake .. -DBUILD_SANITIZER=thread    # ThreadSanitizer
cmake .. -DBUILD_SANITIZER=undefined # UndefinedBehaviorSanitizer

# Build unit tests
cmake .. -DBUILD_UNIT_GTESTS=yes

# Build test/example modules
cmake .. -DBUILD_TEST_MODULES=yes -DBUILD_EXAMPLE_MODULES=yes
```

CMake generates `compile_commands.json` for IDE/clangd integration:
```bash
ln -sf $(pwd)/build-release/compile_commands.json $(pwd)/compile_commands.json
```

### Dependencies

All dependencies are vendored in `deps/`:
- **jemalloc** - Memory allocator (default on Linux)
- **lua** - Lua 5.1 interpreter for scripting
- **hdr_histogram** - Latency percentile tracking
- **linenoise** - Line editing for valkey-cli
- **libvalkey** - C client library (used by sentinel)

When updating source or pulling new code, run `make distclean` to rebuild dependencies.

### Monotonic Clock

By default, Valkey uses processor instruction clocks (TSC on x86, CNTVCT on ARM) for ~3x faster time access. Disable with:
```bash
make CFLAGS="-DNO_PROCESSOR_CLOCK"
```

---

## 10. Testing Infrastructure

### Test Suites

Valkey has four main test suites, each with its own runner:

| Suite | Command | Runner Script | Focus |
|-------|---------|---------------|-------|
| Integration | `make test` | `./runtest` | Per-command behavior, data types, features |
| Cluster | `make test-cluster` | `./runtest-cluster` | Cluster topology, slot migration, failover |
| Sentinel | `make test-sentinel` | `./runtest-sentinel` | HA, failover, monitoring |
| Module API | `make test-modules` | `./runtest-moduleapi` | Module loading, custom types, commands |
| Unit (C) | `make test-unit` | `./valkey-unit-tests` | C-level data structure tests |

### Tcl Integration Tests

The primary test framework uses Tcl. Tests live in `tests/unit/` and are organized by feature area.

**Running a single test**:
```bash
./runtest --single unit/bitops
```

**Key options**:

| Option | Purpose |
|--------|---------|
| `--single <test>` | Run a single test file |
| `--singledb` | Restrict to database 0 |
| `--ignore-encoding` | Skip encoding-specific checks |
| `--large-memory` | Enable tests requiring >100MB |
| `--tls` / `--tls-module` | Run with TLS enabled |
| `--cluster-mode` | Enable cluster compatibility mode |
| `--host <ip> --port <n>` | Test against external server |
| `--tags -needs:repl` | Exclude tests by tag |

**Test structure** (Tcl test file pattern):
```tcl
start_server {tags {"bitops"}} {
    test "BITCOUNT returns 0 with empty string" {
        r SET mykey ""
        assert_equal 0 [r BITCOUNT mykey]
    }

    test "BITCOUNT with non-existent key" {
        assert_equal 0 [r BITCOUNT nonexistent]
    }
}
```

The `start_server` block spawns a fresh Valkey instance for the test context. The `r` command sends commands to the test server. Test helpers include `assert_equal`, `assert_error`, `assert_match`, `wait_for_condition`, and more.

**Test tagging system**:

| Tag | Meaning |
|-----|---------|
| `external:skip` | Incompatible with external servers |
| `cluster:skip` | Incompatible with cluster mode |
| `needs:repl` | Requires replication/SYNC |
| `needs:debug` | Requires DEBUG command |
| `needs:config-*` | Requires CONFIG SET |
| `valgrind:skip` | Incompatible with Valgrind |
| `large-memory` | Requires >100MB RAM |

**Debugging tests** - Insert breakpoints with the `bp` function:
```tcl
... test code ...
bp 1
... more test code ...
```

At the breakpoint, the Tcl interpreter becomes interactive. Commands: `c` (continue), `i` (print local variables). Skip specific breakpoints with `::bp_skip`.

### C Unit Tests (`src/unit/`)

Modern C-level unit tests built with `make valkey-unit-tests`:

```bash
# Run all unit tests
./valkey-unit-tests

# Run a specific test
./valkey-unit-tests --single test_crc64combine.c
```

Unit tests target internal data structures and algorithms (CRC64, SDS, hashtable operations, listpack encoding, etc.). The `src/unit/` directory contains test files following the `test_*.c` naming convention.

### TLS Test Setup

```bash
make BUILD_TLS=yes
./utils/gen-test-certs.sh
# Install tcl-tls package for your OS
./runtest --tls
```

### Running CI Tests on Your Fork

The `.github/workflows/daily.yml` supports manual triggering via `workflow_dispatch`:
1. Go to Actions - Daily in your fork
2. Specify your fork (`your-user/valkey`) and branch
3. Optionally set `skipjobs`, `skiptests`, `test_args`, `cluster_test_args`

Scheduled runs only work on the main repository, but manual dispatch works on forks.

### CI Pipeline

The Valkey CI runs on GitHub Actions with workflows including:
- **PR checks** - Triggered on pull requests (build + test on multiple platforms)
- **Daily tests** - Full test matrix including sanitizer builds, Valgrind, different allocators
- **Code coverage** - Tracked per PR, comparing base vs head

Tests run on Linux (Ubuntu) and macOS across multiple configurations (debug, release, TLS, cluster, sentinel, sanitizers).

---

## 11. Development Workflow

### Setting Up Your Dev Environment

```bash
# Clone the repository
git clone https://github.com/valkey-io/valkey.git
cd valkey

# Build
make -j$(nproc)

# Run the server
./src/valkey-server

# In another terminal, test with CLI
./src/valkey-cli
valkey> PING
PONG

# Run tests to verify your build
make test
```

For IDE support with CMake:
```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Debug
make
ln -sf $(pwd)/compile_commands.json ../compile_commands.json
```

### Coding Style

Style is enforced by **clang-format**. Key conventions:

**Naming**:
- Variables: `snake_case` or all lowercase (e.g., `valkey_object` or `valkeyobject`)
- Functions: `camelCase` or `namespace_camelCase` (e.g., `createObjectList` or `networking_createObjectList`)
- Macros: `UPPER_CASE` (e.g., `DICT_CREATE`)
- Structures: `camelCase` (e.g., `user`)

**Comments**:
- C-style `/* comment */` for both single and multi-line
- C++ `//` for single-line only

**General**:
- Maximum 120 characters per line
- Follow the style of surrounding code when encountering legacy patterns
- Use `static` functions internally when possible
- Avoid adding configuration when heuristics can determine behavior
- ANSI C11 with atomics, plus GCC/Clang built-ins like `__builtin_clz()`

### Commit Conventions

Every commit must include a DCO (Developer Certificate of Origin) sign-off:

```bash
git commit -s -m "Fix memory leak in quicklist compression"
```

This adds `Signed-off-by: Your Name <your@email.com>` to the commit message. Only real or preferred names are accepted - anonymous contributions and pseudonyms are not permitted.

### Contribution Workflow

1. **For major features**: Create a GitHub issue first describing what you want to accomplish, why, and the use cases. Wait for acknowledgment before coding.
2. **For minor fixes**: Open a PR directly.

```bash
# Fork the repository on GitHub, then:
git clone https://github.com/YOUR-USERNAME/valkey.git
cd valkey
git remote add upstream https://github.com/valkey-io/valkey.git
git checkout -b my-feature
# ... make changes ...
git commit -s -m "Add feature X for use case Y"
git push origin my-feature
# Open PR on GitHub, link existing issues with "Fixes #xyz"
```

### Testing Requirements

All contributions must include tests:
- **Unit tests** in `src/unit/` for internal data structure changes
- **Integration tests** in `tests/unit/` for new commands or behavioral changes
- **Module tests** in `tests/modules/` for module API changes

Test isolation is critical - avoid dependencies between tests and ensure proper cleanup.

### Security Vulnerability Reporting

Report vulnerabilities to `security@lists.valkey.io`. Do NOT create public issues. Valkey follows responsible disclosure and may notify vendors before public release. GPG encryption available for sensitive communications.

---

## 12. PR and Review Process

### PR Requirements

- DCO sign-off on every commit (enforced by CI)
- Tests covering the change
- CI must pass (builds, integration tests, unit tests across platforms)
- Link to related issues using "Fixes #xyz" in the PR description

### CI Checks

PRs trigger automated checks including:
- Build on multiple platforms (Linux, macOS)
- Full integration test suite
- Unit tests
- Code coverage comparison (base vs head)
- DCO compliance check
- Sanitizer builds (address, thread, undefined behavior)

### Review Process

The project acknowledges being "very overloaded" - PRs may wait extended periods. Contributors can promote their PRs through community engagement on Discord/Matrix/GitHub Discussions.

Maintainers review for:
- Correctness and completeness
- Test coverage
- Coding style compliance
- Backward compatibility
- Performance implications
- Documentation updates

### Major Decision Process

Changes marked as "major decisions" require formal TSC review:

**Technical major decisions** (simple majority):
- Core data structure modifications
- New data structures or APIs
- Backward compatibility changes
- Permanent user-visible fields
- External library additions affecting runtime behavior

If no majority within two weeks and no negative votes, explicit `+2` from two TSC members suffices (author's `+1` counts).

**Governance major decisions** (2/3 supermajority):
- TSC membership changes
- Governance document modifications
- Leadership delegation

---

## 13. Governance

### Linux Foundation Project

Valkey was forked from Redis 7.2.4 in March 2024, maintains the BSD 3-clause license, and is governed under the Linux Foundation's multi-vendor governance model.

### Technical Steering Committee (TSC)

The TSC comprises maintainers of the Valkey repository. No more than 1/3 of TSC members may be from the same organization.

**Current Maintainers (9)**:

| Name | GitHub | Company |
|------|--------|---------|
| Madelyn Olson (Chair) | @madolson | Amazon |
| Binbin Zhu | @enjoy-binbin | Tencent |
| Harkrishn Patro | @hpatro | Amazon |
| Lucas Yang | @lucasyonge | Independent |
| Jacob Murphy | @murphyjacob4 | Google |
| Ping Xie | @pingxie | Oracle |
| Ran Shidlansik | @ranshid | Amazon |
| Zhao Zhao | @soloestoy | Alibaba |
| Viktor Soderqvist | @zuiderkwast | Ericsson |

**Committers (2)**:

| Name | GitHub | Company |
|------|--------|---------|
| Jim Brunner | @JimB123 | Amazon |
| Ricardo Dias | @rjd15372 | Percona |

### Decision-Making

1. **Consensus**: Primary approach - good-faith consideration of dominant views
2. **Voting**: When consensus fails or for major decisions
3. **Tie-breaking**: Status quo prevails
4. **Minimum notice**: Two weeks for vote submission

### Maintainer Removal

- Governance Major Decision vote
- Written resignation
- Six-month unresponsiveness (simple majority removal vote)

### Community Channels

- **GitHub Discussions**: https://github.com/orgs/valkey-io/discussions
- **Discord**: Linked from valkey.io
- **Matrix**: Linked from valkey.io
- **Weekly meetings**: Open to the public, covering technical discussions on performance, features, and priorities

---

## 14. Release Process

### Versioning

Valkey follows semantic versioning (`major.minor.patch`) with strict API contracts across seven domains:

1. Commands (inputs, outputs, behavior)
2. Lua script functions and APIs
3. RDB version
4. Primary-to-replica replication protocol
5. Cluster node communication protocol
6. Module API interface
7. AOF disk format

### Release Cadence

- **Major releases**: One stable major release annually
- **Minor releases**: At least one per year between majors
- **Patch releases**: As needed for critical bug fixes

### Branch Strategy

- `unstable` - Development branch (not production-ready)
- `major.minor` (e.g., `8.1`, `9.0`) - Release branches
- Release candidates branch from `unstable` as `major.minor`

### Release Process

1. Release candidate (RC1) branches from `unstable`
2. Subsequent RCs released every couple of weeks for bug fixes
3. Once feedback stabilizes, GA release with patch version "0" (e.g., `8.1.0`)
4. Patches deployed as needed for high-urgency issues

### Support Timeline

- **Maintenance support**: 3 years from minor version release (bug fixes + security)
- **Extended security support**: 5 years for the latest minor of each major version

### Current Supported Versions

| Version | Release Date | Status |
|---------|-------------|--------|
| 7.2 | April 2024 | Maintenance |
| 8.0 | September 2024 | Maintenance |
| 8.1 | 2025 | Maintenance |
| 9.0 | September 2025 | Active |

---

## 15. Module/Plugin API

### Overview

Valkey modules are dynamic libraries (`.so` files) that extend server functionality at runtime. Written in C (or languages with C bindings), modules register commands, data types, and event handlers through the `valkeymodule.h` API.

### Module Lifecycle

```c
// Required entry point
int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    // Initialize module, declare API version
    if (ValkeyModule_Init(ctx, "mymodule", 1, VALKEYMODULE_APIVER_1)
        == VALKEYMODULE_ERR) return VALKEYMODULE_ERR;

    // Register commands
    if (ValkeyModule_CreateCommand(ctx, "mymodule.set", MySetCommand,
        "write deny-oom", 1, 1, 1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}

// Optional cleanup
int ValkeyModule_OnUnload(ValkeyModuleCtx *ctx) {
    // Free resources
    return VALKEYMODULE_OK; // Return ERR to prevent unloading
}
```

### Loading Modules

```bash
# Via configuration file
loadmodule /path/to/mymodule.so [arg1] [arg2]

# At runtime (requires enable-module-command yes)
MODULE LOAD /path/to/mymodule.so [arg1] [arg2]
MODULE LIST
MODULE UNLOAD mymodule
```

### Command Implementation

```c
int MySetCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);

    ValkeyModule_AutoMemory(ctx); // Automatic cleanup

    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1],
        VALKEYMODULE_READ | VALKEYMODULE_WRITE);

    ValkeyModule_StringSet(key, argv[2]);
    ValkeyModule_ReplyWithSimpleString(ctx, "OK");

    // Replicate to AOF/replicas
    ValkeyModule_ReplicateVerbatim(ctx);

    return VALKEYMODULE_OK;
}
```

### Reply Functions

- `ValkeyModule_ReplyWithLongLong()` - Integer
- `ValkeyModule_ReplyWithSimpleString()` - Status string
- `ValkeyModule_ReplyWithStringBuffer()` - Binary-safe string
- `ValkeyModule_ReplyWithArray()` - Array
- `ValkeyModule_ReplyWithError()` - Error
- `ValkeyModule_ReplyWithDouble()` - Float
- `ValkeyModule_ReplyWithNull()` - Null

### Data Access

**High-level** (using existing commands):
```c
ValkeyModuleCallReply *reply = ValkeyModule_Call(ctx, "SET", "sc", key, "value");
```

Format specifiers: `c` (C string), `s` (ValkeyModuleString), `l` (long long), `b` (buffer + length), `!` (replicate).

**Low-level** (direct key manipulation):
```c
ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, keyname, VALKEYMODULE_WRITE);
int type = ValkeyModule_KeyType(key);
ValkeyModule_StringSet(key, value);
ValkeyModule_SetExpire(key, 60000); // 60 second TTL
```

### Custom Native Types

Register new data types with RDB persistence callbacks:

```c
ValkeyModuleTypeMethods tm = {
    .version = VALKEYMODULE_TYPE_METHOD_VERSION,
    .rdb_load = MyTypeRdbLoad,
    .rdb_save = MyTypeRdbSave,
    .aof_rewrite = MyTypeAofRewrite,
    .free = MyTypeFree,
    .mem_usage = MyTypeMemUsage,
    .digest = MyTypeDigest,
};

MyType = ValkeyModule_CreateDataType(ctx, "MyType-AZ",
    MYTYPE_ENCODING_VERSION, &tm);
```

**Type name requirements**: Exactly 9 characters (A-Z, a-z, 0-9, underscore, hyphen). The name encodes into a 64-bit signature stored in RDB files (9 chars x 6 bits + 10 bits for encoding version).

**RDB persistence functions**:
- `ValkeyModule_SaveUnsigned()` / `ValkeyModule_LoadUnsigned()`
- `ValkeyModule_SaveSigned()` / `ValkeyModule_LoadSigned()`
- `ValkeyModule_SaveDouble()` / `ValkeyModule_LoadDouble()`
- `ValkeyModule_SaveString()` / `ValkeyModule_LoadString()`
- `ValkeyModule_SaveStringBuffer()` / `ValkeyModule_LoadStringBuffer()`

### Blocking Commands

```c
ValkeyModuleBlockedClient *bc = ValkeyModule_BlockClient(ctx,
    reply_callback, timeout_callback, free_callback, timeout_ms);
// Start background work...
// When done:
ValkeyModule_UnblockClient(bc, privdata);
```

### Thread-Safe Contexts

For operations from background threads:
```c
ValkeyModuleCtx *ctx = ValkeyModule_GetThreadSafeContext(bc);
ValkeyModule_ThreadSafeContextLock(ctx);
// ... perform operations ...
ValkeyModule_ThreadSafeContextUnlock(ctx);
ValkeyModule_FreeThreadSafeContext(ctx);
```

### Cluster Support

```c
if (ValkeyModule_IsKeysPositionRequest(ctx)) {
    ValkeyModule_KeyAtPos(ctx, 1); // Declare key position for slot routing
}
```

### Rust SDK

The `valkeymodule-rs` crate provides an idiomatic Rust API:

```toml
[dependencies]
valkey-module = "latest"

[lib]
crate-type = ["cdylib"]
```

```rust
use valkey_module::{valkey_module, Context, ValkeyResult, ValkeyString, ValkeyValue};

fn my_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    // Implementation
    Ok(ValkeyValue::SimpleStringStatic("OK"))
}

valkey_module! {
    name: "mymodule",
    version: 1,
    data_types: [],
    commands: [
        ["mymodule.cmd", my_command, "write", 1, 1, 1],
    ],
}
```

### Scripting Engine Modules (Valkey 8.1+)

A new module API enables external scripting engines beyond Lua. WASM is planned as a future candidate for sandbox-based script execution.

---

## 16. Valkey vs Redis: What Changed Since the Fork

### Fork Origin

Valkey forked from Redis 7.2.4 in March 2024 after Redis changed its license from BSD to a dual SSPL/RSAL model. Valkey maintains the BSD 3-clause license.

### Major Architectural Changes

**I/O Threading Rewrite (8.0)**: Complete overhaul of the I/O threading model with dynamic thread management, thread affinity, and memory access amortization. Redis 7.x had basic I/O threading; Valkey 8.0 delivers 3x throughput improvement.

**New Hashtable (8.1)**: Replaced the `dict` chained hash table with an open-addressing design using 64-byte cache-line-aligned buckets. 20-30 bytes savings per key, 10% throughput improvement.

**Dual-Channel Replication (8.0)**: Simultaneous RDB and command stream transfer on separate connections, reducing sync time and memory pressure.

**Atomic Slot Migration (9.0)**: Replaces key-by-key slot migration with atomic slot-level transfer using AOF format.

**Multi-Database Clustering (9.0)**: Full `SELECT` database support in cluster mode, breaking from Redis's cluster-mode limitation to DB 0.

### New Features Not in Redis

| Feature | Version | Description |
|---------|---------|-------------|
| Per-slot metrics | 8.0 | CPU, memory, network metrics per hash slot |
| RDMA support | 8.0 | Experimental Remote Direct Memory Access (275% throughput) |
| Dual-channel replication | 8.0 | Parallel RDB + stream sync |
| Key embedding in main dict | 8.0 | 9-10% memory reduction |
| New hashtable | 8.1 | Cache-line-aligned open addressing |
| Iterator prefetching | 8.1 | 3.5x faster KEYS/SCAN operations |
| SIMD optimizations | 8.1 | AVX2 for BITCOUNT (514%), HyperLogLog (12x) |
| COMMANDLOG | 8.1 | Large request/reply logging |
| SET IFEQ | 8.1 | Conditional string updates |
| Structured logging | 8.1 | logfmt format option |
| Hash field expiration | 9.0 | Per-field TTL (11 new commands) |
| DELIFEQ | 9.0 | Conditional delete |
| Geospatial polygons | 9.0 | Polygon-based geo queries |
| MPTCP support | 9.0 | Multipath TCP (~25% latency reduction) |
| AVX-512 optimizations | 9.0 | SIMD acceleration for more operations |
| TLS cert-based auth | 9.0 | Automatic mTLS client authentication |
| Pipeline prefetching | 9.0 | Batch key prefetch for pipelined commands |
| Zero-copy responses | 9.0 | 20% throughput for large responses |
| Bloom filters | 9.0 (bundle) | Native probabilistic data structure |
| Vector search | 9.0 (bundle) | AI workload support |
| JSON module | 9.0 (bundle) | Native JSON data type |

### Performance Comparison

| Metric | Redis 7.2 | Valkey 8.0 | Valkey 9.0 |
|--------|-----------|------------|------------|
| Throughput (SET) | ~360K RPS | ~1.19M RPS | ~1.66M RPS |
| Cluster scale | ~200 nodes | ~1000 nodes | ~2000 nodes |
| Max aggregate RPS | N/A | N/A | >1B RPS |

### Licensing

- **Valkey**: BSD 3-clause (permissive, unchanged from original Redis)
- **Redis 8+**: Tri-license (AGPLv3 / RSAL2 / SSPL)

---

## 17. Key Performance Optimizations for Contributors

Understanding these optimizations is essential for contributing performance-sensitive code:

### False Sharing Mitigation

When different threads access variables on the same 64-byte cache line, the CPU's cache coherence protocol forces expensive cache invalidation. Valkey strategically separates hot variables accessed by different threads into different cache lines. The approach prioritizes eliminating false sharing between the main thread and I/O threads (the actual bottleneck) while accepting it among I/O threads.

### Thread-Local Memory Tracking

Replaced global atomic counters with thread-local storage for memory tracking. Each thread updates a non-atomic local counter; the global total is computed on demand by summing all thread-local values.

### Memory Access Amortization

The `lookupKey` function consumed >40% of main thread time due to cache misses on large datasets. The solution interleaves memory prefetch instructions across batched commands, hiding memory latency by overlapping fetches for different keys.

### Profiling Methodology

For performance work on Valkey:
1. Use `perf` and Intel VTune Profiler to identify hot code paths
2. Use `perf c2c` to detect cache line contention
3. Pin processes with `taskset` on bare metal
4. Use loopback interface to minimize network variability
5. Establish baselines, implement isolated changes, remeasure
6. Use `valkey-benchmark` for standardized throughput/latency measurement

---

## 18. Quick Reference

### Essential Files for New Contributors

| File | What to Learn |
|------|--------------|
| `src/server.h` | Global state structure, all type definitions |
| `src/server.c` | Server initialization, `main()`, `serverCron()` |
| `src/ae.c` | Event loop - the heart of the server |
| `src/networking.c` | How clients connect and communicate |
| `src/db.c` | How commands interact with the database |
| `src/t_string.c` | Simplest command implementations to study |
| `src/object.c` | How Valkey objects (robj) work |
| `CONTRIBUTING.md` | Contribution requirements |
| `GOVERNANCE.md` | Decision-making process |
| `MAINTAINERS.md` | Who reviews and merges |
| `tests/README.md` | How to write and run tests |

### Common Development Commands

```bash
# Build and test cycle
make -j$(nproc) && make test

# Run specific integration test
./runtest --single unit/bitops

# Run specific unit test
make valkey-unit-tests && ./src/valkey-unit-tests --single test_sds.c

# Build with AddressSanitizer (CMake)
mkdir build-asan && cd build-asan
cmake .. -DCMAKE_BUILD_TYPE=Debug -DBUILD_SANITIZER=address
make -j$(nproc)

# Run with debug logging
./src/valkey-server --loglevel debug

# Connect with CLI
./src/valkey-cli

# Run benchmark
./src/valkey-benchmark -t set,get -n 1000000 -c 50 -P 16 --threads 4
```

### Community Links

| Resource | URL |
|----------|-----|
| GitHub | https://github.com/valkey-io/valkey |
| Website | https://valkey.io |
| Documentation | https://valkey.io/docs/ |
| Blog | https://valkey.io/blog/ |
| Commands Reference | https://valkey.io/commands/ |
| Topics/Internals | https://valkey.io/topics/ |
| GitHub Discussions | https://github.com/orgs/valkey-io/discussions |
| LFX Insights | https://insights.linuxfoundation.org/project/valkey |
| Performance Dashboard | https://perf-dashboard.valkey.io |
