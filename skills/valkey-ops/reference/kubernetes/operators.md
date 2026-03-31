# Kubernetes Operators for Valkey

Use when deploying Valkey via a Kubernetes operator, comparing operator options, writing CRD manifests, or deciding between operators and Helm charts.

## Contents

- Operator Comparison (line 17)
- Valkey Official Operator (valkey-io/valkey-operator) (line 39)
- Hyperspike Valkey Operator (line 165)
- SAP Valkey Operator (line 289)
- Operator Day-2 Operations (line 355)
- Choosing Between Operators (line 395)
- See Also (line 408)

---

## Operator Comparison

| Feature | Valkey Official Operator | Hyperspike Operator | SAP Operator |
|---------|-------------------------|-------------------|--------------|
| **API version** | `valkey.io/v1alpha1` | `hyperspike.io/v1` | **v1alpha1** |
| Modes | Cluster only | Standalone, Sentinel, Cluster | Sentinel, Static primary |
| CRD name | `ValkeyCluster` | `Valkey` (shortName: `vk`) | `Valkey` |
| API group | `valkey.io` | `hyperspike.io` | `cache.cs.sap.com` |
| TLS | Not yet | Yes (cert-manager integration) | Yes (cert-manager integration) |
| Prometheus integration | Exporter sidecar (enabled by default) | ServiceMonitor | ServiceMonitor + PrometheusRule |
| External access | Not yet | Envoy proxy or per-shard LB | No |
| OpenShift | Not yet | Yes (`platformManagedSecurityContext`) | No |
| Underlying deployment | StatefulSet or Deployment | Custom StatefulSets | Bitnami Helm chart |
| ACL / Users | Declarative `users` spec with fine-grained ACL | No | No |
| Install method | make deploy (no Helm yet) | Helm or kubectl | Helm or kubectl |
| Maturity | Early development (WIP) | Pre-1.0 (community) | Enterprise (SAP) |

### When to Use an Operator vs Helm

- **Operator**: automated day-2 operations (failover, scaling, backup), declarative desired state, CRD-based GitOps
- **Helm**: simpler deployments, one-time setup, full control over templates, lower abstraction

## Valkey Official Operator (valkey-io/valkey-operator)

The official Kubernetes operator from the Valkey project. Written in Go, built with kubebuilder. In active early development - not yet production-ready. Contributions and feedback welcome via the repo's [Discussions](https://github.com/valkey-io/valkey-operator/discussions).

- **Repo**: https://github.com/valkey-io/valkey-operator
- **License**: Apache 2.0
- **Status**: Work in progress - API and features are evolving

### Installation

No Helm chart yet. Deploy from source using the Makefile:

```bash
# Clone and build
git clone https://github.com/valkey-io/valkey-operator.git
cd valkey-operator

# Install CRDs
make install

# Build and push operator image, then deploy
make docker-build docker-push IMG=<your-registry>/valkey-operator:latest
make deploy IMG=<your-registry>/valkey-operator:latest
```

### CRD: Cluster with StatefulSet (Default)

```yaml
apiVersion: valkey.io/v1alpha1
kind: ValkeyCluster
metadata:
  name: cluster-sample
spec:
  shards: 3
  replicas: 1
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"
```

### CRD: Cluster with Deployment Workload

```yaml
apiVersion: valkey.io/v1alpha1
kind: ValkeyCluster
metadata:
  name: cluster-sample-deployment
spec:
  shards: 3
  replicas: 1
  workloadType: Deployment
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"
```

The `workloadType` field is immutable after creation. Defaults to `StatefulSet`.

### CRD: Cluster with Declarative ACL Users

```yaml
apiVersion: valkey.io/v1alpha1
kind: ValkeyCluster
metadata:
  name: cluster-with-users
spec:
  shards: 3
  replicas: 1
  users:
    - name: alice
      enabled: true
      passwordSecret:
        name: my-user-secrets
        keys: [alicepw]
      commands:
        allow: ["@read", "@write", "@connection"]
        deny: ["@admin", "@dangerous"]
      keys:
        readWrite: ["app:*", "cache:*"]
        readOnly: ["shared:*"]
        writeOnly: ["logs:*"]
      channels:
        patterns: ["notifications:*"]
    - name: readonly-user
      nopass: true
      enabled: true
      permissions: "+@read ~* &*"
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"
```

### Official Operator Features

- Cluster mode with configurable shards and replicas per shard
- StatefulSet or Deployment workload types (immutable after creation)
- Declarative ACL user management with fine-grained permissions (commands, keys, channels)
- Password references via Kubernetes Secrets
- Metrics exporter sidecar (enabled by default)
- Pod scheduling: tolerations, nodeSelector, affinity (anti-affinity rules applied by default)
- Custom container overrides via strategic merge patch
- Cluster state tracking: Initializing, Reconciling, Ready, Degraded, Failed
- Conditions: Ready, Progressing, Degraded, ClusterFormed, SlotsAssigned

### Current Limitations (WIP)

- Cluster mode only - no Standalone or Sentinel mode yet
- No TLS support yet
- No external access (no LoadBalancer or proxy support)
- No Helm chart for operator installation
- No persistence/storage configuration yet
- No backup/restore
- API is v1alpha1 - expect breaking changes

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

- Standalone, Sentinel, and Cluster modes
- cert-manager integration for TLS (specify issuer name and type)
- Envoy proxy for external access (avoids per-shard LoadBalancers)
- Prometheus ServiceMonitor creation
- Persistent volume claim management
- OpenShift support via `platformManagedSecurityContext`
- Container image signing via cosign

**Known limitation**: the `replicas` field currently creates extra primary
nodes rather than per-shard replicas. No backup/restore functionality.

### External Access (Hyperspike)

Two modes for external client access:

**Proxy** - single LoadBalancer with Envoy routing (recommended):
```yaml
spec:
  externalAccess:
    enabled: true
    type: Proxy
    proxy:
      image: "envoyproxy/envoy:v1.32.1"
      replicas: 2
```

**LoadBalancer** - one LB per shard (simpler but more expensive):
```yaml
spec:
  externalAccess:
    enabled: true
    type: LoadBalancer
```

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

## See Also

- [Helm Charts](helm.md) - chart-based deployment
- [StatefulSet Patterns](statefulset.md) - raw StatefulSet deployment
- [Kubernetes Tuning](tuning-k8s.md) - kernel tuning in K8s
- [Capacity Planning](../operations/capacity-planning.md) - memory and resource sizing
- [Performance I/O Threads](../performance/io-threads.md) - I/O thread CPU allocation for operator manifests
- [Performance Memory](../performance/memory.md) - memory optimization for resource spec sizing
- [Rolling Upgrades](../upgrades/rolling-upgrade.md) - zero-downtime upgrade procedures
- [Production Checklist](../production-checklist.md) - full pre-launch verification
