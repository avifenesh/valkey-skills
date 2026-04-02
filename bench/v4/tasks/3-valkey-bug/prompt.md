# Bug Report: Two Critical Issues in Modified Valkey Build

## Environment
- Valkey cluster mode, 3 primaries + 3 replicas
- AOF persistence enabled (appendonly yes)
- Built from source in this directory

## Issue 1: Key Duplication After Server Restart

After a server restart (or `DEBUG LOADAOF`), we observe:
- `KEYS *` returns duplicate key names that shouldn't exist
- Some keys appear to be in the wrong hash slot
- Replication to replicas fails with errors about duplicate keys
- If the server saves the corrupted state and restarts again, it may crash

This only occurs when AOF is enabled with cluster mode and MULTI/EXEC transactions contain keys that hash to different slots.

## Issue 2: Split-Brain After Network Partition

When a primary node is disconnected from the network and then reconnected after a failover occurs:
- Two nodes claim to be master of the same slot range
- Both have the same configEpoch value
- The cluster stays in this split-brain state indefinitely
- The epoch collision between the old and new primary is never resolved

## Notes
- Both bugs are in the C source code in this directory
- A known-good Valkey 9.0.3 does not have either issue
- Each fix is small but hard to find
- The source tree has ~200 files
- There are exactly 2 bugs to find and fix

Please find and fix both bugs. The code must compile after your fixes.
