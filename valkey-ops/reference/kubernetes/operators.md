# Kubernetes Operators for Valkey

Use when deploying Valkey via a Kubernetes operator, comparing operator options, writing CRD manifests, or deciding between operators and Helm charts.

---

## Operator Comparison

| Feature | Hyperspike Operator | SAP Operator |
|---------|-------------------|--------------|
| Modes | Cluster, Sentinel, Standalone | Sentinel, Static primary |
| CRD name | `Valkey` | `Valkey` |
| API group | `hyperspike.io` | `cache.cs.sap.com` |
| TLS | Yes | Yes |
| Prometheus integration | ServiceMonitor | Via Bitnami chart |
| Underlying deployment | Custom StatefulSets | Bitnami Helm chart |
| Install method | Helm or kubectl | Helm or kubectl |
| Maturity | Community | Enterprise (SAP) |

### When to Use an Operator vs Helm

- **Operator**: automated day-2 operations (failover, scaling, backup), declarative desired state, CRD-based GitOps
- **Helm**: simpler deployments, one-time setup, full control over templates, lower abstraction

## Hyperspike Valkey Operator

### Installation

```bash
# Via Helm
helm install valkey-operator oci://ghcr.io/hyperspike/valkey-operator

# Via kubectl
kubectl apply -f https://github.com/hyperspike/valkey-operator/releases/latest/download/install.yaml
```

### CRD: Standalone Instance

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: my-valkey
  namespace: default
spec:
  replicas: 1
  mode: standalone
  resources:
    requests:
      memory: 1Gi
      cpu: 250m
    limits:
      memory: 2Gi
  storage:
    size: 5Gi
    storageClassName: fast-ssd
```

### CRD: Cluster Mode

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: my-cluster
  namespace: default
spec:
  replicas: 6           # 3 primaries + 3 replicas
  mode: cluster
  clusterReplicas: 1    # replicas per primary
  resources:
    requests:
      memory: 2Gi
      cpu: 500m
    limits:
      memory: 4Gi
  storage:
    size: 10Gi
    storageClassName: fast-ssd
  tls:
    enabled: true
    secretName: valkey-tls-secret
  monitoring:
    serviceMonitor:
      enabled: true
      interval: 15s
```

### CRD: Sentinel Mode

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: my-sentinel
  namespace: default
spec:
  replicas: 3           # 1 primary + 2 replicas
  mode: sentinel
  sentinel:
    replicas: 3          # number of Sentinel instances
    quorum: 2
  resources:
    requests:
      memory: 2Gi
      cpu: 500m
    limits:
      memory: 4Gi
  storage:
    size: 10Gi
```

### Hyperspike Operator Features

- Automatic failover handling for Sentinel and Cluster modes
- TLS certificate management
- Prometheus ServiceMonitor creation
- Persistent volume claim management
- Rolling upgrades via StatefulSet update strategy

## SAP Valkey Operator

The SAP operator wraps the Bitnami Helm chart, adding operator lifecycle management.

### Installation

```bash
# Install the SAP operator via its Helm chart
helm repo add sap https://sap.github.io/valkey-operator/
helm install valkey-operator sap/valkey-operator
```

### CRD: Sentinel Topology

```yaml
apiVersion: cache.cs.sap.com/v1alpha1
kind: Valkey
metadata:
  name: my-valkey
spec:
  replicas: 3
  sentinel:
    enabled: true
  tls:
    enabled: true
  persistence:
    storageClass: standard
    size: 10Gi
```

Key behaviors:
- Sentinel is exposed on port 26379
- Valkey data nodes on port 6379
- `spec.sentinel.enabled` is **immutable after creation** - you cannot toggle Sentinel mode on an existing deployment
- The operator manages the Bitnami chart release internally

### CRD: Static Primary

```yaml
apiVersion: cache.cs.sap.com/v1alpha1
kind: Valkey
metadata:
  name: my-valkey
spec:
  replicas: 3
  sentinel:
    enabled: false
  persistence:
    storageClass: standard
    size: 10Gi
```

Without Sentinel, the first pod is always the primary. No automatic failover occurs.

### SAP Operator Features

- Two topologies: static primary and Sentinel
- Bitnami chart values passthrough for advanced config
- TLS support
- Persistent storage management
- Namespace-scoped operation

## Operator Day-2 Operations

### Scaling

```bash
# Hyperspike - edit the CRD
kubectl patch valkey my-cluster --type merge \
  -p '{"spec":{"replicas":9}}'
# Operator handles adding nodes and rebalancing (cluster mode)

# SAP - edit the CRD
kubectl patch valkey my-valkey --type merge \
  -p '{"spec":{"replicas":5}}'
```

### Version Upgrades

```bash
# Update the image version in the CRD
kubectl patch valkey my-cluster --type merge \
  -p '{"spec":{"image":"valkey/valkey:9.1"}}'
# Operator performs rolling upgrade automatically
```

### Monitoring Operator Health

```bash
# Check operator logs
kubectl logs -n valkey-operator-system deployment/valkey-operator-controller-manager

# Check CRD status
kubectl get valkey
kubectl describe valkey my-cluster
```

## Choosing Between Operators

| Scenario | Recommendation |
|----------|---------------|
| Valkey Cluster with sharding | Hyperspike |
| Sentinel HA without sharding | Either (SAP simpler) |
| Enterprise support needed | SAP |
| GitOps with ArgoCD/Flux | Either (CRD-based) |
| Need Bitnami image hardening | SAP (uses Bitnami) |
| Full cluster lifecycle automation | Hyperspike |

## See Also

- [Helm Charts](helm.md) - chart-based deployment
- [StatefulSet Patterns](statefulset.md) - raw StatefulSet deployment
- [Kubernetes Tuning](tuning-k8s.md) - kernel tuning in K8s
- [Production Checklist](../production-checklist.md) - full pre-launch verification
