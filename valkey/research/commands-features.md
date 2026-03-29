# Valkey Commands, Features, and Client Libraries Reference

> Research compiled from valkey.io official documentation, blog posts, and project resources.
> Sources: valkey.io/commands, valkey.io/topics, valkey.io/clients, valkey.io/blog, glide.valkey.io
> Last updated: 2026-03-29

---

## Table of Contents

1. [Command Reference Overview](#1-command-reference-overview)
2. [Valkey 8.0 New Features](#2-valkey-80-new-features)
3. [Valkey 9.0 New Features](#3-valkey-90-new-features)
4. [Conditional Write Commands (SET IFEQ, DELIFEQ)](#4-conditional-write-commands)
5. [Hash Field Expiration Commands](#5-hash-field-expiration-commands)
6. [GEOSEARCH Polygon Support](#6-geosearch-polygon-support)
7. [Numbered Databases in Cluster Mode](#7-numbered-databases-in-cluster-mode)
8. [Valkey GLIDE Client](#8-valkey-glide-client)
9. [Client Library Compatibility Matrix](#9-client-library-compatibility-matrix)
10. [Valkey Functions (FUNCTION LOAD/FCALL)](#10-valkey-functions)
11. [Stream Commands Deep Dive](#11-stream-commands-deep-dive)
12. [Client-Side Caching (CLIENT TRACKING)](#12-client-side-caching)

---

## 1. Command Reference Overview

Valkey supports 400+ commands organized by category. The full command set includes all Redis OSS 7.2 commands plus Valkey-specific additions. Below is a categorized summary of the complete command surface.

### String Commands

| Command | Description |
|---------|-------------|
| `SET` | Set key to value with optional EX/PX/NX/XX/IFEQ/GET/KEEPTTL |
| `GET` | Get value of key |
| `GETEX` | Get value and optionally set expiration |
| `GETDEL` | Get value and delete key |
| `GETSET` | Set value and return old value (deprecated, use SET GET) |
| `MGET` / `MSET` | Multi-get/multi-set |
| `MSETNX` | Set multiple keys only if none exist |
| `SETNX` | Set if not exists (deprecated, use SET NX) |
| `SETEX` / `PSETEX` | Set with expiry (deprecated, use SET EX/PX) |
| `APPEND` | Append to string |
| `INCR` / `INCRBY` / `INCRBYFLOAT` | Increment |
| `DECR` / `DECRBY` | Decrement |
| `STRLEN` | String length |
| `SETRANGE` / `GETRANGE` | Substring operations |
| `LCS` | Longest common substring |
| `DELIFEQ` | Delete if value equals (Valkey 9.0) |

### Hash Commands

| Command | Description |
|---------|-------------|
| `HSET` / `HGET` / `HMGET` / `HMSET` | Basic hash field operations |
| `HDEL` | Delete fields |
| `HEXISTS` | Check field existence |
| `HGETALL` / `HKEYS` / `HVALS` | Get all fields/keys/values |
| `HINCRBY` / `HINCRBYFLOAT` | Increment field value |
| `HLEN` | Number of fields |
| `HRANDFIELD` | Random field |
| `HSCAN` | Iterate fields |
| `HSETNX` | Set field if not exists |
| `HSTRLEN` | Field value length |
| `HEXPIRE` | Set field expiration in seconds (Valkey 9.0) |
| `HPEXPIRE` | Set field expiration in milliseconds (Valkey 9.0) |
| `HEXPIREAT` | Set field expiration at Unix timestamp (Valkey 9.0) |
| `HPEXPIREAT` | Set field expiration at Unix ms timestamp (Valkey 9.0) |
| `HEXPIRETIME` | Get field expiration Unix timestamp (Valkey 9.0) |
| `HPEXPIRETIME` | Get field expiration Unix ms timestamp (Valkey 9.0) |
| `HTTL` | Get field TTL in seconds (Valkey 9.0) |
| `HPTTL` | Get field TTL in milliseconds (Valkey 9.0) |
| `HPERSIST` | Remove field expiration (Valkey 9.0) |
| `HGETEX` | Get field values and set/remove expiration (Valkey 9.0) |
| `HSETEX` | Set field values with expiration options (Valkey 9.0) |
| `HGETDEL` | Get field values and delete fields (Valkey 9.1) |

### List Commands

`LPUSH`, `RPUSH`, `LPUSHX`, `RPUSHX`, `LPOP`, `RPOP`, `LRANGE`, `LINDEX`, `LINSERT`, `LLEN`, `LREM`, `LSET`, `LTRIM`, `LMOVE`, `LMPOP`, `LPOS`, `BLPOP`, `BRPOP`, `BLMOVE`, `BLMPOP`, `RPOPLPUSH` (deprecated), `BRPOPLPUSH` (deprecated).

### Set Commands

`SADD`, `SREM`, `SMEMBERS`, `SISMEMBER`, `SMISMEMBER`, `SCARD`, `SRANDMEMBER`, `SPOP`, `SMOVE`, `SDIFF`, `SDIFFSTORE`, `SINTER`, `SINTERSTORE`, `SINTERCARD`, `SUNION`, `SUNIONSTORE`, `SSCAN`.

### Sorted Set Commands

`ZADD`, `ZREM`, `ZSCORE`, `ZRANK`, `ZREVRANK`, `ZRANGE`, `ZRANGESTORE`, `ZRANGEBYSCORE` (deprecated), `ZRANGEBYLEX` (deprecated), `ZREVRANGE` (deprecated), `ZCOUNT`, `ZLEXCOUNT`, `ZCARD`, `ZINCRBY`, `ZRANDMEMBER`, `ZMSCORE`, `ZPOPMIN`, `ZPOPMAX`, `BZPOPMIN`, `BZPOPMAX`, `BZMPOP`, `ZMPOP`, `ZUNION`, `ZUNIONSTORE`, `ZINTER`, `ZINTERSTORE`, `ZINTERCARD`, `ZDIFF`, `ZDIFFSTORE`, `ZSCAN`.

### Stream Commands

`XADD`, `XREAD`, `XREADGROUP`, `XRANGE`, `XREVRANGE`, `XLEN`, `XTRIM`, `XDEL`, `XINFO` (STREAM/GROUPS/CONSUMERS), `XGROUP` (CREATE/SETID/DELCONSUMER/DESTROY/CREATECONSUMER), `XACK`, `XCLAIM`, `XAUTOCLAIM`, `XPENDING`.

### Geo Commands

`GEOADD`, `GEODIST`, `GEOHASH`, `GEOPOS`, `GEOSEARCH`, `GEOSEARCHSTORE`, `GEORADIUS` (deprecated), `GEORADIUSBYMEMBER` (deprecated).

### HyperLogLog

`PFADD`, `PFCOUNT`, `PFMERGE`.

### Bitmap Commands

`SETBIT`, `GETBIT`, `BITCOUNT`, `BITOP`, `BITPOS`, `BITFIELD`, `BITFIELD_RO`.

### Pub/Sub Commands

`SUBSCRIBE`, `UNSUBSCRIBE`, `PUBLISH`, `PSUBSCRIBE`, `PUNSUBSCRIBE`, `PUBSUB` (CHANNELS/NUMSUB/NUMPAT/SHARDCHANNELS/SHARDNUMSUB), `SSUBSCRIBE`, `SUNSUBSCRIBE`, `SPUBLISH`.

### Scripting and Functions

`EVAL`, `EVALSHA`, `EVAL_RO`, `EVALSHA_RO`, `SCRIPT` (LOAD/EXISTS/FLUSH/KILL/DEBUG/SHOW), `FUNCTION` (LOAD/DELETE/LIST/DUMP/RESTORE/FLUSH/STATS/KILL/HELP), `FCALL`, `FCALL_RO`.

### Cluster Commands

`CLUSTER` (INFO/NODES/SHARDS/MEET/FORGET/REPLICATE/FAILOVER/RESET/ADDSLOTS/ADDSLOTSRANGE/DELSLOTS/DELSLOTSRANGE/SETSLOT/FLUSHSLOTS/KEYSLOT/COUNTKEYSINSLOT/GETKEYSINSLOT/MYID/MYSHARDID/SAVECONFIG/LINKS/REPLICAS/BUMPEPOCH/SET-CONFIG-EPOCH/SLOT-STATS/MIGRATESLOTS/CANCELSLOTMIGRATIONS/GETSLOTMIGRATIONS/SYNCSLOTS/SLAVES (deprecated)/SLOTS (deprecated)), `READONLY`, `READWRITE`, `CLUSTERSCAN`.

### Server/Connection Commands

`AUTH`, `HELLO`, `PING`, `ECHO`, `QUIT`, `RESET`, `SELECT`, `CLIENT` (TRACKING/CACHING/SETNAME/GETNAME/ID/INFO/LIST/KILL/PAUSE/UNPAUSE/REPLY/SETINFO/NO-EVICT/NO-TOUCH/CAPA/IMPORT-SOURCE/TRACKINGINFO/GETREDIR/UNBLOCK/HELP), `CONFIG` (GET/SET/REWRITE/RESETSTAT), `INFO`, `DBSIZE`, `DEBUG`, `MONITOR`, `SAVE`, `BGSAVE`, `BGREWRITEAOF`, `LASTSAVE`, `FLUSHDB`, `FLUSHALL`, `SHUTDOWN`, `REPLICAOF`, `SLAVEOF` (deprecated), `FAILOVER`, `WAIT`, `ROLE`, `SWAPDB`, `COPY`, `MOVE`, `SCAN`, `OBJECT` (ENCODING/FREQ/IDLETIME/REFCOUNT/HELP), `DUMP`, `RESTORE`, `MIGRATE`, `RENAME`, `RENAMENX`, `DEL`, `UNLINK`, `EXISTS`, `TYPE`, `KEYS`, `RANDOMKEY`, `EXPIRE`, `PEXPIRE`, `EXPIREAT`, `PEXPIREAT`, `EXPIRETIME`, `PEXPIRETIME`, `TTL`, `PTTL`, `PERSIST`, `SORT`, `SORT_RO`, `TOUCH`, `MEMORY` (USAGE/DOCTOR/STATS/MALLOC-STATS/PURGE/HELP), `LATENCY` (DOCTOR/GRAPH/HISTORY/LATEST/RESET/HELP/HISTOGRAM), `SLOWLOG` (GET/LEN/RESET/HELP), `COMMANDLOG` (GET/LEN/RESET/HELP), `COMMAND` (COUNT/DOCS/GETKEYS/GETKEYSANDFLAGS/INFO/LIST/HELP), `MODULE` (LOAD/LOADEX/UNLOAD/LIST/HELP), `MULTI`, `EXEC`, `DISCARD`, `WATCH`, `UNWATCH`, `SUBSCRIBE`, `LOLWUT`.

### Bloom Filter Commands (Module)

`BF.ADD`, `BF.EXISTS`, `BF.MADD`, `BF.MEXISTS`, `BF.RESERVE`, `BF.INSERT`, `BF.INFO`, `BF.CARD`, `BF.LOAD`.

### JSON Commands (Module)

`JSON.SET`, `JSON.GET`, `JSON.MGET`, `JSON.MSET`, `JSON.DEL`, `JSON.FORGET`, `JSON.TYPE`, `JSON.NUMINCRBY`, `JSON.NUMMULTBY`, `JSON.STRAPPEND`, `JSON.STRLEN`, `JSON.ARRAPPEND`, `JSON.ARRINDEX`, `JSON.ARRINSERT`, `JSON.ARRLEN`, `JSON.ARRPOP`, `JSON.ARRTRIM`, `JSON.OBJKEYS`, `JSON.OBJLEN`, `JSON.CLEAR`, `JSON.TOGGLE`, `JSON.DEBUG`, `JSON.RESP`.

### Search Commands (Module)

`FT.CREATE`, `FT.SEARCH`, `FT.AGGREGATE`, `FT.DROPINDEX`, `FT.INFO`, `FT._LIST`.

---

## 2. Valkey 8.0 New Features

Released: 2024-09-16 (GA). First major release of Valkey post-fork.

### Performance - 3x Throughput Improvement

- **Asynchronous I/O Threading**: Main thread and I/O threads operate concurrently (previously serialized). Up to 1.2M QPS on AWS r7g (vs 380K QPS previously).
- **Intelligent Core Utilization**: I/O tasks distributed across cores based on real-time usage.
- **Command Batching**: Memory prefetching for frequently accessed data reduces CPU cache misses.
- References: PR #758, #763.

### Reliability - Cluster Slot Migration

- **Automatic Failover for Empty Shards**: New shards with no slots now get automatic failover.
- **Replication of Slot Migration States**: `CLUSTER SETSLOT` commands replicated synchronously to replicas before execution on primary.
- **Slot Migration State Recovery**: Automatic state update on failover.
- Reference: PR #445.

### Replication - Dual-Channel Replication

- RDB and replica backlog transferred simultaneously.
- Reduced memory load on primary during sync.
- Write latency improvements during sync; sync time cut by up to 50% under heavy reads.
- Reference: PR #60.

### Observability - Per-Slot Metrics

- `CLUSTER SLOT-STATS`: Key count, CPU usage, network I/O bytes per slot.
- Approximately 0.7% QPS overhead when enabled.
- References: PR #712, #720, #771.

### Efficiency - Memory Reduction

- Keys embedded in main dictionary (eliminated separate key pointers): 9-10% memory reduction for 16-byte keys with 8/16-byte values.
- Per-slot dictionary replaces linked list: saves 16 bytes per key-value pair.
- References: PR #541, Redis#11695.

### Additional 8.0 Highlights

- **Dual IPv4/IPv6 Stack Support**: Mixed IP environments (#736).
- **Improved Pub/Sub Efficiency**: Lightweight cluster messages (#654).
- **Valkey Over RDMA (Experimental)**: Up to 275% throughput increase via direct memory access (#477).
- **No backward-incompatible command changes**: Existing tools work immediately.

---

## 3. Valkey 9.0 New Features

Released: 2025-10-21. Second major release.

### Atomic Slot Migrations

Fundamentally changes how cluster data migrates node-to-node.

- **Before 9.0**: Key-by-key migration using move-then-delete. Caused redirect storms, mini-outages during multi-key operations, and blocked migrations for very large keys.
- **9.0**: Entire slots migrate atomically using AOF format. Individual collection items sent instead of whole keys. Original node retains all data until slot migration completes.
- Prevents large collection latency spikes.
- Eliminates redirect/retry issues and blocked migrations from oversized keys.

### Hash Field Expiration

Individual hash fields can now have their own TTL. See [Section 5](#5-hash-field-expiration-commands) for full command details.

New commands: `HEXPIRE`, `HEXPIREAT`, `HEXPIRETIME`, `HGETEX`, `HPERSIST`, `HPEXPIRE`, `HPEXPIREAT`, `HPEXPIRETIME`, `HPTTL`, `HSETEX`, `HTTL`.

### Numbered Databases in Cluster Mode

- Before 9.0: Cluster mode was restricted to a single database (db 0).
- 9.0: Full support for numbered databases in cluster mode (SELECT works in cluster).
- Enables data separation/namespace isolation within clusters.
- Breaks from the preceding project's restriction.

From cluster spec: "Starting with version 9.0, Valkey cluster supports multiple databases, similar to standalone mode but with some additional restrictions."

### Performance Improvements

- **1 Billion Requests/Second**: Scaling to 2,000 cluster nodes.
- **Pipeline Memory Prefetch**: Up to 40% higher throughput when pipelining.
- **Zero Copy Responses**: Large requests avoid internal memory copying, up to 20% higher throughput.
- **Multipath TCP**: Latency reduced by up to 25%.
- **SIMD for BITCOUNT and HyperLogLog**: Up to 200% higher throughput.

### New Commands

- **DELIFEQ**: Conditional delete if value equals. See [Section 4](#4-conditional-write-commands).
- **SET IFEQ**: Conditional set if current value equals. See [Section 4](#4-conditional-write-commands).
- **GEOSEARCH BYPOLYGON**: Polygon-based geospatial queries. See [Section 6](#6-geosearch-polygon-support).
- **CLIENT LIST Filtering**: Filter by flags, name, idle, library name/version, database, IP, capabilities.
- **HGETDEL**: Get hash field values and delete them atomically (9.1).

### Other Changes

- **Un-deprecation**: 25 previously deprecated commands restored (API backward compatibility stance).
- **LOLWUT**: New generative art piece for version 9.

---

## 4. Conditional Write Commands

### SET with IFEQ Option

**Since**: Valkey 8.1.0

```
SET key value [NX | XX | IFEQ comparison-value] [GET]
    [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL]
```

**IFEQ behavior**: Sets the key only if the current stored value is a string that exactly matches `comparison-value`. Returns error if stored value is not a string. Mutually exclusive with NX and XX.

**Example**:
```
> SET foo "Initial Value"
OK
> SET foo "New Value" IFEQ "Initial Value"
OK
> GET foo
"New Value"
> SET foo "Another" IFEQ "Initial Value"
(nil)    # comparison failed, value was "New Value"
```

**With GET**: When using `GET` + `IFEQ`, the key was set if the reply equals `comparison-value`.

**Use case**: Compare-and-swap (CAS) operations. Update a value atomically only if it hasn't been changed by another client since you last read it.

### DELIFEQ

**Since**: Valkey 9.0.0

```
DELIFEQ key value
```

Complexity: O(1). Deletes the key if its stored string value exactly matches the provided value.

**Return values**:
- `1` if the key was deleted (value matched).
- `0` if the key was not deleted (didn't exist or value didn't match).
- Error if stored value is not a string type.

**Example - Safe Lock Release**:
```
> SET mykey abc123
OK
> DELIFEQ mykey abc123
(integer) 1
> DELIFEQ mykey abc123
(integer) 0     # already deleted
```

**Example - Wrong value**:
```
> SET mykey xyz789
OK
> DELIFEQ mykey abc123
(integer) 0     # value doesn't match
```

**Primary use case**: Safely releasing distributed locks. Replaces the Lua script pattern:

```
-- Old way (Lua script):
EVAL "if redis.call('GET',KEYS[1]) == ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end" 1 mykey abc123

-- New way (native command):
DELIFEQ mykey abc123
```

This is the canonical Redlock unlock pattern, now available as a first-class atomic command.

---

## 5. Hash Field Expiration Commands

All new in Valkey 9.0 (except HGETDEL which is 9.1). These commands enable per-field TTL on hash data types.

### HEXPIRE - Set Field Expiration (Seconds)

```
HEXPIRE key seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

**Options**:
- `NX` - Set expiration only when the field has no expiration.
- `XX` - Set expiration only when the field already has an expiration.
- `GT` - Set only when new expiration is greater than current.
- `LT` - Set only when new expiration is less than current.

**Return values** (per field):
- `-2`: Field does not exist in hash, or key does not exist.
- `0`: NX/XX/GT/LT condition not met.
- `1`: Expiration time was applied.
- `2`: Called with 0 seconds (immediate expiration).

**Example**:
```
> HSET myhash f1 v1 f2 v2 f3 v3
(integer) 3
> HEXPIRE myhash 10 FIELDS 2 f2 f3
1) (integer) 1
2) (integer) 1
> HTTL myhash FIELDS 3 f1 f2 f3
1) (integer) -1     # f1 has no expiration
2) (integer) 8      # f2 expires in ~8s
3) (integer) 8      # f3 expires in ~8s
```

Note: Providing 0 seconds causes immediate expiration and deletion.

### HPEXPIRE - Set Field Expiration (Milliseconds)

```
HPEXPIRE key milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

Same as HEXPIRE but in milliseconds.

### HEXPIREAT / HPEXPIREAT - Set Field Expiration at Unix Timestamp

```
HEXPIREAT key unix-time-seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
HPEXPIREAT key unix-time-milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
```

### HTTL / HPTTL - Get Field TTL

```
HTTL key FIELDS numfields field [field ...]
HPTTL key FIELDS numfields field [field ...]
```

Returns TTL in seconds/milliseconds. `-1` = no expiration, `-2` = field doesn't exist.

### HEXPIRETIME / HPEXPIRETIME - Get Field Expiration Timestamp

```
HEXPIRETIME key FIELDS numfields field [field ...]
HPEXPIRETIME key FIELDS numfields field [field ...]
```

### HPERSIST - Remove Field Expiration

```
HPERSIST key FIELDS numfields field [field ...]
```

### HGETEX - Get Values and Set/Remove Expiration

```
HGETEX key [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | PERSIST]
    FIELDS numfields field [field ...]
```

Returns field values (like HMGET) and atomically sets/removes expiration. Without options, behaves exactly like HMGET.

**Example**:
```
> HSET myhash f1 v1 f2 v2 f3 v3
(integer) 3
> HGETEX myhash EX 10 FIELDS 2 f2 f3
1) "v2"
2) "v3"
> HTTL myhash FIELDS 3 f1 f2 f3
1) (integer) -1
2) (integer) 8
3) (integer) 8
```

Setting EX 0 causes immediate expiration:
```
> HGETEX myhash EX 0 FIELDS 3 f1 f2 f3
1) "v1"      # returns values before deletion
2) "v2"
3) "v3"
> HGETEX myhash FIELDS 3 f1 f2 f3
1) (nil)     # fields are gone
2) (nil)
3) (nil)
```

### HSETEX - Set Values with Expiration Options

```
HSETEX key [NX | XX] [FNX | FXX]
    [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL]
    FIELDS numfields field value [field value ...]
```

**Key-level options**: NX (key must not exist), XX (key must exist).
**Field-level options**: FNX (set only if none of the fields exist), FXX (set only if all fields exist).

Returns `1` if all fields set, `0` if condition prevented setting.

**Example**:
```
> HSETEX myhash FIELDS 3 f1 v1 f2 v2 f3 v3
(integer) 1
> HSETEX myhash FNX EX 10 FIELDS 2 f2 v2 f3 v3
(integer) 0    # fields already exist, FNX fails
> HSETEX myhash FXX EX 10 FIELDS 2 f2 v2 f3 v3
(integer) 1    # fields exist, FXX succeeds
```

Setting a value on a volatile field (has TTL) removes the expiration unless KEEPTTL is used.

### HGETDEL - Get Values and Delete Fields (Valkey 9.1)

```
HGETDEL key FIELDS numfields field [field ...]
```

Returns values and atomically deletes the fields. When the last field is deleted, the key is also deleted.

**Example**:
```
> HSET myhash f1 v1 f2 v2 f3 v3
(integer) 3
> HGETDEL myhash FIELDS 1 f2
1) "v2"
> HGETDEL myhash FIELDS 1 f2
1) (nil)     # already deleted
> HGETALL myhash
1) "f1"
2) "v1"
3) "f3"
4) "v3"
```

---

## 6. GEOSEARCH Polygon Support

**Since**: Valkey 9.0.0 (BYPOLYGON option)

### Full Syntax

```
GEOSEARCH key
    [FROMMEMBER member | FROMLONLAT longitude latitude]
    < BYRADIUS radius <m|km|ft|mi>
    | BYBOX width height <m|km|ft|mi>
    | BYPOLYGON num-vertices longitude latitude [longitude latitude ...] >
    [ASC | DESC]
    [COUNT count [ANY]]
    [WITHCOORD] [WITHDIST] [WITHHASH]
```

### Shape Options

- **BYRADIUS**: Search within a circle. Requires FROMMEMBER or FROMLONLAT for center.
- **BYBOX**: Search within an axis-aligned rectangle. Requires FROMMEMBER or FROMLONLAT for center.
- **BYPOLYGON** (9.0): Search within an arbitrary polygon. Center point and bounding box are computed from the polygon vertices. `FROMMEMBER` and `FROMLONLAT` are invalid with BYPOLYGON.

### BYPOLYGON Format

```
BYPOLYGON <num-vertices> <lon1> <lat1> <lon2> <lat2> ... <lonN> <latN>
```

The polygon is defined by `num-vertices` pairs of longitude/latitude coordinates. The polygon does not need to be explicitly closed (the last vertex connects back to the first).

### Example

```
> GEOADD Sicily 13.361389 38.115556 "Palermo" 15.087269 37.502669 "Catania"
(integer) 2
> GEOADD Sicily 12.758489 38.788135 "edge1" 17.241510 38.788135 "edge2"
(integer) 2

-- Circular search
> GEOSEARCH Sicily FROMLONLAT 15 37 BYRADIUS 200 km ASC
1) "Catania"
2) "Palermo"

-- Box search with coordinates and distances
> GEOSEARCH Sicily FROMLONLAT 15 37 BYBOX 400 400 km ASC WITHCOORD WITHDIST
1) 1) "Catania"
   2) "56.4413"
   3) 1) "15.08726745843887329"
      2) "37.50266842333162032"
2) 1) "Palermo"
   2) "190.4424"
   3) 1) "13.36138933897018433"
      2) "38.11555639549629859"
...

-- Polygon search (5 vertices)
> GEOSEARCH Sicily BYPOLYGON 5 12.41 38.05 15.11 38.01 18.15 38.64 17.81 39.50 12.46 38.58
1) "Palermo"
2) "edge2"

-- Polygon search with coordinates and distances
> GEOSEARCH Sicily BYPOLYGON 5 12.41 38.05 15.11 38.01 18.15 38.64 17.81 39.50 12.46 38.58 ASC WITHCOORD WITHDIST
1) 1) "Palermo"
   2) "166482.0159"
   3) 1) "13.36138933897018433"
      2) "38.11555639549629859"
2) 1) "edge2"
   2) "180861.7725"
   3) 1) "17.24151045083999634"
      2) "38.78813451624225195"
```

### Complexity

O(N+log(M)) where N is the number of elements in the grid-aligned bounding box around the shape and M is the number of items inside the shape.

### GEOSEARCHSTORE

`GEOSEARCHSTORE` also supports BYPOLYGON with the same syntax, storing results into a destination sorted set.

---

## 7. Numbered Databases in Cluster Mode

### Background

Numbered databases (via `SELECT`) allow data separation and key namespace isolation. Each database (0-15 by default) contains its own keyspace. This is one of the oldest features, dating to the very first version of the original project.

### Pre-9.0 Limitation

Before Valkey 9.0, cluster mode was restricted to a single database (db 0). The `SELECT` command returned an error for any database other than 0 in cluster mode. This made numbered databases impractical since using them prevented scaling beyond a single node.

### Valkey 9.0 Change

Valkey 9.0 adds full support for numbered databases in cluster mode. This is a deliberate break from the preceding project.

From the cluster specification: "Starting with version 9.0, Valkey cluster supports multiple databases, similar to standalone mode but with some additional restrictions."

### Key Behaviors

- `SELECT <db>` works in cluster mode, selecting databases 0 through (databases-1).
- Slot calculation includes the database number - the same key name in different databases may map to different slots.
- `MOVE` command works across databases within the same node.
- All existing cluster semantics (slot-based sharding, MOVED/ASK redirections) apply per-database.
- `FLUSHDB` flushes only the selected database, `FLUSHALL` flushes all.

### Use Cases

- **Namespace isolation**: Separate application concerns (sessions in db 1, cache in db 2) within the same cluster.
- **Testing/staging**: Use different databases for different environments on the same cluster.
- **Migration**: Allows gradual migration from standalone (multi-db) setups to cluster without losing database separation.

### Configuration

```
databases 16     # default, configurable like standalone mode
```

---

## 8. Valkey GLIDE Client

GLIDE (General Language Independent Driver for the Enterprise) is Valkey's official multi-language client library.

### Architecture

- **Core**: Written in Rust for high performance and memory safety.
- **Bindings**: Language-specific bindings for Python, Java, Node.js, Go, with C# coming soon.
- **Design goals**: Reliability, optimized performance, high availability.

### Installation

| Language | Package |
|----------|---------|
| Python | `pip install valkey-glide` |
| Node.js | `npm install @valkey/valkey-glide` |
| Java (Maven) | `io.valkey:valkey-glide:<classifier>` (osx-aarch_64, linux-aarch_64, linux-x86_64) |
| Go | `go get github.com/valkey-io/valkey-glide/go` |

Current version: v2.1.1 (released 2025-10-08).

### Key Features (from feature matrix)

GLIDE has the broadest feature support among all official Valkey clients:

| Feature | GLIDE | Others |
|---------|-------|--------|
| Read from Replica | Yes | Varies |
| Smart Backoff (Connection Storm Prevention) | Yes | Most |
| PubSub State Restoration | Yes | No (except valkey-go, redisson) |
| Cluster Scan | Yes | No (most) |
| AZ-Based Read from Replica | Yes | No (except valkey-go) |
| Latency-Based Read from Replica | No | No (except redisson partially) |
| Client-Side Caching | No | valkey-go, redisson |
| Persistent Connection Pool | No | Some |

### GLIDE vs Traditional Clients

**Advantages over ioredis/redis-py/jedis/go-redis**:
- Rust core ensures memory safety and performance consistency.
- Unified API across all languages.
- Built-in cluster scan support (consistent behavior across cluster/standalone).
- Automatic PubSub state restoration after failovers and topology changes.
- Smart backoff prevents connection storms during topology updates.

**When to use traditional clients instead**:
- Client-side caching needed (valkey-go has native support).
- Persistent connection pools needed (valkey-py, valkey-java, phpredis support this).
- Platform not supported (e.g., Windows development).
- Lighter dependency footprint needed (GLIDE includes Rust native binary).

---

## 9. Client Library Compatibility Matrix

### Official/Recommended Clients by Language

| Language | Client | Version | License | Notes |
|----------|--------|---------|---------|-------|
| **Python** | valkey-glide | v2.1.1 | Apache-2.0 | Rust core, multi-language |
| **Python** | valkey-py | 6.1.0 | MIT | Fork of redis-py |
| **Node.js** | @valkey/valkey-glide | v2.1.1 | Apache-2.0 | Rust core |
| **Node.js** | iovalkey | v0.3.1 | MIT | Fork of ioredis |
| **Java** | valkey-glide | v2.1.1 | Apache-2.0 | Rust core |
| **Java** | valkey-java | v5.3.0 | MIT | Fork of jedis |
| **Java** | redisson | v3.48.0 | Apache-2.0 | 50+ Java objects/services |
| **Go** | valkey-glide | v2.1.1 | Apache-2.0 | Rust core |
| **Go** | valkey-go | 1.0.67 | Apache-2.0 | Auto-pipelining, client-side caching |
| **PHP** | phpredis | 6.1.0 | PHP-3.01 | C extension |
| **PHP** | predis | v2.3.0 | MIT | Pure PHP |
| **Swift** | valkey-swift | v1.0.0 | Apache-2.0 | First-party Swift client |

### Third-Party Redis Client Compatibility

Any Redis client supporting Redis OSS 7.2 protocol is compatible with Valkey 7.2+. Specific compatibility notes:

| Client | Status with Valkey | Notes |
|--------|--------------------|-------|
| **ioredis** (Node.js) | Compatible | iovalkey is the Valkey-native fork |
| **redis-py** (Python) | Compatible | valkey-py is the Valkey-native fork |
| **jedis** (Java) | Compatible | valkey-java is the Valkey-native fork |
| **go-redis** (Go) | Compatible | valkey-go is the dedicated replacement |
| **Lettuce** (Java) | Compatible | Works with Valkey, no fork needed |
| **node-redis** (Node.js) | Compatible | Works with Valkey directly |
| **hiredis** (C) | Compatible | Low-level protocol library |

### Advanced Feature Comparison Table

| Feature | GLIDE (py) | valkey-py | GLIDE (node) | iovalkey | GLIDE (java) | valkey-java | redisson | GLIDE (go) | valkey-go | phpredis | predis | valkey-swift |
|---------|-----------|-----------|-------------|----------|-------------|-------------|----------|-----------|-----------|----------|--------|-------------|
| Read from Replica | Yes | Yes | Yes | Yes | Yes | No | Yes | Yes | Yes | Yes | Yes | Yes |
| Smart Backoff | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| PubSub Restoration | Yes | No | Yes | No | Yes | No | Yes | Yes | Yes | No | No | No |
| Cluster Scan | Yes | No | Yes | No | Yes | No | Yes | Yes | No | No | No | No |
| Latency-Based Replica | No | No | No | No | No | No | No | No | No | No | No | No |
| AZ-Based Replica | Yes | No | Yes | No | Yes | No | No | Yes | Yes | No | No | No |
| Client-Side Caching | No | No | No | No | No | No | Yes | No | Yes | No | No | No |
| Client Capa Redirect | No | No | No | No | No | Yes | Yes | No | Yes | No | No | Yes |
| Persistent Conn Pool | No | Yes | No | Yes | No | Yes | Yes | No | Yes | Yes | No | Yes |

---

## 10. Valkey Functions

### Overview

Functions are first-class server-side code artifacts, introduced in version 7.0. Unlike EVAL scripts which are ephemeral, functions are persisted, replicated, and managed as part of the database.

### Functions vs EVAL Scripts

| Aspect | EVAL Scripts | Functions |
|--------|-------------|-----------|
| Persistence | Ephemeral (script cache) | Persisted to AOF, replicated |
| Loading | Client sends full script each time (or EVALSHA) | Loaded once, called by name |
| Naming | SHA1 hash | User-defined function name |
| Organization | Individual scripts | Libraries containing multiple functions |
| Calling other code | Cannot call other scripts | Can call functions in same library |
| Management | SCRIPT LOAD/EXISTS/FLUSH | FUNCTION LOAD/LIST/DELETE/DUMP/RESTORE |
| Durability | Lost on restart/failover | Survives restart/failover |
| Debugging | SHA1 hashes are opaque | Named functions in named libraries |

### FUNCTION LOAD

```
FUNCTION LOAD [REPLACE] function-code
```

Since: 7.0.0. Complexity: O(1).

The library code must start with a Shebang: `#!<engine> name=<library-name>`. Currently the only engine is `lua`.

**Example - Loading a library**:
```
> FUNCTION LOAD "#!lua name=mylib \n server.register_function('myfunc', function(keys, args) return args[1] end)"
"mylib"
```

**REPLACE option**: Overwrites an existing library with the same name. Function names must still be globally unique across all libraries.

**Error conditions**:
- Invalid engine name.
- Library name already exists (without REPLACE).
- Function name already exists in another library (even with REPLACE).
- Compilation error.
- No functions registered.

### FCALL / FCALL_RO

```
FCALL function numkeys [key [key ...]] [arg [arg ...]]
FCALL_RO function numkeys [key [key ...]] [arg [arg ...]]
```

Since: 7.0.0.

- `function`: Name of a registered function.
- `numkeys`: Number of key name arguments that follow.
- Keys are available as the first argument (table) to the Lua callback.
- Args are available as the second argument (table).
- `FCALL_RO`: Read-only variant, can be sent to replicas.

**Example**:
```
> FCALL myfunc 0 hello
"hello"
```

### Real-World Function Patterns

**Rate Limiter**:
```lua
#!lua name=ratelimit
server.register_function('check_rate', function(keys, args)
    local key = keys[1]
    local limit = tonumber(args[1])
    local window = tonumber(args[2])
    local current = tonumber(server.call('GET', key) or '0')
    if current >= limit then
        return 0
    end
    server.call('INCR', key)
    if current == 0 then
        server.call('EXPIRE', key, window)
    end
    return 1
end)
```

**Atomic Transfer**:
```lua
#!lua name=transfer
server.register_function('transfer_funds', function(keys, args)
    local from = keys[1]
    local to = keys[2]
    local amount = tonumber(args[1])
    local balance = tonumber(server.call('GET', from) or '0')
    if balance < amount then
        return server.error_reply('insufficient funds')
    end
    server.call('DECRBY', from, amount)
    server.call('INCRBY', to, amount)
    return 'OK'
end)
```

**Registration with Flags**:
```lua
#!lua name=mylib
server.register_function{
    function_name = 'my_readonly_func',
    callback = function(keys, args)
        return server.call('GET', keys[1])
    end,
    flags = { 'no-writes' }
}
```

### Managing Functions

```
FUNCTION LIST [LIBRARYNAME pattern] [WITHCODE]  -- List loaded libraries
FUNCTION DELETE library-name                      -- Delete a library
FUNCTION DUMP                                     -- Serialize all functions
FUNCTION RESTORE serialized-data [FLUSH|APPEND|REPLACE]  -- Restore functions
FUNCTION FLUSH [ASYNC|SYNC]                       -- Delete all functions
FUNCTION STATS                                    -- Running function info
FUNCTION KILL                                     -- Kill running function
```

---

## 11. Stream Commands Deep Dive

### Architecture

Streams are append-only log data structures with O(1) random access. Implemented as radix trees for efficient inserts and lookups.

Entry IDs format: `<millisecondsTime>-<sequenceNumber>`. Auto-generated IDs are monotonically increasing.

### Core Commands

**XADD** - Append entry:
```
XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]] *|id field value [field value ...]
```

**XREAD** - Read entries (fan-out to multiple consumers):
```
XREAD [COUNT count] [BLOCK milliseconds] STREAMS key [key ...] id [id ...]
```

**XRANGE / XREVRANGE** - Range queries:
```
XRANGE key start end [COUNT count]
XREVRANGE key end start [COUNT count]
```

**XLEN** - Stream length. **XTRIM** - Trim stream. **XDEL** - Delete entries.

### Consumer Groups

Consumer groups enable partitioned processing where each message is delivered to exactly one consumer in the group.

**Creating a group**:
```
XGROUP CREATE mystream mygroup 0       -- from beginning
XGROUP CREATE mystream mygroup $       -- from current end
XGROUP CREATE mystream mygroup $ MKSTREAM  -- create stream if not exists
```

**XREADGROUP** - Read with consumer group:
```
XREADGROUP GROUP group consumer [COUNT count] [BLOCK milliseconds] [NOACK] STREAMS key [key ...] id [id ...]
```

Key behaviors:
- Use `>` as ID to receive only new, never-delivered messages.
- Use `0` (or any other ID) to re-read pending messages for that consumer.
- Messages are added to the consumer's PEL (Pending Entries List) on delivery.
- `NOACK` skips PEL tracking (for fire-and-forget patterns).
- `BLOCK` enables blocking read (same as XREAD blocking).

**Processing loop pattern**:
```
WHILE true
    entries = XREADGROUP GROUP mygroup consumer1 BLOCK 2000 COUNT 10 STREAMS mystream >
    if entries == nil
        continue    # timeout, retry
    end
    FOREACH entry
        process(entry)
        XACK mystream mygroup entry.id
    end
end
```

### Pending Entries and Recovery

**XPENDING** - Inspect pending entries:
```
-- Summary form
XPENDING mystream mygroup
> 1) (integer) 2              # total pending
> 2) "1526984818136-0"        # smallest pending ID
> 3) "1526984818136-0"        # greatest pending ID
> 4) 1) 1) "consumer-123"    # consumers with pending
>       2) "2"

-- Extended form
XPENDING mystream mygroup - + 10 [consumer]
> 1) 1) "1526984818136-0"     # message ID
>    2) "consumer-123"         # current owner
>    3) (integer) 196415       # idle time (ms)
>    4) (integer) 1            # delivery count

-- With idle filter (find stale messages)
XPENDING mystream mygroup IDLE 60000 - + 10
```

### XAUTOCLAIM - Automatic Recovery

```
XAUTOCLAIM key group consumer min-idle-time start [COUNT count] [JUSTID]
```

Transfers ownership of pending entries that have been idle longer than `min-idle-time` milliseconds. Combines XPENDING + XCLAIM into one command with SCAN-like cursor semantics.

**Return value**:
1. Next cursor ID (use as `start` for next call; `0-0` when complete).
2. Array of claimed messages (in XRANGE format).
3. Array of message IDs that no longer exist (cleaned from PEL).

**Example**:
```
> XAUTOCLAIM mystream mygroup Alice 3600000 0-0 COUNT 25
1) "0-0"                           # scan complete
2) 1) 1) "1609338752495-0"         # claimed message
      2) 1) "field"
         2) "value"
3) (empty array)                   # no deleted messages found
```

**JUSTID option**: Returns only message IDs (not message bodies). Does not increment the delivery counter.

**Recovery pattern**:
```
-- Periodically run XAUTOCLAIM to recover from failed consumers
cursor = "0-0"
WHILE true
    result = XAUTOCLAIM mystream mygroup recovery-consumer 300000 cursor COUNT 50
    cursor = result[0]
    process(result[1])    # process claimed messages
    if cursor == "0-0"
        SLEEP(interval)   # wait before next sweep
        cursor = "0-0"    # restart scan
    end
end
```

### XCLAIM - Manual Message Claiming

```
XCLAIM key group consumer min-idle-time id [id ...] [IDLE ms] [TIME ms] [RETRYCOUNT count] [FORCE] [JUSTID] [LASTID id]
```

Explicitly transfer ownership of specific message IDs to a new consumer. Used when you know which messages to reclaim. XAUTOCLAIM is preferred for automatic recovery.

### XACK - Acknowledge Messages

```
XACK key group id [id ...]
```

Removes messages from the PEL. Must be called after successful processing.

### Stream Trimming

```
XTRIM key MAXLEN [=|~] threshold [LIMIT count]
XTRIM key MINID [=|~] threshold [LIMIT count]
```

- `MAXLEN`: Keep at most N entries.
- `MINID`: Keep entries with ID >= threshold.
- `~` (approximate): More efficient, trims to nearest radix tree node.

### XINFO - Stream Metadata

```
XINFO STREAM key [FULL [COUNT count]]    -- Stream details
XINFO GROUPS key                          -- Consumer group info
XINFO CONSUMERS key group                 -- Consumer info within group
```

---

## 12. Client-Side Caching

### Overview

Client-side caching stores a subset of Valkey data in application memory for sub-millisecond access. Valkey provides server-assisted invalidation to keep cached data fresh.

### CLIENT TRACKING Command

```
CLIENT TRACKING <ON|OFF> [REDIRECT client-id] [PREFIX prefix [...]] [BCAST] [OPTIN] [OPTOUT] [NOLOOP]
```

Since: 6.0.0.

### Two Modes

**Default Mode (Invalidation-on-use)**:
- Server remembers which keys each client accessed.
- Sends invalidation messages only for keys the client has cached.
- Costs memory on server side (Invalidation Table).
- More bandwidth-efficient.

**Broadcasting Mode (BCAST)**:
- Server does NOT remember per-client key access.
- Clients subscribe to key prefixes.
- All clients get notifications for all matching keys.
- Zero memory cost on server side.
- Higher bandwidth usage.

### Options

| Option | Description |
|--------|-------------|
| `REDIRECT <id>` | Send invalidation messages to a different connection (by client ID). Required for RESP2 two-connection model. |
| `BCAST` | Enable broadcasting mode. |
| `PREFIX <prefix>` | In broadcast mode, only track keys starting with this prefix. Can specify multiple. |
| `OPTIN` | Default mode only. Don't track keys unless preceded by `CLIENT CACHING yes`. |
| `OPTOUT` | Default mode only. Track all read keys unless preceded by `CLIENT CACHING no`. |
| `NOLOOP` | Don't send invalidations for keys modified by this same connection. |

### Protocol - RESP3 (Single Connection)

With RESP3, invalidation messages arrive as push messages on the same connection:

```
Client 1 -> Server: CLIENT TRACKING ON
Client 1 -> Server: GET foo
(Server remembers Client 1 may have "foo" cached)

Client 2 -> Server: SET foo SomeOtherValue

Server -> Client 1: INVALIDATE "foo"
(Client 1 evicts "foo" from local cache)
```

### Protocol - RESP2 (Two Connections)

RESP2 requires a dedicated connection for invalidation via Pub/Sub:

```
-- Connection 1 (invalidation channel)
CLIENT ID
:4
SUBSCRIBE __redis__:invalidate
*3 $9 subscribe $20 __redis__:invalidate :1

-- Connection 2 (data)
CLIENT TRACKING on REDIRECT 4
+OK
GET foo
$3 bar

-- When foo is modified by any client:
-- Connection 1 receives:
*3 $7 message $20 __redis__:invalidate *1 $3 foo
```

The `__redis__:invalidate` channel name is the standard Pub/Sub channel for invalidation messages.

### Invalidation Table

Server-side data structure that maps keys to client IDs:
- Global table with configurable maximum entries (`tracking-table-max-keys`).
- When full, evicts oldest entries by sending "phantom" invalidation messages.
- Client IDs (not pointers) stored - garbage collected incrementally on disconnect.
- Single key namespace (not per-database) - simplifies implementation.

### OPTIN / OPTOUT Patterns

**OPTIN** (selective caching):
```
CLIENT TRACKING ON OPTIN
CLIENT CACHING yes          -- enable for next read command only
GET user:1234               -- this key will be tracked
GET user:5678               -- this key will NOT be tracked (no preceding CACHING yes)
```

**OPTOUT** (cache everything except specific reads):
```
CLIENT TRACKING ON OPTOUT
GET user:1234               -- tracked by default
CLIENT CACHING no           -- disable for next read
GET temp:session             -- NOT tracked
GET user:5678               -- tracked again
```

### Broadcasting Mode Usage

```
CLIENT TRACKING ON BCAST PREFIX user: PREFIX session:
-- Now receives invalidations for ALL keys starting with "user:" or "session:"
-- regardless of what this client actually reads
```

### FLUSH Handling

When `FLUSHALL` or `FLUSHDB` is executed, a null/nil invalidation message is sent to all tracking clients, signaling that all cached data should be evicted.

### Best Practices

1. **Cache popular, infrequently-changing data** - user profiles, configuration, rarely-updated content.
2. **Use OPTIN mode** for fine-grained control over what gets cached.
3. **Use BCAST with PREFIX** for shared caches where multiple services need the same data.
4. **Set reasonable tracking-table-max-keys** - too low causes premature evictions, too high wastes server memory.
5. **Handle invalidation promptly** - stale data can cause consistency issues.
6. **Use NOLOOP** when the same connection writes and reads - avoids self-invalidation noise.
7. **Implement local TTL** as a fallback - even with tracking, have a maximum local cache lifetime.

### Client Library Support

| Client | Client-Side Caching |
|--------|-------------------|
| valkey-go | Yes (server-assisted) |
| redisson | Yes |
| valkey-glide | No (planned) |
| iovalkey | No |
| valkey-py | No |
| valkey-java | No |

---

## Sources

- Valkey Command Reference: https://valkey.io/commands/
- Valkey 8.0 GA: https://valkey.io/blog/valkey-8-ga/
- Valkey 8.0 RC1 Features: https://valkey.io/blog/valkey-8-0-0-rc1/
- Valkey 9.0 Announcement: https://valkey.io/blog/introducing-valkey-9/
- Client Libraries: https://valkey.io/clients/
- GLIDE Website: https://glide.valkey.io/
- Client-Side Caching: https://valkey.io/topics/client-side-caching/
- Functions Introduction: https://valkey.io/topics/functions-intro/
- Streams Introduction: https://valkey.io/topics/streams-intro/
- Cluster Specification: https://valkey.io/topics/cluster-spec/
- Individual command pages: https://valkey.io/commands/{command-name}/
