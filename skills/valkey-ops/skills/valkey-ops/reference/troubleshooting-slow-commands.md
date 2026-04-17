# Slow-Command Investigation

Use when p99 spikes, clients time out, or throughput drops while CPU stays moderate. Redis playbook applies (`KEYS *` vs `SCAN`, `HGETALL` on huge hashes, unbounded `ZRANGEBYSCORE`, Lua scripts blocking the main thread, `SMEMBERS` on million-member sets) - this file is the Valkey-specific delta.

## COMMANDLOG replaces SLOWLOG - and splits the job

Valkey 8.1+ adds three logs in one command family. `SLOWLOG *` remains as an alias for the `slow` type only; the other two are net-new surfaces.

```sh
valkey-cli COMMANDLOG GET 25 slow            # > 10ms by default
valkey-cli COMMANDLOG GET 25 large-request   # > 1MB by default
valkey-cli COMMANDLOG GET 25 large-reply     # > 1MB by default
valkey-cli COMMANDLOG LEN <type>
valkey-cli COMMANDLOG RESET <type>
```

Why it matters: a client timing out on `HGETALL` against a large hash won't show in slow-log if the server side was fast - but the **reply** was megabytes. That's the `large-reply` log, and it's the signal that tells you the client's network or their own parser is the bottleneck, not the server.

In cluster mode, `COMMANDLOG GET/LEN/RESET` carry `REQUEST_POLICY:ALL_NODES` annotations, so a cluster-aware client fan-outs and merges automatically. Aggregated IDs aren't globally unique.

Tightening thresholds during investigation:

```
commandlog-execution-slower-than 1000     # 1ms - surface more
commandlog-slow-execution-max-len 512
commandlog-reply-larger-than 65536        # 64KB - catch medium replies
```

Restore defaults (10000 µs, 128, 1048576 B) after.

## Argv capture nuance

COMMANDLOG entries capture `c->original_argv` when the server rewrote the command (e.g., `SET ... EX` rewritten internally). Per-argument redaction is separate: `redactClientCommandArgument` sets bits in `c->redact_arg_bitmap` applied lazily at log time. Commands marked with `CMD_SKIP_COMMANDLOG` (AUTH, HELLO) never enter any of the three logs. Scripts: `peerid`/`cname` come from `scriptGetCaller()` so entries from Lua show the caller's identity, not the scripting engine's.

## Hot-key detection

`valkey-cli --hotkeys` needs `maxmemory-policy` set to one of the LFU variants; it internally calls `OBJECT FREQ`. `--bigkeys` and `--memkeys` ship in `valkey-cli` and work without LFU (same binary identity as `redis-cli`). For ad-hoc sampling, `MONITOR` still exists but adds per-command overhead - only run briefly, never leave on.

In cluster mode, a hot key lives on exactly one shard; `CLUSTER SLOT-STATS ORDERBY cpu-usec LIMIT 10 DESC` (with `cluster-slot-stats-enabled yes`) points directly at the slot and, via `CLUSTER NODES`, the shard owning it. That replaces the "run --hotkeys on every node and diff" workflow.

## Mitigation handles

- Disable dangerous commands via `rename-command KEYS ""` (valkey.conf only, not runtime).
- `UNLINK` instead of `DEL` for large keys - asynchronous via BIO (same as Redis, but all five lazyfree defaults are `yes` on Valkey so `DEL` already goes async unless you've disabled that).
- `CLIENT NO-EVICT on` on the exporter's connection so scraping doesn't churn the LRU.
- `io-threads > 1` helps I/O-bound workloads (many small commands) but doesn't parallelize command execution - a slow single command is still slow.
