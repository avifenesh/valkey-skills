# Benchmark Tasks

## Task 1: Cache Layer with GLIDE

Write a cache-aside layer for a Node.js CRUD API using Valkey GLIDE as the client. The API manages user profiles (create, read, update, delete). Requirements:
- Use Valkey GLIDE (not ioredis or node-redis)
- Cache-aside pattern: read from cache first, fallback to DB, populate cache on miss
- Cache invalidation on write/update/delete
- TTL-based expiration (configurable per entity type)
- Handle connection failures gracefully (app works without cache)
- Use GLIDE's cluster mode configuration
- Include TypeScript types

Output: the cache layer module code and a usage example showing integration with an Express route handler.

## Task 2: Valkey Cluster on Kubernetes with Search

Write Kubernetes manifests to deploy a 3-primary, 3-replica Valkey cluster with the valkey-search module enabled. Requirements:
- StatefulSet-based deployment
- Persistent volume claims for data
- ConfigMap for valkey.conf with search module loaded
- Service for client connections
- Resource limits and readiness probes
- TLS enabled between nodes
- The cluster should auto-initialize on first boot
- Include a test job that creates a search index and runs a query to verify the deployment

Output: all YAML manifests and a brief deployment guide.

## Task 3: Valkey Server Bug Investigation

You are investigating a production issue in a 6-node Valkey cluster (3 primaries, 3 replicas) running 9.0.3. After a network partition heals, two nodes both claim to be primary for the same slots. CLUSTER INFO shows cluster_state:ok but CLUSTER NODES shows overlapping slot ownership. The currentEpoch on the two conflicting nodes is the same value - it appears the epoch did not advance during the failover that happened during the partition.

Walk through the Valkey source code to investigate:
- Where does the currentEpoch get incremented during failover?
- What are the conditions that must be met for the increment to happen?
- What could prevent the epoch from advancing (causing both nodes to believe they own the same slots)?
- What specific functions and source files are involved?

Output: a root cause analysis tracing through the actual C source code, identifying the specific code path where the epoch should have been incremented, and what condition was not met.

## Judging Criteria

Each response is scored 1-10 on:
1. **Correctness** - Does the code work? Are APIs used correctly? Are Valkey-specific features handled properly?
2. **Completeness** - Does it cover all requirements? Missing pieces?
3. **Valkey-awareness** - Does it use Valkey-specific knowledge (not just Redis patterns)? Correct API names? Valkey 9.x features?
4. **Production quality** - Error handling, edge cases, security considerations?
5. **Specificity** - Actual function names, file paths, struct fields vs generic descriptions?
