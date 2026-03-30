# Kubernetes Manifest Summary

All manifests for the 3-primary, 3-replica Valkey cluster deployment.

## Files Overview

### Core Manifests

1. **valkey-cluster-namespace.yaml**
   - Creates `valkey-cluster` namespace
   - Isolates cluster resources

2. **valkey-cluster-secret.yaml**
   - Password secret: `valkeypassword123`
   - Used by all nodes for auth
   - Change password before production

3. **valkey-cluster-configmap.yaml**
   - Valkey configuration file
   - Cluster mode enabled
   - Module loading: `search.so`
   - TLS settings
   - Persistence: AOF enabled
   - Memory limit: 1Gi per node

4. **valkey-cluster-tls.yaml**
   - Base64-encoded TLS certificates
   - **IMPORTANT**: Replace with real certificates
   - Used for client and inter-node encryption
   - Run `generate-tls.sh` for self-signed certs

5. **valkey-cluster-service.yaml**
   - **Headless service** (valkey-cluster): DNS discovery
   - **LoadBalancer service** (valkey-lb): External access
   - Cluster port 16379 (gossip protocol)
   - Client port 6379 (TLS)

6. **valkey-cluster-statefulset.yaml**
   - Main deployment (6 replicas)
   - Init container for cluster auto-initialization
   - Startup/liveness/readiness probes
   - Pod anti-affinity for distribution
   - Resources: 1Gi mem request, 2Gi limit
   - PVC volumeClaimTemplate (20Gi per pod)

7. **valkey-cluster-pdb.yaml**
   - Pod Disruption Budget
   - Minimum 4 pods available during voluntary disruptions
   - Prevents cluster instability during node drains

8. **valkey-cluster-test-job.yaml**
   - Comprehensive validation job
   - Tests cluster health
   - Creates search index
   - Inserts JSON documents
   - Runs full-text queries
   - Verifies replication

### Utility Scripts

- **generate-tls.sh**: Generate self-signed certificates
- **deploy.sh**: One-shot deployment orchestration
- **DEPLOYMENT_GUIDE.md**: Step-by-step walkthrough
- **README.md**: Architecture and reference
- **MANIFEST_SUMMARY.md**: This file

## Deployment Order

1. Namespace creation (auto with first manifest)
2. Secrets and ConfigMaps
3. Services (headless + LB)
4. StatefulSet (6 pods start in parallel)
5. Pod Disruption Budget
6. Test Job

## Key Configuration Values

### StatefulSet (valkey-cluster-statefulset.yaml)

```yaml
replicas: 6                    # 3 primaries, 3 replicas
serviceName: valkey-cluster    # Headless service for discovery
updateStrategy: RollingUpdate  # Rolling restarts
podManagementPolicy: Parallel  # All pods start simultaneously
terminationGracePeriodSeconds: 60  # Allow clean shutdown
```

### Resource Limits (valkey-cluster-statefulset.yaml)

```yaml
requests:
  memory: 1Gi      # match maxmemory
  cpu: 500m
limits:
  memory: 2Gi      # 2x requests for fork headroom (no CPU limit)
```

### Health Probes (valkey-cluster-statefulset.yaml)

```yaml
startupProbe:           # First to run (5 min timeout)
  failureThreshold: 30  # 30 * 10s = 5 minutes

livenessProbe:          # Restart if unresponsive
  initialDelaySeconds: 30
  failureThreshold: 3   # 3 * 10s = 30s

readinessProbe:         # Remove from service
  initialDelaySeconds: 5
  failureThreshold: 3   # 3 * 5s = 15s
```

### Cluster Config (valkey-cluster-configmap.yaml)

```
cluster-enabled yes                  # Cluster mode
cluster-node-timeout 15000           # 15s PFAIL threshold
cluster-require-full-coverage no     # Cluster up if some slots down
cluster-replica-validity-factor 10   # Replica eligibility
maxmemory 1gb                        # Per-node limit
appendonly yes                       # AOF persistence
loadmodule /usr/lib/valkey/modules/search.so  # Search module
```

### TLS Config (valkey-cluster-configmap.yaml)

```
tls-port 6379
port 0                              # Disable plaintext
tls-cert-file /etc/valkey/tls/server.crt
tls-key-file /etc/valkey/tls/server.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
tls-cluster yes                     # Encrypt inter-node
tls-replication yes                 # Encrypt replication
tls-auth-clients no                 # Optional client certs
```

## Pod Initialization Sequence

### Pod 0 (valkey-0) - Cluster Creator

1. Init container waits for all 6 pods DNS-resolvable
2. Waits for all Valkey instances to respond PING
3. Executes `CLUSTER CREATE` with `--cluster-replicas 1`
4. Slots distributed:
   - P0: 0-5460 (5461 slots)
   - P1: 5461-10922 (5462 slots)
   - P2: 10923-16383 (5461 slots)
5. Nodes join cluster:
   - valkey-0,1,2 become primaries
   - valkey-3,4,5 become replicas

### Pods 1-5 (valkey-1 to valkey-5)

1. Init container waits for Pod 0 `cluster_state:ok`
2. Main container starts Valkey
3. Auto-joins cluster (cluster gossip)
4. Receives slot assignments
5. Replica pods sync from primary

## Storage

### PVC Template

```yaml
volumeClaimTemplates:
  - name: valkey-data
    accessModes: ["ReadWriteOnce"]
    storageClassName: standard    # Adjust per cluster
    resources:
      requests:
        storage: 20Gi
```

- **Per pod**: 1 PVC per StatefulSet pod
- **Lifecycle**: Persists after pod deletion (safety)
- **Mounting**: `/data` inside container
- **Reattach**: Reapplying StatefulSet reattaches to same PVC
- **Manual cleanup**: `kubectl delete pvc -l app=valkey`

### Storage Sizing

| Scenario | Size |
|----------|------|
| Cache-only (no persistence) | 2x maxmemory |
| Persistent (RDB) | 3x dataset size |
| Persistent (AOF) | 3x dataset size |
| Hybrid (AOF+RDB) | 4x dataset size |

For 1Gb maxmemory: 20Gi PVC is sufficient for AOF persistence.

## Pod Anti-Affinity

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        topologyKey: kubernetes.io/hostname  # Spread across nodes
      - weight: 50
        topologyKey: topology.kubernetes.io/zone  # Also spread zones
```

**Effect**: Kubernetes tries to place each pod on a different node/zone, but allows co-location if needed.

## Security Context

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 999            # valkey user
  runAsGroup: 999
  fsGroup: 999              # Data directory ownership
```

Init container runs as root to manage file permissions, main container as non-root.

## Service Types

### Headless Service (valkey-cluster)

```yaml
clusterIP: None
publishNotReadyAddresses: true  # DNS records even if not ready
```

- No load balancing
- DNS A record: `valkey-0.valkey-cluster.valkey-cluster.svc.cluster.local` → pod IP
- Used for cluster discovery during init

### LoadBalancer Service (valkey-lb)

```yaml
type: LoadBalancer
```

- External access to cluster
- Single entry point (load balances across primaries)
- Requires client cluster-aware routing for full topology

## Volume Mounts

| Mount | Source | Read-only | Purpose |
|-------|--------|-----------|---------|
| `/data` | PVC | No | Persistent data (RDB/AOF) |
| `/etc/valkey` | ConfigMap | Yes | Valkey configuration file |
| `/etc/valkey/tls` | Secret | Yes | TLS certificates and keys |

## Environment Variables

- Pod name: `$HOSTNAME` (used in init for cluster discovery)
- All passwords hardcoded in ConfigMap for init

## Resource Budget

For 6-pod cluster with 1Gi maxmemory each:

| Resource | Total | Note |
|----------|-------|------|
| Memory request | 6Gi | 1Gi x 6 pods |
| Memory limit | 12Gi | 2Gi x 6 pods |
| CPU request | 3 cores | 500m x 6 pods |
| CPU limit | unlimited | No throttling |
| Storage | 120Gi | 20Gi x 6 pods |

## Network Policy Considerations

If NetworkPolicy is enabled, allow:
- Pod-to-pod on port 6379 (client)
- Pod-to-pod on port 16379 (cluster bus)
- Pod-to-external DNS (53/TCP+UDP)
- Pod-to-LoadBalancer

## Readiness Implications

Test job waits for:
1. All pods in Running state
2. Cluster state = `ok`
3. All 6 nodes known
4. All 16384 slots assigned

Only then does it proceed with module tests.

## Troubleshooting Checklist

| Issue | Check |
|-------|-------|
| Pods pending | Node capacity, PVC availability, image pull |
| Init container hung | Logs: `kubectl logs POD -c cluster-init` |
| Cluster state FAIL | `CLUSTER INFO` output, PFAIL nodes |
| TLS errors | Secret exists, mounts correct, certs valid |
| OOMKilled | Memory usage vs limit, maxmemory tuning |
| Replication lag | `INFO replication`, network latency |

See DEPLOYMENT_GUIDE.md for full troubleshooting section.
