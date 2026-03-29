# Kubernetes

Use when deploying Valkey on Kubernetes - choosing an operator, configuring StatefulSets, or integrating with service meshes and sidecars.

---

## Operator Landscape

### valkey-io/valkey-operator (Official)

The official Valkey Kubernetes operator, maintained by the Valkey project. Built with Kubebuilder.

**Status**: Early development - explicitly NOT ready for production. The README
states: "EARLY DEVELOPMENT NOTICE - This operator is in active development and
not ready for production use." No releases yet - no published container images or
Helm charts.

**Roadmap**: Tracked via "Road to Release: 1.0.0" with open design issues for
module handling, Persistent Volumes, safer cluster rolling updates, Config CRD
design, and container image publishing.

**Community**: Weekly tech calls Fridays 11:00-11:30 US Eastern via LF Zoom.
Slack channel: `#valkey-k8s-operator` on valkey.io/slack.

**CRD**: `ValkeyCluster` (API version `valkey.io/v1alpha1`)

```yaml
apiVersion: valkey.io/v1alpha1
kind: ValkeyCluster
metadata:
  name: my-cluster
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

**Supported topologies**:
- Cluster mode with configurable shard and replica counts
- Deployment workload type (StatefulSet is default)

**User management** via CRD:

```yaml
spec:
  users:
    - name: alice
      enabled: true
      passwordSecret:
        name: user-secrets
        keys: [alicepw]
      commands:
        allow: ["@read", "@write", "@connection"]
        deny: ["@admin", "@dangerous"]
      keys:
        readWrite: ["app:*", "cache:*"]
        readOnly: ["shared:*"]
```

**Installation**: Build from source and deploy with `make install && make deploy`. No published Helm chart or container image yet.

**Prerequisites**: Go 1.24.6+, Docker, kubectl, Kubernetes 1.11.3+.

### Hyperspike/valkey-operator (Community)

The most mature community operator. 302 stars (2x the official operator).
Latest release: v0.0.61 (2025-10-12). Supports cluster mode with TLS,
Prometheus monitoring (bundles redis_exporter v1.78.0), and cert-manager
integration. Container images are cosign-verified. Ships Valkey 8.1.4.

**CRD**: `Valkey` (API version `hyperspike.io/v1`)

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: my-valkey
spec:
  volumePermissions: true
```

**Installation**:

```bash
# Vanilla manifests
LATEST=$(curl -s https://api.github.com/repos/hyperspike/valkey-operator/releases/latest | jq -cr .tag_name)
curl -sL https://github.com/hyperspike/valkey-operator/releases/download/$LATEST/install.yaml | kubectl create -f -

# Helm
helm install valkey-operator \
  --namespace valkey-operator-system --create-namespace \
  oci://ghcr.io/hyperspike/valkey-operator \
  --version ${LATEST}-chart
```

**Features**: TLS via cert-manager, Prometheus ServiceMonitor, cosign-signed container images, quick-start with minikube.

**Image verification**:

```bash
cosign verify ghcr.io/hyperspike/valkey-operator:$LATEST \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/hyperspike/valkey-operator/.github/workflows/image.yaml@refs/tags/$LATEST
```

### Other Community Operators

| Operator | Description | Notes |
|----------|-------------|-------|
| **SAP/redis-operator** | Manages Redis/Valkey clusters on Kubernetes | Originally Redis-focused; works with Valkey via compatibility |
| **OT-CONTAINER-KIT/redis-operator** | Golang-based, supports standalone/cluster/replication/sentinel | 1300+ stars; Redis-native but compatible with Valkey images |

### Operator Selection Guide

| Scenario | Recommendation |
|----------|---------------|
| Production today | Hyperspike operator or Helm chart (no operator) |
| Want official support long-term | Watch valkey-io/valkey-operator; use Helm chart meanwhile |
| Need TLS + cert-manager | Hyperspike operator |
| Existing Redis operator in use | Continue with it; swap the image to `valkey/valkey` |

---

## Helm Charts (Brief)

The official Valkey Helm chart and Bitnami charts provide operator-free Kubernetes deployment. See the [Infrastructure as Code](iac.md) reference for full Helm documentation.

**Quick install**:

```bash
helm install valkey oci://registry-1.docker.io/valkeycharts/valkey \
  --set architecture=replication \
  --set replica.replicaCount=3
```

Helm is the recommended approach for production today, given that the official operator is still in early development.

---

## StatefulSet Patterns

When deploying without an operator, use StatefulSets for Valkey instances that need stable network identities and persistent storage.

### Key Elements

A Valkey StatefulSet needs:
- `serviceName` pointing to a headless Service (`clusterIP: None`)
- Container image pinned to exact patch (`valkey/valkey:9.0.3`)
- Volume mount at `/data` with a `volumeClaimTemplate` for per-pod PVCs
- Resource requests and limits for CPU and memory
- Readiness probe: `valkey-cli ping` (initialDelaySeconds: 5, periodSeconds: 10)
- Liveness probe: `valkey-cli ping` (initialDelaySeconds: 15, periodSeconds: 20)

Each pod gets a stable hostname (`valkey-0`, `valkey-1`, etc.) and is addressable as `valkey-0.valkey.namespace.svc.cluster.local`. PVCs persist across restarts. Set `podManagementPolicy: Parallel` for faster scaling (default is `OrderedReady`).

### PVC Sizing

| Use Case | Recommended Storage |
|----------|-------------------|
| Cache-only (no persistence) | No PVC needed; use emptyDir |
| RDB snapshots | 2-3x the expected dataset size |
| AOF persistence | 3-5x the expected dataset size |
| AOF + RDB combined | 5x the expected dataset size |

---

## Sidecar Patterns

### Prometheus Exporter Sidecar

Deploy `redis_exporter` as a sidecar for metrics collection:

```yaml
containers:
  - name: valkey
    image: valkey/valkey:9.0.3
    ports:
      - containerPort: 6379

  - name: exporter
    image: oliver006/redis_exporter:v1.78.0
    ports:
      - containerPort: 9121
        name: metrics
    env:
      - name: REDIS_ADDR
        value: "localhost:6379"
```

Pair with a PodMonitor or ServiceMonitor CRD for Prometheus Operator scraping. See the valkey-ecosystem guide (Section 4) for monitoring platform options.

### TLS Termination Sidecar

For environments where Valkey's built-in TLS is not suitable, deploy a TLS proxy sidecar (e.g., HAProxy or Envoy) that terminates TLS on a separate port and forwards plaintext to Valkey on localhost:6379. In most cases, Valkey's built-in TLS (compiled with OpenSSL in the official image) is sufficient. Valkey 9.1 adds automatic TLS certificate reload, reducing the need for sidecar-based cert rotation.

---

## Service Mesh Considerations

### Istio / Linkerd

Valkey uses a custom binary protocol (RESP), not HTTP. Service mesh integration requires:

- **TCP traffic routing** instead of HTTP-based routing
- **Disable protocol detection** for Valkey ports (Istio: set `appProtocol: tcp` on the Service port)
- **mTLS passthrough** - if Valkey already handles TLS, configure the mesh to skip encryption for Valkey traffic to avoid double encryption

Set `appProtocol: tcp` on the Service port definition to signal TCP routing.

### Cluster Mode in Service Mesh

Valkey Cluster uses a gossip bus on port 16379 (base port + 10000). Both the client port and the bus port must be accessible between cluster nodes. Ensure mesh policies allow inter-pod traffic on both ports.

---

## Cross-References

For deeper Kubernetes operational guidance, see the **valkey-ops** skill:
- `kubernetes/operators.md` - Detailed operator comparison and selection
- `kubernetes/statefulset.md` - Advanced StatefulSet configuration
- `kubernetes/helm.md` - Helm chart values and customization
- `kubernetes/tuning-k8s.md` - Kernel tuning and resource optimization for Kubernetes

---

## See Also

- [Infrastructure as Code](iac.md) - Helm charts and Terraform for Valkey on Kubernetes
- [Docker](docker.md) - Base image selection and tag pinning
- [Security](security.md) - TLS and ACL configuration
- **valkey-ops** skill - Production operations, monitoring, and troubleshooting
