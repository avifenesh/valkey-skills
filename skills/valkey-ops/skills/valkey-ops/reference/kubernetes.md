# Kubernetes

Use when picking a Helm chart, operator, or rolling your own StatefulSet for Valkey on Kubernetes. Generic K8s + prereqs (`vm.overcommit_memory=1`, `net.core.somaxconn=65535`, THP `never`, SSD-backed PVC) apply - this file covers what's Valkey-specific.

## Helm charts

| | Official (`valkey/valkey`) | Bitnami (`oci://registry-1.docker.io/bitnamicharts/valkey` + `valkey-cluster`) |
|---|---|---|
| Architectures | standalone, replication | standalone, replication, Sentinel, cluster |
| Cluster mode | no | yes (separate `valkey-cluster` chart) |
| Sentinel | no | yes |
| PDB | manual | default enabled |
| Auth default | disabled | random password generated |
| Persistence default | disabled | 8Gi PVC enabled |
| ACL-first | yes | password-first (ACL optional) |
| Replica autoscaling (HPA/VPA) | no | yes |
| OpenShift SCC auto-adapt | no | yes |
| Base image | `valkey/valkey` (upstream) | `bitnami/valkey` (hardened, non-root) |
| Chart license | BSD-3-Clause | Apache-2.0 |
| Exporter sidecar | `redis_exporter` | `redis_exporter` |

Pick **official** for clean upstream defaults with ACL auth; pick **Bitnami** when you need cluster mode, Sentinel, hardened images, or built-in ServiceMonitor / autoscaling.

### Production values (both charts)

```yaml
persistence:
  size: 10Gi            # 2x expected dataset
  storageClass: fast-ssd

resources:
  requests: { memory: 2Gi, cpu: 500m }
  limits:
    memory: 4Gi         # 2x requests - fork COW headroom
    # no cpu limit - CFS throttling spikes tail latency

pdb:
  enabled: true
  maxUnavailable: 1     # never 0 - blocks drains

podAntiAffinity: soft   # hard = strict spread but can't schedule on small clusters

valkeyConfig: |
  maxmemory 2gb
  maxmemory-policy allkeys-lru
  appendonly yes
  aof-use-rdb-preamble yes
  tcp-keepalive 300
```

**Memory limit must exceed `maxmemory` by fork RSS headroom.** AOF rewrite or BGSAVE on write-heavy datasets makes child RSS approach 2× parent - sizing the K8s limit below that triggers OOMKill during snapshots.

### Migrating Bitnami → Official

In-place upgrade doesn't work (StatefulSet names, labels, and PVC claims differ). Treat as replica-promote:

1. Deploy the official chart alongside the Bitnami release.
2. Point the new instance at the Bitnami primary via `replicaof` + `primaryauth`.
3. Wait for `master_link_status:up` and `master_sync_in_progress:0`.
4. Promote (`REPLICAOF NO ONE`), switch app endpoints.
5. `helm uninstall` the Bitnami release once traffic drains.

Bitnami values use `master:` / `replica:` as root; official uses `primary:` / `replica:`. Value files can't be copied 1:1.

## Operators

Three Valkey-aware options:

| | Official (`valkey-io/valkey-operator`) | Hyperspike (`hyperspike/valkey-operator`) | SAP (`sap/valkey-operator`) |
|---|---|---|---|
| API | `valkey.io/v1alpha1` | `hyperspike.io/v1` | `cache.cs.sap.com/v1alpha1` |
| Modes | cluster only | standalone / Sentinel / cluster | Sentinel / static primary |
| CRD | `ValkeyCluster` | `Valkey` (short: `vk`) | `Valkey` |
| TLS | **not yet** | cert-manager | cert-manager |
| External access | **not yet** | Envoy proxy or per-shard LB | none |
| OpenShift | not yet | `platformManagedSecurityContext` | no |
| Prometheus | exporter sidecar (default) | ServiceMonitor | ServiceMonitor + PrometheusRule |
| Declarative ACL users | yes (commands/keys/channels/patterns) | no | no |
| Workload type | StatefulSet or Deployment (immutable) | StatefulSet | Bitnami Helm chart |
| Install | `make deploy` from source | Helm or single-YAML | Helm or kubectl |
| Maturity | early (WIP, breaking changes) | pre-1.0 community | SAP-maintained |

### Decision matrix

| Scenario | Pick |
|----------|------|
| Production cluster mode with sharding today | Hyperspike |
| Sentinel HA, no sharding, enterprise support | SAP |
| Declarative ACL users in the CRD | Official |
| Stable upstream Valkey project alignment | Official (once past `v1alpha1`) |
| Need Bitnami image hardening as runtime | SAP |
| OpenShift with SCC constraints | Hyperspike |

### Known gaps

- **Official**: no TLS, no persistence config, no backup/restore, no standalone/Sentinel modes, no Helm install chart yet. `v1alpha1` - expect breaking upgrades.
- **Hyperspike**: `replicas` field creates extra primary nodes rather than per-shard replicas (use `clusterReplicas` for replicas-per-primary). No backup/restore.
- **SAP**: Sentinel-focused, no cluster support.

### Operator vs Helm

Operators own day-2 (declarative failover, scaling, cert rotation, ACL sync, resharding). Helm owns day-1. If you want GitOps for topology changes, the operator path pays for itself; if the cluster is static and you manage day-2 out-of-band, Helm is simpler.

### CRD shapes - read from the cluster

```sh
kubectl explain valkeycluster.spec --recursive    # official
kubectl explain valkey.spec --recursive           # hyperspike or SAP
```

Every one has: `shards`/`replicas` (or `clusterReplicas`), `resources`, `storage`, `tls` (where supported). See each operator's `config/samples/` for golden configs. Official also exposes `workloadType: StatefulSet | Deployment` (immutable) and `users[]` for ACL rules.

### SAP operator specifics

SAP wraps the Bitnami Helm chart with operator lifecycle management:

```sh
helm repo add sap https://sap.github.io/valkey-operator/
helm install valkey-operator sap/valkey-operator
```

CRD (`kind: Valkey`): `spec.replicas`, `spec.sentinel.enabled` (Sentinel vs static primary), `spec.tls.enabled` (cert-manager), `spec.persistence`. Auto-generates a binding Secret (host, port, password, CA cert, sentinel config) customizable via Go templates. Ships ServiceMonitor + PrometheusRule. Auto-generates topology-spread constraints when not specified.

**`spec.sentinel.enabled` is immutable after creation** - can't toggle Sentinel mode on existing deployment.

Static-primary mode (no Sentinel) makes the first pod the primary with no automatic failover. Rarely what you want in prod.

### Day-2 commands

```sh
# Official: scale shards/replicas
kubectl patch valkeycluster my-cluster --type merge \
  -p '{"spec":{"shards":6,"replicas":2}}'

# Hyperspike: scale cluster mode
kubectl patch valkey my-cluster --type merge \
  -p '{"spec":{"replicas":9,"clusterReplicas":1}}'

# SAP: scale replicas
kubectl patch valkey my-valkey --type merge \
  -p '{"spec":{"replicas":5}}'

# Any operator: bump image version
kubectl patch valkey my-cluster --type merge \
  -p '{"spec":{"image":"valkey/valkey:9.0.3"}}'
```

All operators translate CRD changes into rolling upgrades. Watch via operator logs and CR status.

### Health check

```sh
kubectl get <kind>                          # status: Ready / Reconciling / Degraded
kubectl describe <kind> <name>              # conditions: Ready / Progressing / Degraded / ClusterFormed / SlotsAssigned
kubectl logs -n <operator-ns> deploy/<controller>
```

Controller-manager deployment name differs per operator.

## Raw StatefulSet

### Image and probes

- Image: `valkey/valkey:9`
- Health probe: `["valkey-cli", "ping"]` (not `redis-cli`)
- Security context UID: 999 (official image); Bitnami uses 1001
- Data mountPath: `/data`
- Config mountPath: `/etc/valkey`

### Minimal example

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: valkey }
spec:
  serviceName: valkey
  replicas: 3
  selector: { matchLabels: { app: valkey } }
  template:
    metadata: { labels: { app: valkey } }
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

### Resource sizing

```yaml
resources:
  requests:
    memory: 2Gi     # match maxmemory
    cpu: 500m
  limits:
    memory: 4Gi     # 2x requests for fork COW
    # no CPU limit - avoids CFS throttling latency spikes
```

When using `io-threads N`, set CPU requests `≥ N * 250m`.

### Replica readiness probe

```yaml
readinessProbe:
  exec:
    command: ["sh", "-c", "valkey-cli -a $PASSWORD INFO replication | grep -q master_link_status:up"]
```

### PVC sizing

| Workload | Size |
|----------|------|
| Cache-only | 2× maxmemory |
| RDB only | 3× dataset |
| AOF + RDB (hybrid) | 4× dataset |

**PVCs created by StatefulSets are NOT deleted when the StatefulSet is deleted** - manual cleanup required.

### Gotchas

- **OOMKilled during persistence**: fork doubles memory - set memory limit > 2× `maxmemory`.
- **UID conflicts**: official UID 999, Bitnami UID 1001. Switching charts requires PVC permission fixes.
- **Cluster gossip port**: 16379 must be allowed in NetworkPolicies.
- **Split-brain with Sentinel**: use `min-replicas-to-write 1`.
- **Termination grace period**: increase for large datasets - default 30s may not allow RDB save.
- **Headless service**: use `publishNotReadyAddresses: true` or DNS drops during pod restart break replication.

## Cluster gossip under NAT

Valkey cluster gossip advertises `<ip>:<port>:<bus-port>`. Bus port is always `port + 10000`. A pod listening on 6379 also needs 16379 reachable from every other cluster node. Any NAT or Service remapping breaks the protocol.

Three fixes:

- **`hostNetwork: true`** - simplest, limits one Valkey pod per node, bypasses NetworkPolicy. Fine for dedicated nodes.
- **`cluster-announce-*` overrides**:

  ```sh
  valkey-server /etc/valkey/valkey.conf \
      --cluster-announce-ip   $(hostname -i) \
      --cluster-announce-port 6379 \
      --cluster-announce-bus-port 16379
  ```

  Put in a StatefulSet init script; pod-ip discovery with `hostname -i` is stable because Valkey's pods are stateful.

- **Operator-managed** - Hyperspike/SAP inject announce-* values for you.

Sentinel mode doesn't have the bus port problem - `sentinel announce-ip` / `announce-port` plus a standard ClusterIP Service is enough. Use Sentinel over cluster mode when K8s networking makes bus routing painful.

## GKE Autopilot

Autopilot blocks `securityContext.sysctls` (no `net.core.somaxconn` bump, no THP disable), forbids privileged init containers, mandates resource requests. Net effect: default sysctls only, BGSAVE fork behavior unpredictable on large datasets. **For production Valkey on GKE, use Standard clusters.**

## Exporter sidecar

`redis_exporter` as a sidecar talks to Valkey over `localhost`:

```yaml
- name: exporter
  image: oliver006/redis_exporter:latest
  env:
    - { name: REDIS_ADDR, value: "redis://localhost:6379" }
  resources:
    requests: { memory: 64Mi, cpu: 50m }
    limits:   { memory: 128Mi }
```

`REDIS_ADDR` accepts `valkey://` too, but `redis://localhost:6379` is what every operator emits by default. ServiceMonitor / alert-rule plumbing is identical to Redis; use the Grafana Redis dashboards (`11835`, `763`). See `monitoring.md` for Valkey-only metrics beyond the standard panels.
