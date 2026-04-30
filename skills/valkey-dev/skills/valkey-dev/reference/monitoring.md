# Monitoring (CommandLog, Latency, Tracking)

## Commandlog (`src/commandlog.c`, `src/commandlog.h`)

`SLOWLOG` is still accessible but is now one of three logs under unified `COMMANDLOG` (types: `slow`, `large-request`, `large-reply`). State at `server.commandlog[]`; enums `COMMANDLOG_TYPE_SLOW`, `COMMANDLOG_TYPE_LARGE_REQUEST`, `COMMANDLOG_TYPE_LARGE_REPLY` in `server.h`. Each type has its own threshold, max-len, and ID counter.

Renamed configs (old names kept as aliases):

- `commandlog-execution-slower-than` (alias: `slowlog-log-slower-than`)
- `commandlog-slow-execution-max-len` (alias: `slowlog-max-len`)

`-1` threshold or `0` max-len disables that log.

- `commandlogPushCurrentCommand` runs after every command and pushes into all three logs when thresholds cross. `CMD_SKIP_COMMANDLOG` on a command's flags hides the entire entry (AUTH and similar).
- Per-argument redaction: `redactClientCommandArgument(c, argc)` sets bits in `c->redact_arg_bitmap` (bits 1-31 for indices < 32; bit 0 is an "everything from here on" sentinel for larger indices). Applied lazily at log time. The old eager `original_argv`-rewrite-on-redact path is gone.
- Script execution: value fields come from the executing client, but `peerid` / `cname` come from `scriptGetCaller()` - entries show the caller's identity, not the script's.
- Rewritten argv (e.g., SET-with-EX rewritten to SETEX) is captured via `c->original_argv`. Separate mechanism from redaction.
- Truncation: `COMMANDLOG_ENTRY_MAX_ARGC = 32`, `COMMANDLOG_ENTRY_MAX_STRING = 128` bytes.
- Cluster aggregation: `COMMANDLOG GET`/`LEN`/`RESET` carry `REQUEST_POLICY:ALL_NODES`; `LEN` also carries `RESPONSE_POLICY:AGG_SUM`. Aggregated IDs aren't globally unique.

## Latency Monitor (`src/latency.c`)

`LATENCY DOCTOR` references `COMMANDLOG` (not just `SLOWLOG`) when suggesting thresholds - its output names which of the three log types to query.

## Client Tracking (`src/tracking.c`)

- Invalidation channel is `__redis__:invalidate`, NOT `__valkey__:*`. Preserved for client compatibility. See `TrackingChannelName`.
- `tracking_total_keys` bounds against `tracking-table-max-keys` - spurious invalidations start when this hits the limit.
