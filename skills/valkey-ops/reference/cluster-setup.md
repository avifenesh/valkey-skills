# Cluster Setup

Use when deploying a new Valkey Cluster or understanding hash slot mechanics.

Standard Redis Cluster setup applies - 16384 hash slots, `CLUSTER MEET`, hash tags, MOVED/ASK redirects. See Redis Cluster docs for full details.

## Valkey-Specific Names

- Binary: `valkey-server`, CLI: `valkey-cli`
- `cluster-config-file nodes.conf` (auto-managed, do not edit)
- `masterauth`/`primaryauth` both accepted for inter-node auth

## Cluster Creation

```bash
valkey-cli --cluster create \
  192.168.1.10:7000 192.168.1.11:7001 192.168.1.12:7002 \
  192.168.1.10:7003 192.168.1.11:7004 192.168.1.12:7005 \
  --cluster-replicas 1 -a "cluster-password"

valkey-cli -c -p 7000 CLUSTER INFO
valkey-cli --cluster check 192.168.1.10:7000 -a "cluster-password"
```

## Key Config Parameters

| Parameter | Default | Note |
|-----------|---------|------|
| `cluster-enabled` | no | Must be yes |
| `cluster-node-timeout` | 15000ms | Affects failover timing |
| `cluster-require-full-coverage` | yes | Stops all writes if any slot uncovered |
| `cluster-port` | 0 (auto) | Bus port = client port + 10000 |

## Minimum Viable Topology

3 primary nodes (1 shard each). Production: 6 nodes (3P+3R). Both client port and cluster bus port (client port + 10000) must be reachable between all nodes.
