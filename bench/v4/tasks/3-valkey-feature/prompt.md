We want to reduce primary load in our Valkey deployment. Right now every replica syncs directly from the primary, which becomes a bottleneck when we have 8+ replicas.

We need a way for replicas to sync from other replicas instead of directly from the primary (chained/cascading replication). Valkey already supports REPLICAOF to point at any node, but we want a smarter approach:

1. A new config directive `replica-source-priority` that controls whether a replica prefers to sync from another replica or from the primary. Values: `primary-only` (current behavior), `prefer-replica` (try replica first, fall back to primary), `auto` (let the server decide based on primary load).

2. When `prefer-replica` is set, the replica should pick the most up-to-date sibling replica (closest replication offset) to sync from.

3. Document your design decisions in `DESIGN.md` - explain the trade-offs, failure scenarios, and how this interacts with existing replication (PSYNC, partial resync, failover).

4. Implement the config directive and the replica selection logic. The code must compile.

The source code is in this directory (src/, deps/, Makefile).
