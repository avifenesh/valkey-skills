Use when deploying Valkey on Kubernetes with raw StatefulSets, configuring PVCs, pod scheduling, health probes, resource sizing, or Pod Disruption Budgets.

# StatefulSet Patterns for Valkey

## Contents

- When to Use Raw StatefulSets (line 19)
- Persistent Volume Claims (line 28)
- Pod Anti-Affinity (line 60)
- Health Probes (line 116)
- Resource Sizing (line 182)
- Pod Disruption Budget (line 216)
- Complete StatefulSet Example (line 239)
- Common StatefulSet Gotchas for Valkey (line 329)
- See Also (line 350)

---

## When to Use Raw StatefulSets

Raw StatefulSets give full control but require more configuration. Use when:

- Helm charts or operators do not support your topology
- You need custom sidecar containers or init containers
- You want to integrate with existing deployment tooling
- You need fine-grained control over update strategy

## Persistent Volume Claims

StatefulSet `volumeClaimTemplates` create one PVC per pod. These PVCs survive pod restarts and rescheduling.

```yaml
volumeClaimTemplates:
  - metadata:
      name: valkey-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 10Gi
```

### PVC Sizing Guidelines

| Workload | Size recommendation |
|----------|-------------------|
| Cache-only | 2x maxmemory (for RDB snapshots) |
| Persistent store (RDB) | 3x dataset size (snapshot + temp file) |
| Persistent store (AOF) | 3x dataset size (base + incremental + rewrite temp) |
| AOF + RDB (hybrid) | 4x dataset size |

### PVC Lifecycle

- PVCs created by StatefulSets are NOT deleted when the StatefulSet or Helm release is deleted
- Manual cleanup required: `kubectl delete pvc -l app=valkey`
- This is a safety feature - prevents accidental data loss
- When scaling down, PVCs for removed pods persist and reattach if scaled back up

## Pod Anti-Affinity

Spread Valkey pods across nodes to survive node failures.

### Soft Anti-Affinity (Preferred)

Schedules on different nodes when possible, but allows co-location if no other nodes are available:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["valkey"]
          topologyKey: kubernetes.io/hostname
```

### Hard Anti-Affinity (Required)

Strictly prevents co-location. Pods stay pending if no separate node is available:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values: ["valkey"]
        topologyKey: kubernetes.io/hostname
```

### Zone Spread

For multi-AZ clusters, spread across availability zones:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["valkey"]
          topologyKey: topology.kubernetes.io/zone
```

## Health Probes

### Liveness Probe

Restarts the pod if Valkey becomes unresponsive:

```yaml
livenessProbe:
  exec:
    command: ["valkey-cli", "-a", "$PASSWORD", "ping"]
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

Set `initialDelaySeconds` high enough to allow AOF/RDB loading on restart. For large datasets, 60-120 seconds may be needed.

### Readiness Probe

Removes the pod from service endpoints when not ready to serve traffic:

```yaml
readinessProbe:
  exec:
    command: ["valkey-cli", "-a", "$PASSWORD", "ping"]
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
```

### Startup Probe

For large datasets that take a long time to load, use a startup probe to avoid liveness probe kills during startup:

```yaml
startupProbe:
  exec:
    command: ["valkey-cli", "-a", "$PASSWORD", "ping"]
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30    # 30 * 10s = 5 minutes to start
```

The startup probe runs first. Liveness and readiness probes only start after the startup probe succeeds.

### Probe for Replicas

For replica pods, check replication status instead of just PING:

```yaml
readinessProbe:
  exec:
    command:
      - sh
      - -c
      - |
        valkey-cli -a "$PASSWORD" INFO replication | grep -q "master_link_status:up"
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 5
  failureThreshold: 3
```

## Resource Sizing

```yaml
resources:
  requests:
    memory: 2Gi         # match maxmemory setting
    cpu: 500m            # 0.5 core baseline
  limits:
    memory: 4Gi          # 2x requests for fork headroom
    # No CPU limit - avoids throttling
```

### Memory Sizing Rules

1. **Requests** = `maxmemory` + ~200MB overhead (buffers, connections, replication backlog)
2. **Limits** = 2x requests to accommodate BGSAVE/BGREWRITEAOF fork (copy-on-write memory)
3. If using `appendfsync always`, reduce the fork multiplier to 1.5x (less COW churn)

### CPU Sizing Rules

1. **Requests** = 500m for moderate workloads, 1000m for high throughput
2. **Limits** = avoid setting CPU limits for latency-sensitive workloads. Kubernetes CPU throttling (CFS quota) causes latency spikes
3. If you must set CPU limits, set them at 4x requests minimum

### I/O Thread Considerations

When using Valkey 8.0+ I/O threads (`io-threads`), ensure CPU requests account for the thread count:

```
cpu requests >= io-threads * 250m
```

For example, with `io-threads 4`, request at least 1000m CPU.

## Pod Disruption Budget

Limits how many pods Kubernetes can evict simultaneously during voluntary disruptions (node drains, cluster upgrades):

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: valkey
```

### PDB Rules

- **Never set `maxUnavailable: 0`** - this blocks node drains entirely, stalling cluster operations
- For replication setups: `maxUnavailable: 1` ensures at most one pod is disrupted at a time
- For cluster setups: `maxUnavailable: 1` per shard is ideal, but a global `maxUnavailable: 1` works for small clusters
- Alternative: use `minAvailable` instead: `minAvailable: 2` for a 3-pod replication set

## Complete StatefulSet Example

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: valkey
spec:
  serviceName: valkey
  replicas: 3
  selector:
    matchLabels:
      app: valkey
  template:
    metadata:
      labels:
        app: valkey
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        fsGroup: 999
      affinity:        # see Pod Anti-Affinity section above
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: { app: valkey }
                topologyKey: kubernetes.io/hostname
      containers:
        - name: valkey
          image: valkey/valkey:9
          ports:
            - containerPort: 6379
              name: client
          command: ["valkey-server", "/etc/valkey/valkey.conf"]
          resources:
            requests:
              memory: 2Gi
              cpu: 500m
            limits:
              memory: 4Gi
          startupProbe:
            exec:
              command: ["valkey-cli", "ping"]
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            exec:
              command: ["valkey-cli", "ping"]
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command: ["valkey-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
          volumeMounts:
            - name: valkey-data
              mountPath: /data
            - name: config
              mountPath: /etc/valkey
      volumes:
        - name: config
          configMap:
            name: valkey-config
  volumeClaimTemplates:
    - metadata:
        name: valkey-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 10Gi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: valkey
```

## Common StatefulSet Gotchas for Valkey

1. **OOMKilled during persistence** - fork can double memory. Set container
   memory limit > 2x `maxmemory`, or use AOF-only with `save ""`.
2. **Headless service must use publishNotReadyAddresses** - without this,
   DNS records are removed during pod restart, breaking replication discovery.
3. **PVC stuck in Pending** - check `storageClassName`, `volumeBindingMode:
   WaitForFirstConsumer`, and zone capacity.
4. **Cluster gossip port** - port 16379 must be allowed in Network Policies.
5. **Split-brain with Sentinel** - use `min-replicas-to-write` to mitigate.
6. **SecurityContext UID conflicts** - official chart uses UID 1000, Bitnami
   uses 1001. Switching charts requires PVC permission fixes.
7. **Termination grace period** - increase for large datasets (default 30s
   may not suffice for RDB saves).
8. **Volume expansion** - requires `allowVolumeExpansion: true` on StorageClass.
9. **Client redirection in cluster mode** - clients must handle MOVED/ASK.
10. **DNS propagation delay** - after pod restart, DNS may take seconds to
    update. Use retry parameters in startup scripts.

---
