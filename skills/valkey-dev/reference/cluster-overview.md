# Cluster Subsystem Overview

Use when you need to understand how Valkey distributes data across nodes, how the cluster bus works, or how client requests get routed.

Standard 16,384-slot hash cluster with gossip protocol, MOVED/ASK redirects, full-mesh bus on port+10000. See Redis Cluster docs for the base model.

## Valkey-Specific Changes

- **Atomic slot migration**: `slot_migration_jobs` list on `clusterState` enables atomic slot migration in Valkey 9.0. See [cluster-slot-migration.md](cluster-slot-migration.md) for details.
- **Multi-database cluster**: Cluster mode supports multiple databases (not just DB 0). `getKVStoreIndexForKey()` routes by CRC16 slot; `selectDb()` works in cluster mode.
- **Shard tracking**: `clusterState.shards` dict maps `shard_id -> list(clusterNode)` for shard-level operations.

Source: `src/cluster.c`, `src/cluster_legacy.c`, `src/cluster.h`, `src/cluster_legacy.h`
