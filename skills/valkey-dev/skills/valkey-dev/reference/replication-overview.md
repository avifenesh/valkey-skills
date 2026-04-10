# Replication Overview

Use when you need to understand how Valkey replicates data from a primary to replicas.

Standard PSYNC protocol with full/partial resync, replication backlog (linked list of `replBufBlock` nodes with radix tree index), dual replication IDs for failover continuity, and write propagation via `replicationFeedReplicas()`. Replica handshake state machine in `syncWithPrimary()`.

## Valkey-Specific Changes

- **Dual-channel replication**: Full sync can use a dedicated channel. See [replication-dual-channel.md](replication-dual-channel.md) for details.
- **Terminology**: `master` -> `primary`, `slave` -> `replica` throughout the codebase and protocol.

Source: `src/replication.c`
