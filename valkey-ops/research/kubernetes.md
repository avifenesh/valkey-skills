# Valkey on Kubernetes - Deep Research

Research date: 2026-03-29
Sources: GitHub repos (valkey-io/valkey-helm, bitnami/charts, hyperspike/valkey-operator, SAP/redis-operator), actual values.yaml files, CRD specs, chart templates

---

## 1. Official Valkey Helm Chart (valkey-io/valkey-helm)

- **Repo**: https://github.com/valkey-io/valkey-helm
- **Chart version**: 0.9.3 (released 2026-01-15)
- **App version**: Valkey 9.0.1
- **Helm repo URL**: `https://valkey.io/valkey-helm/`
- **Image**: `docker.io/valkey/valkey`
- **License**: BSD 3-Clause
- **Maintainers**: mk-raven, sgissi

### Installation

```bash
helm repo add valkey https://valkey.io/valkey-helm/
helm install valkey valkey/valkey
```

### Architecture Options

Two modes - standalone (default) and replication:

**Standalone** - single Valkey pod, optional PVC. Uses a Deployment.

**Replication** - StatefulSet with 1 master + N replicas. Requires `replica.enabled=true`.
- Total pods = `replica.replicas + 1` (master)
- Default: 2 replicas + 1 master = 3 pods
- Uses `OrderedReady` pod management policy
- Headless service for pod discovery: `<release>-headless`
- Read service: `<release>-read` (load-balances across all pods)
- Write service: `<release>` (points to master)

Notable: This chart does NOT support cluster mode (sharding) or Sentinel. It is purely standalone or primary-replica replication.

### Key values.yaml Parameters

```yaml
# Replication mode
replica:
  enabled: false            # Enable master-replica mode
  replicas: 2               # Number of replicas (total pods = replicas + 1)
  replicationUser: "default"  # ACL user for replication auth
  disklessSync: false        # Sync from memory vs disk
  minReplicasToWrite: 0      # Write safety (0 = disabled)
  minReplicasMaxLag: 10      # Max replication lag seconds
  persistence:
    size: ""                 # REQUIRED when replica.enabled=true
    storageClass: ""
    accessModes: [ReadWriteOnce]
  service:
    enabled: true            # Read service
    type: ClusterIP

# Standalone persistence
dataStorage:
  enabled: false
  requestedSize: ""
  className: ""
  accessModes: [ReadWriteOnce]
  keepPvc: false

# Security context (hardened defaults)
podSecurityContext:
  fsGroup: 1000
  runAsUser: 1000
  runAsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1000

# Auth (ACL-based)
auth:
  enabled: false
  usersExistingSecret: ""
  aclUsers: {}
  aclConfig: ""

# TLS
tls:
  enabled: false
  existingSecret: ""
  serverPublicKey: server.crt
  serverKey: server.key
  caPublicKey: ca.crt
  requireClientCertificate: false

# Metrics (redis_exporter sidecar)
metrics:
  enabled: false
  exporter:
    image:
      registry: ghcr.io
      repository: oliver006/redis_exporter
      tag: "v1.79.0"
    port: 9121
  serviceMonitor:
    enabled: false
    interval: 30s
  podMonitor:
    enabled: false
  prometheusRule:
    enabled: false

# Scheduling
nodeSelector: {}
tolerations: []
affinity: {}
topologySpreadConstraints: []
priorityClassName: ""
deploymentStrategy: RollingUpdate

# Cluster domain
clusterDomain: cluster.local
```

### Gotchas and Production Notes

1. **Persistence mandatory for replication** - Without persistence, a restarted primary comes up empty, all replicas sync from it, and all data is lost. The chart validates this.
2. **No PDB** - The official chart does NOT create a PodDisruptionBudget. You must create one manually.
3. **No Sentinel** - No automatic failover. If the master pod dies, replicas wait until Kubernetes restarts it.
4. **ACL default user warning** - When `auth.enabled=true`, the `default` user MUST be defined in `aclUsers` or `aclConfig`. Otherwise anyone can connect without credentials.
5. **Config checksum annotation** - StatefulSet pods have `checksum/initconfig` and `checksum/config` annotations, so config changes trigger rolling restarts.
6. **Init container** - An init container generates `/data/conf/valkey.conf` at startup, configuring replicaof, ACL, TLS, etc. The main container runs `valkey-server /data/conf/valkey.conf`.
7. **DNS pattern for replicas**: `<release>-<index>.<release>-headless.<namespace>.svc.cluster.local`
8. **Headless service** uses `publishNotReadyAddresses: true` for stable DNS during restarts.

### Replication Auth Example

```yaml
auth:
  enabled: true
  usersExistingSecret: "valkey-passwords"
  aclUsers:
    default:
      permissions: "~* &* +@all"
    repl-user:
      permissions: "+psync +replconf +ping"
replica:
  enabled: true
  replicas: 2
  replicationUser: "repl-user"
  persistence:
    size: 10Gi
    storageClass: "gp3"
```

### Write Safety Configuration

```yaml
replica:
  minReplicasToWrite: 1  # Reject writes if fewer than 1 replica in sync
  minReplicasMaxLag: 10  # Replica considered unhealthy after 10s lag
```

---

## 2. Bitnami Valkey Helm Chart

- **Chart**: `oci://registry-1.docker.io/bitnamicharts/valkey`
- **Chart version**: 4.0.2
- **App version**: Valkey 8.1.3
- **Image**: `docker.io/bitnami/valkey:8.1.3-debian-12-r3`
- **License**: Apache-2.0
- **Prerequisites**: Kubernetes 1.23+, Helm 3.8.0+

### Architecture Options

Three topologies:
1. **Standalone** (`architecture: standalone`) - single StatefulSet
2. **Primary-Replicas** (`architecture: replication`) - separate primary and replica StatefulSets
3. **Primary-Replicas with Sentinel** (`architecture: replication` + `sentinel.enabled: true`) - single StatefulSet with Sentinel sidecars

### Key Differences from Official Chart

| Feature | Official (valkey-io) | Bitnami |
|---------|---------------------|---------|
| Chart version | 0.9.3 | 4.0.2 |
| Valkey version | 9.0.1 | 8.1.3 |
| Sentinel support | No | Yes |
| Cluster mode (sharding) | No | No (separate chart) |
| PDB | No | Yes (default created) |
| Auth default | Disabled | Enabled with random password |
| Persistence default | Disabled | Enabled (8Gi) |
| Default architecture | standalone | replication |
| OpenShift support | Manual | Auto-adapt security context |
| Resource presets | No | Yes (nano, micro, small, etc.) |
| VPA/HPA | No | Yes (replica autoscaling) |
| Disable commands | No | FLUSHDB, FLUSHALL disabled |
| External primary bootstrap | No | Yes |
| ExternalDNS | No | Yes |
| Diagnostic mode | No | Yes |

### Key values.yaml Parameters (Bitnami-specific)

```yaml
architecture: replication  # Default is replication, not standalone

auth:
  enabled: true           # On by default (unlike official chart)
  sentinel: true
  password: ""            # Auto-generated if empty
  existingSecret: ""
  usePasswordFiles: true  # Mount as files, not env vars

commonConfiguration: |-
  appendonly yes
  save ""

primary:
  kind: StatefulSet
  replicaCount: 1
  disableCommands: [FLUSHDB, FLUSHALL]
  resourcesPreset: "nano"  # Use explicit resources in production
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""
  podAntiAffinityPreset: soft  # Soft anti-affinity by default
  pdb:
    create: true
  persistentVolumeClaimRetentionPolicy:
    enabled: false
    whenScaled: Retain
    whenDeleted: Retain
  terminationGracePeriodSeconds: 30

replica:
  kind: StatefulSet
  replicaCount: 3
  disableCommands: [FLUSHDB, FLUSHALL]
  resourcesPreset: "nano"
  persistence:
    enabled: true
    size: 8Gi
  podAntiAffinityPreset: soft
  pdb:
    create: true
  autoscaling:
    vpa:
      enabled: false
    hpa:
      enabled: false
  externalPrimary:
    enabled: false
    host: ""

sentinel:
  enabled: false
  image:
    repository: bitnami/valkey-sentinel
    tag: 8.1.3-debian-12-r3
  primarySet: myprimary
  quorum: 2
  downAfterMilliseconds: 60000
  failoverTimeout: 180000
  parallelSyncs: 1
  valkeyShutdownWaitFailover: true
  containerPorts:
    sentinel: 26379
  service:
    type: ClusterIP
    ports:
      valkey: 6379
      sentinel: 26379
    createPrimary: false  # Experimental: service pointing to current primary
  persistence:
    enabled: false
    size: 100Mi
  terminationGracePeriodSeconds: 30
```

### Bitnami Sentinel Mode Details

When `sentinel.enabled=true`:
- All pods in a single StatefulSet (each has Valkey + Sentinel containers)
- One unified service exposes both ports 6379 (Valkey) and 26379 (Sentinel)
- Primary/replica services are disabled
- Clients connect to Sentinel to discover the current primary
- On graceful termination, failover is initiated before pod terminates
- `valkeyShutdownWaitFailover: true` (default) makes the Valkey container also wait for failover

```bash
# Discover primary via Sentinel
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name myprimary
```

### OpenShift Compatibility

```yaml
global:
  compatibility:
    openshift:
      adaptSecurityContext: auto  # auto, force, or disabled
```

When set to `auto` or `force`, the chart removes `runAsUser`, `runAsGroup`, and `fsGroup` from security contexts, letting OpenShift manage them via SCCs.

---

## 3. Bitnami Valkey Cluster Chart (Sharding)

- **Chart**: `oci://registry-1.docker.io/bitnamicharts/valkey-cluster`
- **Chart version**: 3.0.25
- **App version**: Valkey 8.1.3
- **Image**: `docker.io/bitnami/valkey-cluster:8.1.3-debian-12-r3`

### When to Use This vs. the Regular Chart

| Valkey (Bitnami) | Valkey Cluster (Bitnami) |
|-------------------|--------------------------|
| Multiple databases | Only one database |
| Single write point | Multiple write points (sharding) |
| Good for moderate datasets | Better for large datasets |
| Sentinel for HA | Built-in cluster failover |

### Key Parameters

```yaml
cluster:
  init: true        # Initialize cluster on first install
  nodes: 6          # Total nodes (3 primary + 3 replica)
  replicas: 1       # Replicas per primary

persistence:
  enabled: true
  path: /bitnami/valkey/data
  size: 8Gi
  accessModes: [ReadWriteOnce]

pdb:
  create: true
  minAvailable: ""
  maxUnavailable: ""

usePassword: true
usePasswordFiles: true

tls:
  enabled: false
  autoGenerated: false

valkey:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0

# Scale operations require update jobs
updateJob:
  activeDeadlineSeconds: 600
```

### Cluster Topology Math

`nodes = numberOfPrimaryNodes + numberOfPrimaryNodes * replicas`

Examples:
- `nodes: 6, replicas: 1` = 3 primaries + 3 replicas
- `nodes: 9, replicas: 2` = 3 primaries + 6 replicas (2 replicas each)

Minimum: 3 primary nodes required.

### External Access for Cluster Mode

```yaml
cluster:
  externalAccess:
    enabled: true
    service:
      type: LoadBalancer
      loadbalancerIP: []  # Set after first install with actual IPs
```

Creates one LoadBalancer per node. Two-step process:
1. Install, get external IPs
2. Upgrade with the IPs in `loadbalancerIP` array

### Scaling a Cluster

Adding nodes requires a post-upgrade hook:
```bash
helm upgrade my-release oci://registry-1.docker.io/bitnamicharts/valkey-cluster \
  --set cluster.nodes=9 \
  --set cluster.replicas=2 \
  --set cluster.update.addNodes=true \
  --set cluster.update.currentNumberOfNodes=6 \
  --set password=$VALKEY_PASSWORD
```

---

## 4. Hyperspike Valkey Operator

- **Repo**: https://github.com/hyperspike/valkey-operator
- **Latest version**: v0.0.61 (2025-10-12)
- **Language**: Go
- **Stars**: 302
- **CRD group**: `hyperspike.io`
- **CRD kind**: `Valkey` (shortName: `vk`)
- **License**: Apache-2.0

### What It Does

Provisions Valkey **cluster mode** (sharded) clusters natively on Kubernetes. This is the only Kubernetes-native operator purpose-built for Valkey (not Redis).

### Installation

**Via Helm**:
```bash
LATEST=$(curl -s https://api.github.com/repos/hyperspike/valkey-operator/releases/latest | jq -cr .tag_name)
helm install valkey-operator \
  --namespace valkey-operator-system \
  --create-namespace \
  oci://ghcr.io/hyperspike/valkey-operator \
  --version ${LATEST}-chart
```

**Via manifest**:
```bash
LATEST=$(curl -s https://api.github.com/repos/hyperspike/valkey-operator/releases/latest | jq -cr .tag_name)
curl -sL https://github.com/hyperspike/valkey-operator/releases/download/$LATEST/install.yaml | kubectl create -f -
```

### CRD Spec (ValkeySpec)

```go
type ValkeySpec struct {
    Image            string                          // Container image
    ExporterImage    string                          // Prometheus exporter image
    Shards           int32  `json:"nodes"`           // Number of shards (default: 3)
    Replicas         int32                           // Replicas per shard (default: 0)
    VolumePermissions bool                           // Init container for volume perms
    TLS              bool                            // Enable TLS (default: false)
    CertIssuer       string                          // cert-manager issuer name
    CertIssuerType   string                          // ClusterIssuer or Issuer
    Prometheus       bool                            // Enable metrics (default: false)
    PrometheusLabels map[string]string               // Extra labels for ServiceMonitor
    ServiceMonitor   bool                            // Create ServiceMonitor CR
    ClusterDomain    string                          // K8s cluster domain (default: cluster.local)
    Storage          *corev1.PersistentVolumeClaim   // PVC spec
    Resources        *corev1.ResourceRequirements    // CPU/memory
    ExternalAccess   *ExternalAccess                 // External access config
    AnonymousAuth    bool                            // Allow passwordless access
    ServicePassword  *corev1.SecretKeySelector       // Existing password secret
    Tolerations      []corev1.Toleration
    NodeSelector     map[string]string
    ClusterPreferredEndpointType string              // ip, hostname, unknown-endpoint
    PlatformManagedSecurityContext bool              // Delegate to OpenShift SCCs
}
```

### Minimal CR Example

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: my-cache
spec:
  volumePermissions: true
```

This creates a 3-shard Valkey cluster with no replicas, no TLS, no auth.

### Production CR Example

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: production-cache
spec:
  nodes: 3
  replicas: 1
  tls: true
  certIssuer: "letsencrypt-prod"
  certIssuerType: ClusterIssuer
  prometheus: true
  serviceMonitor: true
  anonymousAuth: false
  servicePassword:
    name: valkey-password
    key: password
  storage:
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 10Gi
      storageClassName: gp3
  resources:
    requests:
      cpu: "500m"
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 4Gi
  nodeSelector:
    workload: cache
  tolerations:
    - key: dedicated
      value: cache
      effect: NoSchedule
```

### External Access

Two modes:

**Proxy mode** (default) - Single LoadBalancer with Envoy proxy routing:
```yaml
spec:
  externalAccess:
    enabled: true
    type: Proxy
    proxy:
      image: "envoyproxy/envoy:v1.32.1"
      replicas: 2
      hostname: "valkey.example.com"
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
```

**LoadBalancer mode** - One LoadBalancer per shard:
```yaml
spec:
  externalAccess:
    enabled: true
    type: LoadBalancer
    loadBalancer:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
```

### Key Features

- Cluster mode (sharding) only - no standalone or Sentinel mode
- cert-manager integration for TLS
- Prometheus + ServiceMonitor support
- Envoy proxy for external access (avoids per-shard LoadBalancers)
- OpenShift support via `platformManagedSecurityContext`
- ExternalDNS support
- Container image signing via cosign

### Known Limitations

- `replicas` field note from source: "This field currently creates extra primary nodes. Follow https://github.com/hyperspike/valkey-operator/issues/186 for details"
- No backup/restore functionality
- No Sentinel mode (cluster mode only)
- Pre-1.0 software (v0.0.61)

---

## 5. SAP Redis Operator

- **Repo**: https://github.com/SAP/redis-operator
- **Stars**: 18
- **Language**: Go Template
- **CRD**: `Redis` (`redis.cache.cs.sap.com/v1alpha1`)
- **License**: Apache-2.0
- **Helm chart**: `oci://ghcr.io/sap/redis-operator-helm/redis-operator`

### What It Does

Wraps the Bitnami Redis chart into a Kubernetes operator. Supports Redis/Valkey but not Valkey cluster mode. Focused on cluster-internal usage.

### CRD Spec

```go
type RedisSpec struct {
    Version     string                    // Redis/Valkey version
    Replicas    int    `default:"1"`      // Minimum 1
    Sentinel    *SentinelProperties       // Sentinel config
    Metrics     *MetricsProperties        // Prometheus exporter
    TLS         *TLSProperties            // TLS with cert-manager
    Persistence *PersistenceProperties    // AOF persistence
    Binding     *BindingProperties        // Auto-generated binding secret
    // Plus: NodeSelector, Affinity, TopologySpreadConstraints,
    //       Tolerations, PriorityClassName, PodSecurityContext,
    //       PodLabels, PodAnnotations, Resources, SecurityContext
}
```

### CR Examples

**Basic Sentinel cluster with TLS and metrics**:
```yaml
apiVersion: cache.cs.sap.com/v1alpha1
kind: Redis
metadata:
  name: test
spec:
  replicas: 3
  sentinel:
    enabled: true
  metrics:
    enabled: true
  tls:
    enabled: true
```

**With cert-manager issuer**:
```yaml
apiVersion: cache.cs.sap.com/v1alpha1
kind: Redis
metadata:
  name: production
spec:
  replicas: 3
  sentinel:
    enabled: true
  tls:
    enabled: true
    certManager:
      issuer:
        kind: ClusterIssuer
        name: cluster-ca
  persistence:
    enabled: true
    size: "10Gi"
    storageClass: "gp3"
```

### Key Features

- Auto-generates a binding secret with connection details (host, port, password, CA cert, sentinel config)
- Binding secret template is customizable via Go templates
- Sentinel mode with automatic failover
- cert-manager integration (auto self-signed or custom issuer)
- Prometheus exporter + ServiceMonitor + PrometheusRule
- Auto-generates topology spread constraints when not specified
- `sentinel.enabled` is immutable after creation

### Topologies Supported

| Mode | Description |
|------|-------------|
| Static primary + replicas | `sentinel.enabled: false` - one master, N-1 read replicas |
| Sentinel | `sentinel.enabled: true` - N pods, each with Redis + Sentinel sidecar |

Does NOT support sharding/cluster mode.

### Auto-generated Binding Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-test-binding
type: Opaque
stringData:
  caData: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  host: redis-test.testns.svc.cluster.local
  masterName: mymaster
  password: BM5vR1ziGE
  port: "6379"
  sentinelEnabled: "true"
  sentinelHost: redis-test.testns.svc.cluster.local
  sentinelPort: "26379"
  tlsEnabled: "true"
```

### Default Topology Spread

When `topologySpreadConstraints` is not set, the operator auto-generates:
```yaml
topologySpreadConstraints:
  - labelSelector:
      matchLabels:
        app.kubernetes.io/component: node
        app.kubernetes.io/instance: test
        app.kubernetes.io/name: redis
    maxSkew: 1
    nodeAffinityPolicy: Honor
    nodeTaintsPolicy: Honor
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    matchLabelKeys: [controller-revision-hash]
```

---

## 6. Kubernetes Best Practices for Stateful Workloads

### StatefulSet Patterns for Valkey

**Pod Management Policy**:
- `OrderedReady` (default, used by official chart) - pods created/deleted sequentially by ordinal index
- `Parallel` - used by Bitnami valkey-cluster for faster startup of all nodes simultaneously

**Update Strategy**:
- `RollingUpdate` - one pod at a time, starting from highest ordinal
- `OnDelete` - manual control, only update pods when explicitly deleted
- `RollingUpdate` with `partition` - staged rollouts, only pods >= partition ordinal are updated

For Valkey replication: `RollingUpdate` is standard. Replicas update first (higher ordinals), then primary (ordinal 0). This is naturally safe.

**PVC Retention Policy** (Kubernetes 1.23+):
```yaml
persistentVolumeClaimRetentionPolicy:
  whenScaled: Retain    # Keep PVCs when scaling down
  whenDeleted: Retain   # Keep PVCs when StatefulSet is deleted
```
Both official and Bitnami charts default to `Retain` for safety.

### Headless Services

Critical for StatefulSet DNS:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: valkey-headless
spec:
  type: ClusterIP
  clusterIP: None
  publishNotReadyAddresses: true  # Critical for stable DNS during restarts
  ports:
    - name: tcp
      port: 6379
  selector:
    app: valkey
```

**DNS pattern**: `<pod-name>.<headless-service>.<namespace>.svc.<cluster-domain>`

Example: `valkey-0.valkey-headless.default.svc.cluster.local`

`publishNotReadyAddresses: true` ensures DNS records exist even when pods are not ready - essential for Valkey nodes to discover each other during startup.

### DNS Resolution Gotchas

1. **DNS propagation delay** - After a pod restart, DNS may take a few seconds to update. Bitnami charts include `nameResolutionThreshold: 5` and `nameResolutionTimeout: 5` to retry.
2. **ndots setting** - Default `ndots: 5` in most clusters causes excessive DNS lookups. For pods doing many external lookups, consider:
   ```yaml
   dnsConfig:
     options:
       - name: ndots
         value: "2"
   ```
3. **Search domains** - Fully-qualified names (with trailing dot) avoid search domain appending.

### Storage Class Selection

| Provider | Recommended Class | Notes |
|----------|------------------|-------|
| AWS EKS | `gp3` | 3000 IOPS baseline, cheaper than gp2 |
| GKE | `premium-rwo` | SSD-backed, single-zone |
| AKS | `managed-premium` | Premium SSD |
| On-prem | Local PV or Ceph | Lowest latency with local PV |

For Valkey, I/O latency matters more than throughput. SSD/NVMe storage classes are strongly recommended for production.

**Local persistent volumes** provide the lowest latency but sacrifice portability - pods are pinned to nodes. Good for dedicated Valkey nodes.

---

## 7. Pod Disruption Budget Strategies

### For Primary-Replica (Non-Sentinel)

Without Sentinel, the primary is a single point of failure. PDB must ensure the primary is available:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-pdb
spec:
  maxUnavailable: 1         # Allow at most 1 pod down during drain
  selector:
    matchLabels:
      app: valkey
```

For a 3-pod setup (1 primary + 2 replicas), `maxUnavailable: 1` means one replica can be evicted, but not the primary and a replica simultaneously.

### For Sentinel Mode

With Sentinel (Bitnami chart), more nuance:

```yaml
# Bitnami default: PDB created for both primary and replica
primary:
  pdb:
    create: true
    # Default: maxUnavailable: 1 when both minAvailable and maxUnavailable are empty
replica:
  pdb:
    create: true
```

**Sentinel quorum considerations**:
- Sentinel needs a majority to elect a new primary
- With 3 Sentinel nodes, quorum = 2, so at most 1 can be down
- PDB should ensure `minAvailable >= quorum`

### For Cluster Mode (Sharding)

```yaml
# Bitnami valkey-cluster default
pdb:
  create: true
  minAvailable: ""
  maxUnavailable: ""
  # When both empty, defaults to maxUnavailable: 1
```

**Cluster mode considerations**:
- Each shard must have at least one available node to serve its hash slots
- If a primary and all its replicas are down, that shard's slots are unavailable
- `maxUnavailable: 1` globally may be too restrictive for large clusters
- Consider per-shard PDBs or `maxUnavailable` as a percentage

### Production Recommendations

1. **Always create PDBs** - Protects against accidental mass eviction during node drains
2. **Use `maxUnavailable` over `minAvailable`** - Scales better, doesn't block cluster autoscaler
3. **Account for rolling updates** - A rolling update + node drain can violate PDB if both affect the same pods
4. **Test PDB with drain** - Run `kubectl drain --dry-run=client` to verify

---

## 8. Cloud Provider Specific Guidance

### Amazon EKS

**Storage**:
```yaml
# gp3 StorageClass (EKS default since 1.23+)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: valkey-storage
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"           # Tune for write-heavy workloads
  throughput: "250"      # MiB/s
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

**Networking**:
- Use `topologySpreadConstraints` to spread across AZs
- For cross-AZ replication, be aware of data transfer costs
- Consider single-AZ deployment for latency-sensitive caches

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: valkey
```

**Node groups**: Dedicated node groups with `cache-optimized` instances (r6g, r7g for ARM or r6i, r7i for x86).

**Security**: Use IRSA (IAM Roles for Service Accounts) if Valkey needs AWS API access (e.g., for backup to S3).

### Google GKE

**Storage**:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: valkey-storage
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

**GKE Autopilot**: Works with Valkey, but:
- Cannot set sysctls (no `net.core.somaxconn` tuning)
- Security context is managed by Autopilot
- Resource requests are mandatory (Autopilot provisions based on requests)

**GKE Standard**:
- Use `n2-highmem` or `c3-highmem` machine types
- Enable Workload Identity for GCP API access

### Azure AKS

**Storage**:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: valkey-storage
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  cachingMode: ReadOnly    # Helps for read-heavy workloads
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

**AKS-specific**:
- Use dedicated node pools with `Standard_E*` or `Standard_L*` series
- Enable Azure CNI Overlay for better IP management
- Proximity placement groups for lowest inter-node latency

### Kernel Tuning (All Providers)

Valkey benefits from kernel tuning. Use init containers or sysctl settings:

```yaml
# Bitnami chart approach
podSecurityContext:
  sysctls:
    - name: net.core.somaxconn
      value: "10000"
```

For `transparent_hugepage` (cannot be set via sysctls):
```yaml
initContainers:
  - name: disable-thp
    image: busybox
    command: ['sh', '-c', 'echo never > /sys/kernel/mm/transparent_hugepage/enabled']
    securityContext:
      privileged: true
    volumeMounts:
      - name: sys
        mountPath: /sys
volumes:
  - name: sys
    hostPath:
      path: /sys
```

Note: This requires privileged containers, which conflicts with restricted Pod Security Standards. Some managed Kubernetes providers disable THP at the node level instead.

---

## 9. Production vs Development Patterns

### Development

```yaml
# Official chart - minimal dev setup
replica:
  enabled: false
dataStorage:
  enabled: false  # Ephemeral, data lost on restart
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 250m
    memory: 256Mi
```

### Production (Official Chart)

```yaml
replica:
  enabled: true
  replicas: 2
  disklessSync: false
  minReplicasToWrite: 1
  minReplicasMaxLag: 10
  persistence:
    size: 20Gi
    storageClass: "gp3"

auth:
  enabled: true
  usersExistingSecret: "valkey-credentials"
  aclUsers:
    default:
      permissions: "~* &* +@all"
    replication:
      permissions: "+psync +replconf +ping"
    app-user:
      permissions: "~app:* +@read +@write +@connection"

tls:
  enabled: true
  existingSecret: "valkey-tls"

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
  prometheusRule:
    enabled: true
    rules:
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 2m
        labels:
          severity: critical
      - alert: ValkeyMemoryHigh
        expr: >
          redis_memory_used_bytes * 100 /
          redis_memory_max_bytes > 90
        for: 5m
        labels:
          severity: warning

resources:
  requests:
    cpu: "1"
    memory: 2Gi
  limits:
    cpu: "2"
    memory: 4Gi

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: valkey
        topologyKey: kubernetes.io/hostname

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: valkey

valkeyConfig: |
  maxmemory 3gb
  maxmemory-policy allkeys-lru
  hz 100
  tcp-backlog 511
  timeout 300
```

### Production (Bitnami with Sentinel)

```yaml
architecture: replication

auth:
  enabled: true
  existingSecret: "valkey-credentials"

sentinel:
  enabled: true
  quorum: 2
  downAfterMilliseconds: 5000
  failoverTimeout: 60000

primary:
  resources:
    requests:
      cpu: "2"
      memory: 4Gi
    limits:
      cpu: "4"
      memory: 8Gi
  persistence:
    enabled: true
    size: 50Gi
    storageClass: "gp3"
  pdb:
    create: true
    minAvailable: 1

replica:
  replicaCount: 3
  resources:
    requests:
      cpu: "1"
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi
  persistence:
    enabled: true
    size: 50Gi
    storageClass: "gp3"
  pdb:
    create: true
    maxUnavailable: 1

tls:
  enabled: true
  existingSecret: "valkey-tls"

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

### Production (Hyperspike Operator - Cluster Mode)

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: production
spec:
  nodes: 3
  replicas: 1
  tls: true
  certIssuer: "letsencrypt-prod"
  certIssuerType: ClusterIssuer
  prometheus: true
  serviceMonitor: true
  anonymousAuth: false
  servicePassword:
    name: valkey-production-password
    key: password
  clusterDomain: cluster.local
  storage:
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: gp3
      resources:
        requests:
          storage: 20Gi
  resources:
    requests:
      cpu: "1"
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi
  nodeSelector:
    node-role: cache
  tolerations:
    - key: dedicated
      value: cache
      effect: NoSchedule
  externalAccess:
    enabled: true
    type: Proxy
    proxy:
      replicas: 2
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
```

---

## 10. Deployment Decision Matrix

### Which Tool to Use

| Requirement | Recommended | Why |
|------------|-------------|-----|
| Simple cache, dev/staging | Official Helm (standalone) | Lightweight, minimal config |
| HA with auto-failover | Bitnami Helm + Sentinel | Mature, well-tested Sentinel integration |
| Large dataset, multi-writer | Bitnami valkey-cluster or Hyperspike operator | Sharding distributes data |
| GitOps / operator pattern | Hyperspike or SAP operator | CRD-based, reconciliation loop |
| OpenShift | Bitnami (any) or Hyperspike | Both have OpenShift support |
| Cluster-internal with binding secret | SAP operator | Auto-generates connection secrets |
| External client access | Hyperspike (Envoy proxy) | Built-in external access with proxy |
| Need Valkey 9.x | Official Helm | Only chart shipping 9.0.1 |
| Enterprise support | Bitnami | Broadcom/VMware backing |

### Feature Comparison Summary

| Feature | Official | Bitnami | Bitnami Cluster | Hyperspike | SAP |
|---------|----------|---------|-----------------|------------|-----|
| Standalone | Y | Y | N | N | Y |
| Replication | Y | Y | N | N | Y |
| Sentinel | N | Y | N | N | Y |
| Cluster (sharding) | N | N | Y | Y | N |
| PDB | N | Y | Y | auto | auto |
| Metrics | Y | Y | Y | Y | Y |
| TLS | Y | Y | Y | Y | Y |
| cert-manager | N | N | N | Y | Y |
| Auth | ACL | password | password | password/anon | password |
| Network Policy | Y | Y | Y | N | N |
| OpenShift | N | Y | Y | Y | N |
| External Access | N | ExternalDNS | LB per node | Envoy/LB | N |
| Backup/Restore | N | N | N | N | N |
| VPA/HPA | N | Y | N | N | N |

---

## 11. Common K8s Gotchas for Valkey

1. **Memory overcommit kills** - Valkey fork (BGSAVE/BGREWRITEAOF) can double memory usage. Set memory limits to 2x the maxmemory setting, or disable fork-based persistence.

2. **OOMKilled during persistence** - When RDB snapshots or AOF rewrites trigger fork(), the copy-on-write pages can exceed the container memory limit. Solutions:
   - Use `appendonly yes` + `save ""` (AOF only, no RDB)
   - Set container memory limit > 2x `maxmemory`
   - Use `aof-use-rdb-preamble yes` for faster AOF rewrites

3. **Headless service must use publishNotReadyAddresses** - Without this, during pod restart, the old pod's DNS record is removed before the new pod is ready, breaking replication discovery.

4. **PVC stuck in Pending** - Usually a storage class issue. Check `storageClassName` matches a provisioner, `volumeBindingMode: WaitForFirstConsumer` is set, and the zone has capacity.

5. **Cluster mode gossip port** - Valkey cluster uses port 16379 (client port + 10000) for gossip. Ensure Network Policies allow this.

6. **Client redirection in cluster mode** - Clients must handle MOVED/ASK redirections. Use `-c` flag with `valkey-cli`. Application clients must use cluster-aware libraries.

7. **Split-brain with Sentinel** - Network partitions can cause Sentinel to elect a new primary while the old one is still accepting writes. Use `min-replicas-to-write` to mitigate.

8. **Volume expansion** - Expanding PVCs requires `allowVolumeExpansion: true` on the StorageClass. Some CSI drivers require pod restart after expansion.

9. **SecurityContext conflicts** - The official chart uses UID 1000, Bitnami uses 1001. Switching charts requires PVC permission fixes or an init container with `chown`.

10. **Termination grace period** - Default 30s may not be enough for large RDB saves. Increase `terminationGracePeriodSeconds` if Valkey needs time to flush data.
