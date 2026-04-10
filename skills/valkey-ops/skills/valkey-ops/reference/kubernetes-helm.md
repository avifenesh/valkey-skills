# Helm Charts for Valkey on Kubernetes

Use when deploying Valkey on Kubernetes via Helm, choosing between the official and Bitnami charts, or configuring chart values for production.

## Contents

- Tested Example: kind + Helm Deployment (line 18)
- Chart Comparison (line 48)
- Official Valkey Helm Chart (line 75)
- Bitnami Helm Chart (line 142)
- Production Values Recommendations (line 219)
- Upgrading Helm Releases (line 264)
- Migrating from Bitnami to Official Chart (line 282)

---

## Tested Example: kind + Helm Deployment

```bash
# Create a local K8s cluster with kind
kind create cluster --name valkey-test

# Add the Valkey Helm repo and install (standalone by default)
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update
helm install my-valkey valkey/valkey

# Wait for the pod to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=valkey \
  --timeout=120s

# Connect and verify
kubectl exec -it svc/my-valkey -- valkey-cli PING
# Expected: PONG

kubectl exec -it svc/my-valkey -- valkey-cli SET test "helm works"
kubectl exec -it svc/my-valkey -- valkey-cli GET test
# Expected: "helm works"

# Cleanup
helm uninstall my-valkey
kind delete cluster --name valkey-test
```

---

## Chart Comparison

| Feature | Official Valkey Chart | Bitnami Chart |
|---------|----------------------|---------------|
| Repository | `valkey/valkey` | `oci://registry-1.docker.io/bitnamicharts/valkey` |
| **Chart version** | Check chart repo for latest | Check Bitnami for latest |
| **App version** | Check chart repo for latest | Check Bitnami for latest |
| Architectures | Standalone, replication | Standalone, replication, cluster |
| Cluster mode | No | Yes (separate `valkey-cluster` chart) |
| Sentinel | No | Yes |
| PDB | No (create manually) | Yes (default) |
| TLS | Yes | Yes |
| Metrics sidecar | redis_exporter | redis_exporter |
| ACL support | Yes (ACL-based) | Yes (password-based default) |
| Persistence default | Disabled | Enabled (8Gi) |
| Auth default | Disabled | Enabled (random password) |
| VPA/HPA | No | Yes (replica autoscaling) |
| OpenShift | Manual | Auto-adapt security context |
| Base image | `valkey/valkey` | `bitnami/valkey` (hardened) |
| License | BSD | Apache 2.0 |

### When to Use Which

- **Official chart**: standard standalone or replication deployments, want upstream defaults
- **Bitnami chart**: need cluster mode, Sentinel HA, hardened images, or extensive value customization
- **Bitnami valkey-cluster**: specifically for Valkey Cluster (hash-slot sharding across primaries)

## Official Valkey Helm Chart

### Installation

```bash
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update

# Standalone
helm install my-valkey valkey/valkey

# Replication (1 primary + N replicas)
helm install my-valkey valkey/valkey \
  --set replica.enabled=true \
  --set replica.replicas=3 \
  --set auth.enabled=true \
  --set auth.password=secretpassword
```

### Key Values

```yaml
# Authentication
auth:
  enabled: true
  password: ""           # set explicitly or use existingSecret
  existingSecret: ""     # name of a Kubernetes Secret
  aclUsers: []           # additional ACL users

# Replica configuration (standalone when replica.enabled is false)
replica:
  enabled: true
  replicas: 3
  persistence:
    size: 8Gi
    storageClass: ""     # use cluster default if empty

# TLS
tls:
  enabled: false
  existingSecret: ""     # Secret with server.crt, server.key, ca.crt

# Metrics (redis_exporter sidecar)
metrics:
  enabled: true          # deploys redis_exporter alongside each pod

# Custom Valkey configuration (appended to valkey.conf)
valkeyConfig: |
  maxmemory 2gb
  maxmemory-policy allkeys-lru
  tcp-keepalive 300
  latency-monitor-threshold 100
```

### Service Access

After deployment, connect from within the cluster:

```bash
# Standalone
valkey-cli -h my-valkey -p 6379 -a <password>

# Replication - write to primary, read from replicas
valkey-cli -h my-valkey -p 6379 -a <password>               # writes
valkey-cli -h my-valkey-read -p 6379 -a <password>           # reads
```

## Bitnami Helm Chart

### Installation

```bash
# Standalone / replication
helm install my-valkey oci://registry-1.docker.io/bitnamicharts/valkey

# Cluster mode (separate chart)
helm install my-valkey oci://registry-1.docker.io/bitnamicharts/valkey-cluster
```

### Key Values (Bitnami)

```yaml
# Architecture: standalone | replication | sentinel
architecture: replication

# Authentication
auth:
  enabled: true
  password: ""
  existingSecret: ""

# Primary configuration
master:
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""
  resources:
    requests:
      memory: 2Gi
      cpu: 500m
    limits:
      memory: 4Gi
      # Avoid CPU limits for latency-sensitive workloads

# Replica configuration
replica:
  replicaCount: 3
  persistence:
    enabled: true
    size: 8Gi

# Sentinel (when architecture=sentinel)
sentinel:
  enabled: false
  quorum: 2
  downAfterMilliseconds: 5000

# Metrics
metrics:
  enabled: true
  serviceMonitor:
    enabled: true         # creates ServiceMonitor for Prometheus Operator
    interval: 15s
```

### Bitnami Cluster Chart Values

```yaml
# For the valkey-cluster chart
cluster:
  nodes: 6               # total nodes (primaries + replicas)
  replicas: 1             # replicas per primary

persistence:
  enabled: true
  size: 10Gi

# External access (if needed)
cluster:
  externalAccess:
    enabled: false        # expose via LoadBalancer/NodePort
```

## Production Values Recommendations

These values apply to both charts:

```yaml
# Persistence - always enable in production
persistence:
  enabled: true
  size: 10Gi              # 2x expected dataset size
  storageClass: fast-ssd  # use SSD-backed storage class

# Resources
resources:
  requests:
    memory: 2Gi           # match maxmemory + overhead
    cpu: 500m
  limits:
    memory: 4Gi           # 2x requests for fork headroom
    # No CPU limit - avoids throttling latency-sensitive workloads

# Pod Disruption Budget
pdb:
  enabled: true
  maxUnavailable: 1       # never 0, that blocks node drains

# Anti-affinity - spread pods across nodes
podAntiAffinity: soft     # or "hard" for strict placement

# Security context
securityContext:
  runAsNonRoot: true
  runAsUser: 999          # valkey user

# Custom Valkey config
valkeyConfig: |
  maxmemory 2gb
  maxmemory-policy allkeys-lru
  maxmemory-clients 5%
  tcp-keepalive 300
  latency-monitor-threshold 100
  appendonly yes
  appendfsync everysec
  aof-use-rdb-preamble yes
```

## Upgrading Helm Releases

```bash
# Check current values
helm get values my-valkey

# Upgrade with new chart version
helm repo update
helm upgrade my-valkey valkey/valkey -f values.yaml

# Upgrade with changed values
helm upgrade my-valkey valkey/valkey \
  --set replica.replicas=5 \
  --reuse-values
```

Helm upgrades trigger rolling restarts for StatefulSets. Pods are restarted one at a time in reverse ordinal order (highest first), which means replicas restart before the primary.

## Migrating from Bitnami to Official Chart

In-place upgrade is NOT possible due to incompatible naming conventions,
labels, and StatefulSet structures. Use a replication-based migration:

1. Deploy official chart alongside existing Bitnami deployment
2. Configure the new instance as a replica of the Bitnami primary via
   `replicaof` and `primaryauth`
3. Wait for sync (`INFO replication` shows `master_link_status:up`)
4. Failover: promote new instance, switch client endpoints
5. Tear down Bitnami deployment

Plan for a brief maintenance window to ensure all writes are fully
replicated before switching endpoints.

---
