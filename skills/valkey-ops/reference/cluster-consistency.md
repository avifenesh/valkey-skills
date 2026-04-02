# Cluster Consistency Guarantees

Use when evaluating Valkey Cluster write safety or deciding between consistency and availability trade-offs.

Standard Redis Cluster consistency model applies - asynchronous replication, eventual consistency, write loss on primary crash before replication. See Redis Cluster docs for full details.

## Valkey Write Safety Mechanisms (same as Redis)

- `WAIT <numreplicas> <timeout>` - synchronous replication confirmation per command
- `min-replicas-to-write 1` + `min-replicas-max-lag 10` - stops writes when isolated
- `cluster-require-full-coverage yes` (default) - stops writes when any slot uncovered
- `cluster-allow-reads-when-down no` (default) - stops reads when cluster FAIL

## Valkey-Specific: Minority Partition Bound

The isolated primary stops accepting writes after `cluster-node-timeout` when it can no longer reach the majority of primaries. Default 15 seconds provides an automatic data-loss bound without requiring `min-replicas-to-write`.

## Recommendations by Use Case

| Use Case | Key Settings |
|----------|-------------|
| Cache | `cluster-require-full-coverage no`, `cluster-allow-reads-when-down yes` |
| Session store | `cluster-require-full-coverage yes`, `min-replicas-to-write 1` |
| Critical data | All of the above + `WAIT 1 5000` per write |
