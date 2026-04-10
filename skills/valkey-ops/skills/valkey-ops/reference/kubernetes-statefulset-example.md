# StatefulSet for Valkey - Complete Example and Gotchas

Use when you need a complete StatefulSet manifest for Valkey on Kubernetes, or when troubleshooting common StatefulSet issues.

Standard Kubernetes StatefulSet YAML applies. Use `valkey/valkey:9` as the image and `valkey-cli` for health probes.

## Minimal Complete Example

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: valkey
spec:
  serviceName: valkey
  replicas: 3
  selector:
    matchLabels: { app: valkey }
  template:
    metadata:
      labels: { app: valkey }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        fsGroup: 999
      containers:
        - name: valkey
          image: valkey/valkey:9
          command: ["valkey-server", "/etc/valkey/valkey.conf"]
          resources:
            requests: { memory: 2Gi, cpu: 500m }
            limits: { memory: 4Gi }
          livenessProbe:
            exec: { command: ["valkey-cli", "ping"] }
            initialDelaySeconds: 30
          readinessProbe:
            exec: { command: ["valkey-cli", "ping"] }
            initialDelaySeconds: 5
  volumeClaimTemplates:
    - metadata: { name: valkey-data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources: { requests: { storage: 10Gi } }
```

## Valkey-Specific Gotchas

- **OOMKilled during persistence** - fork doubles memory; set memory limit > 2x `maxmemory`
- **UID conflicts** - official image UID 999, Bitnami UID 1001; switching charts requires PVC permission fixes
- **Cluster gossip port** - port 16379 must be allowed in Network Policies
- **Split-brain with Sentinel** - use `min-replicas-to-write 1`
- **Termination grace period** - increase for large datasets (default 30s may not allow RDB save)
- **Headless service** - use `publishNotReadyAddresses: true` or DNS drops during pod restart breaking replication
