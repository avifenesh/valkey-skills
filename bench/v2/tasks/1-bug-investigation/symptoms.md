# Bug Report: Split-Brain After Network Partition

## Environment

- Valkey cluster: 6 nodes (3 primaries, 3 replicas)
- Version: 9.0.3 (modified build - the bug is in the server code)
- Mode: cluster-enabled, appendonly, node-timeout 5000ms
- Source code is in src/ and deps/, builds via Makefile

## Steps to Reproduce

1. Start 6-node cluster with `docker compose up --build`
2. Create cluster with 3 primaries and 3 replicas
3. Write data to the cluster
4. Disconnect one primary node from the network (simulating network partition)
5. Wait 15 seconds (enough for failover timeout)
6. Reconnect the partitioned node
7. Wait 10 seconds for gossip convergence

## Observed Behavior

After the partition heals and the previously disconnected primary rejoins:

- `CLUSTER NODES` shows TWO nodes with `master` flag claiming the SAME slot range
- Both nodes have the SAME `configEpoch` value
- The old primary still believes it owns its slots
- The new primary (promoted during partition) also claims the same slots
- The epoch collision between the two primaries is never resolved
- The cluster stays in this split-brain state indefinitely

## Expected Behavior

After a failover and partition recovery, the epoch collision resolution should ensure one node gets a higher configEpoch and wins ownership. The other should step down to replica.

## Notes

- The failover itself completes successfully (the replica IS promoted)
- The problem occurs during the post-failover convergence
- Something prevents the cluster from resolving the epoch collision between the old and new primary
- The bug is in the C source code in this directory

## Investigation

Run `./reproduce.sh` to see this happen. Then investigate the source code in `src/` to find the root cause.
