# Bug Report: Key Duplication After Server Restart

## Environment
- Valkey cluster mode, 3 primaries + 3 replicas
- AOF persistence enabled (appendonly yes)
- Built from source in this directory

## Observed Behavior
After a server restart (or `DEBUG LOADAOF`), we observe:
- `KEYS *` returns duplicate key names that shouldn't exist
- Some keys appear to be in the wrong hash slot
- Replication to replicas fails with errors about duplicate keys
- If the server saves the corrupted state and restarts again, it may crash

## Reproduction
The issue only occurs when:
1. AOF is enabled with cluster mode
2. MULTI/EXEC transactions contain keys that hash to different slots
3. The server restarts and replays the AOF

## Steps to Reproduce
1. Build and start a cluster: `docker compose up -d --build`
2. Write some data using MULTI/EXEC with keys in different slots
3. Restart the server (or run `DEBUG LOADAOF`)
4. Run `KEYS *` and observe duplicate keys

## Notes
- The bug is in the C source code in this directory
- A known-good Valkey 9.0.3 does not have this issue
- The fix is small (a few lines) but hard to find
- The source tree has ~200 files

Please find and fix the bug. The code must compile after your fix.
