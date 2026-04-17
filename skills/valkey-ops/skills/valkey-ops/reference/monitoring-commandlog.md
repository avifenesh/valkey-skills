# COMMANDLOG

Use when working with Valkey's unified slow/large-request/large-reply log. SLOWLOG works as an alias for the `slow` type only.

## Three logs in one command family

| Type | Tracks | Threshold unit |
|------|-------|----------------|
| `slow` | Command execution time | microseconds |
| `large-request` | Inbound argv bytes | bytes |
| `large-reply` | Outbound reply bytes | bytes |

Each has its own threshold, max-len, and entry-ID counter. Internal constants: `COMMANDLOG_TYPE_SLOW = 0`, `COMMANDLOG_TYPE_LARGE_REQUEST = 1`, `COMMANDLOG_TYPE_LARGE_REPLY = 2`.

## Config

| Parameter | Default | Redis alias (for `slow` only) |
|-----------|---------|-------------------------------|
| `commandlog-execution-slower-than` | `10000` µs | `slowlog-log-slower-than` |
| `commandlog-slow-execution-max-len` | `128` | `slowlog-max-len` |
| `commandlog-request-larger-than` | `1048576` B | - |
| `commandlog-large-request-max-len` | `128` | - |
| `commandlog-reply-larger-than` | `1048576` B | - |
| `commandlog-large-reply-max-len` | `128` | - |

`-1` threshold or `0` max-len disables that type.

## Commands

```
COMMANDLOG GET <count> <type>          # count=-1 for all; type = slow | large-request | large-reply
COMMANDLOG LEN <type>
COMMANDLOG RESET <type>
SLOWLOG GET/LEN/RESET [count]          # alias - operates on the slow type only
```

Entry shape: `[id, timestamp, value, arguments[], peerid, cname]`. `value` is duration (slow) or bytes (large-*). Arguments are truncated to `COMMANDLOG_ENTRY_MAX_ARGC = 32` slots, each capped at `COMMANDLOG_ENTRY_MAX_STRING = 128` bytes - excess becomes `... (N more)`.

In cluster mode, all three subcommands carry `REQUEST_POLICY:ALL_NODES`; `LEN` additionally has `RESPONSE_POLICY:AGG_SUM` so cluster-aware clients fan-out and merge. Aggregated IDs are not globally unique.

## Argv edge cases worth knowing

- **Rewritten commands**: if the server rewrote `c->argv` (e.g., `SET ... EX` internally), the entry captures `c->original_argv` - what the client sent, not what executed.
- **Script execution**: `value` comes from the executing client's counters, `peerid`/`cname` come from `scriptGetCaller()`. Lua entries show the caller's identity, not the script engine's.
- **Redaction**: `redactClientCommandArgument` sets bits in `c->redact_arg_bitmap` (uint32, bit 0 = "all beyond 32"); commandlog applies the bitmap lazily at log time, emitting `shared.redacted` for masked slots. Old-style eager `original_argv` rewrites on redaction are gone.
- **Command-level skip**: commands with `CMD_SKIP_COMMANDLOG` (AUTH, HELLO, etc.) don't enter any of the three logs.

## Exporter reality

`oliver006/redis_exporter` exposes only the slow log today (as `redis_slowlog_length`, `redis_slowlog_last_id`), because it calls `SLOWLOG GET` under the hood. For `large-request` / `large-reply` use a monitoring agent that calls `COMMANDLOG LEN large-request` / `large-reply` directly. Expect this to move into the exporter at some point - check its release notes before writing custom scrapers.

## Investigation workflow

Tighten thresholds during an incident, restore after:

```
CONFIG SET commandlog-execution-slower-than 1000       # 1ms
CONFIG SET commandlog-reply-larger-than 65536          # 64KB
CONFIG SET commandlog-slow-execution-max-len 1024
```

When done:

```
CONFIG SET commandlog-execution-slower-than 10000
CONFIG SET commandlog-reply-larger-than 1048576
CONFIG SET commandlog-slow-execution-max-len 128
```
