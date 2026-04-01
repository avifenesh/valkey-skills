Use when you need a complete, copy-paste StatefulSet manifest for Valkey on Kubernetes, or when troubleshooting common StatefulSet issues.

# StatefulSet for Valkey - Complete Example and Gotchas

## Contents

- Complete StatefulSet Example (line 13)
- Common StatefulSet Gotchas for Valkey (line 103)
- See Also (line 124)

---

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
      affinity:        # see statefulset-config.md Pod Anti-Affinity section
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

## See Also

- [statefulset-config](statefulset-config.md) - PVCs, anti-affinity, probes, resource sizing, PDB
- [helm](helm.md) - Helm chart deployment
- [operators-overview](operators-overview.md) - Kubernetes operators
