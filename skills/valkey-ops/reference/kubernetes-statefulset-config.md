# StatefulSet Patterns for Valkey - Configuration

Use when deploying Valkey on Kubernetes with raw StatefulSets - PVCs, pod scheduling, health probes, resource sizing, Pod Disruption Budgets.

Standard Kubernetes StatefulSet patterns apply. See Kubernetes docs for general StatefulSet guidance.

## Valkey-Specific Names

- Image: `valkey/valkey:9`
- Health probe command: `["valkey-cli", "ping"]` (not `redis-cli`)
- Security context UID: 999 (official image); Bitnami uses 1001
- Data mountPath: `/data`
- Config mountPath: `/etc/valkey`

## Resource Sizing (Valkey)

```yaml
resources:
  requests:
    memory: 2Gi     # match maxmemory
    cpu: 500m
  limits:
    memory: 4Gi     # 2x requests for fork COW headroom
    # no CPU limit - avoids CFS throttling latency spikes
```

When using `io-threads N`, set CPU requests >= N * 250m.

## Replica Readiness Probe

```yaml
readinessProbe:
  exec:
    command: ["sh", "-c", "valkey-cli -a $PASSWORD INFO replication | grep -q master_link_status:up"]
```

## PVC Sizing

| Workload | Size |
|----------|------|
| Cache-only | 2x maxmemory |
| RDB only | 3x dataset |
| AOF + RDB (hybrid) | 4x dataset |

PVCs created by StatefulSets are NOT deleted when the StatefulSet is deleted - manual cleanup required.
