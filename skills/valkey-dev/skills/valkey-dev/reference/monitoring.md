# Monitoring (CommandLog, Latency, Tracking, Debug)

Production observability surface.

## Commandlog (`src/commandlog.c`, `src/commandlog.h`)

Redis's slowlog is still accessible via `SLOWLOG` but is now one of three logs under the unified `COMMANDLOG` command.

### The three logs

```
COMMANDLOG GET <count> <type>    -- type: slow | large-request | large-reply
COMMANDLOG LEN <type>
COMMANDLOG RESET <type>
```

Each has its own threshold, max-len, and entry ID counter (`COMMANDLOG_TYPE_SLOW`, `COMMANDLOG_TYPE_LARGE_REQUEST`, `COMMANDLOG_TYPE_LARGE_REPLY` in `server.h`; state at `server.commandlog[]`).

### Configs

| Directive | Alias | Default | Unit |
|-----------|-------|---------|------|
| `commandlog-execution-slower-than` | `slowlog-log-slower-than` | 10000 | µs |
| `commandlog-request-larger-than` | - | 1048576 | bytes |
| `commandlog-reply-larger-than` | - | 1048576 | bytes |
| `commandlog-slow-execution-max-len` | `slowlog-max-len` | 128 | entries |
| `commandlog-large-request-max-len` | - | 128 | entries |
| `commandlog-large-reply-max-len` | - | 128 | entries |

`-1` threshold or `0` max-len disables that log.

### Non-obvious behaviors

- `commandlogPushCurrentCommand` is called after *every* command and pushes into all three logs if thresholds are crossed. Add `CMD_SKIP_COMMANDLOG` to a command's flags to hide the entire entry (used for AUTH and similar).
- **Per-argument redaction**: to hide specific argv slots (not the whole entry) call `redactClientCommandArgument(c, argc)` - it sets bits in `c->redact_arg_bitmap` (bits 1-31 for indices < 32; bit 0 as a "everything from here on" sentinel for larger indices). Applied lazily by the commandlog at log time. The previous eager `original_argv`-rewrite-on-redact path is gone.
- **Script execution**: value fields come from the executing client's counters, but `peerid`/`cname` come from `scriptGetCaller()` - log entries from Lua show the *caller's* identity.
- **Rewritten argv**: if a command rewrote `c->argv` (e.g., SET with EX rewrites to SETEX), the log captures `c->original_argv` (what the client sent, not what executed). Separate mechanism from argument redaction above.
- Entry value interpretation: slow = microseconds (wall clock, `ustime()` around `call()`); large-* = bytes from `net_input_bytes_curr_cmd` / `net_output_bytes_curr_cmd`.
- **Truncation**: `COMMANDLOG_ENTRY_MAX_ARGC = 32`, `COMMANDLOG_ENTRY_MAX_STRING = 128` bytes. Excess replaced with `... (N more arguments)` / `... (N more bytes)`.
- **Cluster aggregation**: `COMMANDLOG GET`/`LEN`/`RESET` carry `REQUEST_POLICY:ALL_NODES` (and `LEN` also `RESPONSE_POLICY:AGG_SUM`) so cluster-aware clients dispatch and merge. Aggregated IDs aren't globally unique.

## Latency Monitor (`src/latency.c`)

Per-event 160-sample circular buffers, `latency-monitor-threshold` config, `LATENCY LATEST/HISTORY/GRAPH/DOCTOR/RESET/HISTOGRAM`. Standard instrumented events (`command`, `fast-command`, `fork`, `expire-cycle`, `active-defrag-cycle`, `aof-fsync-always`, `aof-write-pending-fsync`, etc.) unchanged.

`LATENCY DOCTOR` references `COMMANDLOG` (not just `SLOWLOG`) when suggesting thresholds - its output tells you *which* of the three log types to query.

## Client Tracking (`src/tracking.c`)

Standard `CLIENT TRACKING`: default (per-key) vs BCAST (prefix), OPTIN / OPTOUT / NOLOOP, RESP3 push vs RESP2 pub/sub redirect.

**Grep hazard**: the invalidation channel is `__redis__:invalidate`, not `__valkey__:*`. Preserved for client compatibility. See `TrackingChannelName` in `src/tracking.c`.

INFO fields: `tracking_total_keys`, `tracking_total_items`, `tracking_total_prefixes`. `tracking_total_keys` is what bounds against `tracking-table-max-keys` (spurious invalidations start when this hits the limit).

## DEBUG (`src/debug.c`)

Standard `DEBUG` subcommand catalog, crash reporter via `sigsegvHandler`, software watchdog via SIGALRM. No Valkey-specific changes at this layer.
