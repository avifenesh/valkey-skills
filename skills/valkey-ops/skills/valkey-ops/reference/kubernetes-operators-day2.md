# Kubernetes Operators - SAP, Day-2, and Selection

Use when deploying Valkey via the SAP Kubernetes operator, performing day-2 operator operations (scaling, upgrades), or choosing between the available operators.

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
- Auto-generates a binding secret with connection details (host, port,
  password, CA cert, sentinel config) - customizable via Go templates
- cert-manager integration (auto self-signed or custom issuer)
- Prometheus exporter + ServiceMonitor + PrometheusRule
- Auto-generates topology spread constraints when not specified
- `sentinel.enabled` is immutable after creation
- Bitnami chart values passthrough for advanced config
- Namespace-scoped operation

## Operator Day-2 Operations

### Scaling

```bash
# Valkey Official - edit the CRD
kubectl patch valkeycluster cluster-sample --type merge \
  -p '{"spec":{"shards":6,"replicas":2}}'
# Operator rebalances slots across new shards

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
| Official Valkey project alignment | Valkey Official (once stable) |
| Valkey Cluster with sharding (production today) | Hyperspike |
| Sentinel HA without sharding | Hyperspike or SAP (SAP simpler) |
| Enterprise support needed | SAP |
| Declarative ACL user management | Valkey Official |
| GitOps with ArgoCD/Flux | Any (all CRD-based) |
| Need Bitnami image hardening | SAP (uses Bitnami) |
| Full cluster lifecycle automation | Hyperspike |

---

## See Also

- [operators-overview](kubernetes-operators-overview.md) - Operator comparison, Official and Hyperspike CRDs
- [helm](kubernetes-helm.md) - Helm chart deployment
- [statefulset-config](kubernetes-statefulset-config.md) - Raw StatefulSet patterns
