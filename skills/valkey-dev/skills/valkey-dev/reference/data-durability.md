# Persistence and Replication

RDB/AOF writers and replication consumers share the same RDB serialization format, so they live here together.

## RDB (`src/rdb.c`, `src/rdb.h`)

Fork-based snapshot mechanics unchanged. Valkey-specific:

### Magic + version

- `RDB_VERSION = 80` in `rdb.h`, 9-byte magic `VALKEY080`.
- Legacy `REDIS0011` (RDB 11) still accepted on load.
- Versions 12-79 are the "foreign" range (`RDB_FOREIGN_VERSION_MIN = 12`, `MAX = 79`) - rejected by default (`rdbIsForeignVersion`), loadable only with explicit override. This blocks Redis CE 7.4+ RDB files.

### New/extended RDB types (in `rdb.h`)

- `RDB_TYPE_SET_LISTPACK = 20` (pre-Valkey, added in RDB 11 - kept for awareness).
- `RDB_TYPE_HASH_2 = 22` (**Valkey-new in RDB 80**): hash with field-level TTL. Load/save paths branch on `rdbtype == RDB_TYPE_HASH_2` to attach expiry metadata per field.

If you add a new RDB type, bump the RDB version. `rdbIsForeignVersion` + `rdbIsVersionAccepted` gate loads.

### Aux fields

Both `valkey-ver` and `redis-ver` are written. Loaders recognize either, so third-party tools expecting `redis-ver` still work.

### Return codes

`RDB_OK`, `RDB_NOT_EXIST`, `RDB_INCOMPATIBLE`, `RDB_FAILED`.

### Diskless sync

40-byte random hex EOF marker terminates the socket stream; verified on the receiving side.

## AOF (`src/aof.c`)

Multi-part AOF (manifest + BASE + INCR under `appendonlydir/`) unchanged from Redis 7.0+. Valkey-specific:

- **BASE file magic**: when `aof-use-rdb-preamble yes` (default), the RDB preamble uses `VALKEY080` in new files. AOF loader accepts either `REDIS` or `VALKEY` magic in the preamble.
- **`AOF_WAIT_REWRITE` state**: replicas enabling AOF during a full sync sit here until the rewrite completes - prevents a partial AOF from being written while the dataset is still loading.

Configs all Redis-baseline: `appendonly`, `appendfsync`, `aof-use-rdb-preamble`, `auto-aof-rewrite-percentage`, `auto-aof-rewrite-min-size`.

## Replication (`src/replication.c`)

Standard PSYNC / partial + full resync / dual replication IDs / `replicationFeedReplicas` / `syncWithPrimary` handshake - agent-knowable from Redis. Valkey-specific:

- **Dual-channel full resync** - see below. The meaty divergence.
- **Terminology flip**: source uses `primary`/`replica` as primary names; `master`/`slave` are aliases. Grepping `master_` mostly hits INFO fields (kept for client compatibility), config aliases, and a few error-string constants. New code and symbols use `primary_*`/`replica_*`.
- **`REDIRECT` during coordinated failover**: writes during `FAILOVER_IN_PROGRESS` get `-REDIRECT host:port` rather than being rejected - see `networking.md`.

## Dual-channel replication

Grep `dualChannel` in `src/replication.c`. Full resync uses two TCP connections so the replica buffers streaming writes locally instead of the primary buffering per-replica.

### Protocol

1. Replica advertises capability via `REPLCONF capa dual-channel` on the main connection.
2. `PSYNC` on the main channel; if a full resync is needed and capa was advertised, primary replies `+DUALCHANNELSYNC` instead of starting RDB. (Result code `PSYNC_FULLRESYNC_DUAL_CHANNEL = 6`.)
3. Replica opens a second connection (RDB channel), sends `REPLCONF set-rdb-client-id <cid>` on the **main** channel to link the two.
4. RDB channel: AUTH (if configured), `REPLCONF ip-address`, then primary sends `$ENDOFF <offset>` - the replication offset at which the RDB snapshot ends.
5. Primary attaches the main channel to the replication backlog starting at that offset, starts streaming writes immediately, in parallel with the child sending RDB on the RDB channel.
6. Replica buffers main-channel bytes in `server.pending_repl_data` (linked list of `replDataBufBlock`) while loading RDB.
7. After RDB load, replica closes the RDB channel, sends `PSYNC <replid> <endoff>`, gets `+CONTINUE`, and drains `pending_repl_data` via `streamReplDataBufToDb()` before normal steady state.

### RDB-channel state machine (on the replica)

Grep `REPL_DUAL_CHANNEL_`:

```
SEND_HANDSHAKE → RECEIVE_AUTH_REPLY → RECEIVE_REPLCONF_REPLY → RECEIVE_ENDOFF → RDB_LOAD → RDB_LOADED
```

Handlers: `dualChannelFullSyncWithPrimary` drives the state machine. `dualChannelSyncSuccess` runs on RDB-done (streams `pending_repl_data`, calls `replicationResurrectProvisionalPrimary`, `replicationSteadyStateInit`, `replicationSendAck`).

### Back-pressure

If `pending_repl_data` exceeds `client-output-buffer-limit replica` hard limit, the replica stops reading the main channel. The primary's own output buffer for that replica then grows - bounded by the same COB limits. Net effect: overall memory matches single-channel, but shifted so the replica can apply back-pressure.

### Fallback paths

- Primary without dual-channel support ignores `capa` and does single-channel full resync.
- RDB-channel connection failure → replica falls back to single-channel sync.
- Partial resync is single-channel; dual-channel only kicks in on full resync.

### Config

- `dual-channel-replication-enabled` (default `no`, on the replica).
- Local buffer block size derived from `repl-backlog-size` (max block ≈ backlog / 16).
