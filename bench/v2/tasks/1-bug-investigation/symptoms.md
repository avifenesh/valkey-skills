# Bug Report: Split-Brain After Network Partition

## Environment

- Valkey cluster: 6 nodes (3 primaries, 3 replicas)
- Version: 9.0.3 (modified build - the bug is in the server code)
- Mode: cluster-enabled, appendonly, node-timeout 5000ms

## Steps to Reproduce

1. Start 6-node cluster with `docker compose up`
2. Create cluster with 3 primaries and 3 replicas
3. Write data to the cluster
4. Disconnect one primary node from the network (simulating network partition)
5. Wait 15 seconds (enough for failover timeout)
6. Reconnect the partitioned node
7. Wait 10 seconds for gossip convergence

## Observed Behavior

After the partition heals and the previously disconnected primary rejoins:

- `CLUSTER NODES` shows TWO nodes with `master` flag claiming the SAME slot range
- `CLUSTER INFO` shows `cluster_current_epoch` is the SAME value on both conflicting nodes
- The old primary (that was partitioned) still believes it owns its slots
- The new primary (that was promoted during the partition) also claims the same slots
- Data written during the partition to the new primary may conflict with the old primary's data

## Expected Behavior

After a failover, the new primary should have a HIGHER configEpoch than the old primary. When the old primary rejoins, it should see the higher epoch and step down to replica, resolving the slot ownership conflict.

## Impact

- Data loss risk: writes to either "primary" may be lost
- Client confusion: different clients may connect to different primaries for the same slots
- No automatic resolution: the cluster stays in this split-brain state

## Investigation

Run `./reproduce.sh` to see this happen. The output shows the CLUSTER NODES before and after the partition.

Your task: find the root cause in the Valkey server source code and explain what went wrong.
