We built Valkey from the source code in this directory and hit two issues in production.

## Issue 1: Key Duplication After Server Restart

After a server restart (or `DEBUG LOADAOF`), we see:
- `KEYS *` returns duplicate key names that shouldn't exist
- Some keys appear to be in the wrong hash slot
- Replication to replicas fails with errors about duplicate keys
- If the server saves the corrupted state and restarts again, it crashes

This only happens with AOF enabled in cluster mode when MULTI/EXEC transactions contain keys that hash to different slots.

## Issue 2: Split-Brain After Network Partition

When a primary node is disconnected from the network and reconnected after a failover:
- Two nodes claim to be master of the same slot range
- Both have the same configEpoch value
- The cluster stays in this split-brain state indefinitely
- The epoch collision between the old and new primary is never resolved

## What we know

- Valkey 9.0.3 stock build does not have either issue
- There are 2 bugs causing this

Find and fix both. Compile the code when finished.
