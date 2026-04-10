# Replication Lag Diagnosis

Use when replicas fall behind the primary or replication breaks frequently.

Standard Redis replication lag diagnosis and resolution applies - check INFO replication, increase backlog, enable diskless sync, tune output buffer limits. See Redis docs for full details.

## Valkey-Specific Terminology

- `INFO replication` shows `role:slave` for replicas (legacy Redis term in output)
- Config uses `replica-*` params: `repl-backlog-size`, `replica-serve-stale-data`, `repl-diskless-sync`
- Both `masterauth` and `primaryauth` accepted

## Key Diagnosis Commands

```bash
valkey-cli INFO replication    # on primary: check slave offset vs master_repl_offset
valkey-cli INFO replication    # on replica: check master_link_status, master_last_io_seconds_ago
valkey-cli COMMANDLOG GET 10 slow   # check for slow commands on replica (not SLOWLOG)
```

## Common Resolutions

```bash
valkey-cli CONFIG SET repl-backlog-size 512mb   # default 10MB is too small
valkey-cli CONFIG SET repl-diskless-sync yes     # avoid disk I/O on full resync
valkey-cli CONFIG SET repl-timeout 120           # default 60s
valkey-cli CONFIG SET client-output-buffer-limit "replica 512mb 128mb 60"
```

## Warning: Persistence Off on Primary

If persistence is disabled on the primary and it restarts, all replicas sync with an empty dataset and lose their data. Enable persistence on primary or disable auto-restart.
