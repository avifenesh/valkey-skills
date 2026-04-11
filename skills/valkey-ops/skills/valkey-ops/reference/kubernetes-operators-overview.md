# Kubernetes Operators - Overview and CRDs

Use when comparing Kubernetes operators for Valkey, writing CRD manifests for the Official or Hyperspike operators, or deciding between operators and Helm charts.

## Contents

- Operator Comparison (line 16)
- Valkey Official Operator (valkey-io/valkey-operator) (line 38)
- Hyperspike Valkey Operator (line 164)

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

---

## See Also

- [operators-day2](kubernetes-operators-day2.md) - SAP operator, day-2 operations, choosing between operators
- [helm](kubernetes-helm.md) - Helm chart deployment
- [statefulset-config](kubernetes-statefulset-config.md) - Raw StatefulSet patterns
