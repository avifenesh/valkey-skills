# Cluster Failover

Use when you need to understand how Valkey detects node failures, how replicas get elected to replace a failed primary, or how manual failover works.

Standard two-phase failure detection (PFAIL -> FAIL via gossip quorum), replica election with vote granting, and manual failover (standard/FORCE/TAKEOVER). See Redis Cluster failover docs for the base algorithm.

## Valkey-Specific Changes

- **Coordinated failover timing**: Best-ranked replica (rank 0) with rank-0 primary starts election immediately with zero delay when all replicas in the shard agree the primary has failed. This avoids unnecessary delays in the common case.
- **Ranked elections with failed-primary rank**: `clusterGetFailedPrimaryRank()` adds delay based on the failed primary's rank across shards, preventing concurrent elections across multiple shards from interfering with each other.
- **Configurable manual failover timeout**: `server.cluster_mf_timeout` (default 5000ms, configurable since Valkey 8.1).

Source: `src/cluster_legacy.c`
