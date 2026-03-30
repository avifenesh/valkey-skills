# Valkey Cluster Kubernetes Deployment Guide

3-primary, 3-replica cluster with valkey-search module, TLS, persistent storage, and auto-initialization.

## Architecture

- 6-node cluster (3 primaries, 3 replicas) with automatic failover
- Hash slot distribution: 5461 slots per primary (16384 total)
- TLS encryption on all traffic (client, replication, cluster bus)
- Plaintext port disabled (`port 0`)
- Persistent storage via StatefulSet volumeClaimTemplates (10Gi per pod)
- valkey-search module loaded via valkey-bundle image
- AOF persistence with everysec fsync
- Health probes: startup (5m window), liveness (30s), readiness (cluster_state check)
- Pod anti-affinity across nodes and zones
- Pod Disruption Budget (`maxUnavailable: 1`)

## Prerequisites

1. Kubernetes 1.23+ cluster with at least 3 nodes (for anti-affinity)
2. StorageClass named `standard` (edit `valkey-cluster-statefulset.yaml` if yours differs)
3. OpenSSL for TLS certificate generation
4. kubectl configured for target cluster

## Quick Deploy (Automated)

The `deploy.sh` script handles everything - cert generation, manifest application, cluster init, and validation:

```bash
bash deploy.sh
```

## Manual Deploy (Step by Step)

### Step 1: Generate TLS Certificates

```bash
bash generate-tls.sh
```

This creates `tls-certs/` with `ca.crt`, `server.crt`, and `server.key`. The server certificate includes SAN extensions for `*.valkey-cluster.valkey-cluster.svc.cluster.local` so all pod DNS names are covered.

For production: replace with certificates from your PKI or cert-manager.

### Step 2: Create Namespace and Secrets

```bash
kubectl apply -f valkey-cluster-namespace.yaml

# Load generated TLS certificates into a Secret
kubectl create secret generic valkey-tls \
  --from-file=ca.crt=tls-certs/ca.crt \
  --from-file=server.crt=tls-certs/server.crt \
  --from-file=server.key=tls-certs/server.key \
  -n valkey-cluster

# Create auth password Secret
kubectl apply -f valkey-cluster-secret.yaml
```

### Step 3: Deploy Core Manifests

```bash
kubectl apply -f valkey-cluster-configmap.yaml
kubectl apply -f valkey-cluster-service.yaml
kubectl apply -f valkey-cluster-statefulset.yaml
kubectl apply -f valkey-cluster-pdb.yaml
```

### Step 4: Wait for Pods

The readiness probe checks `cluster_state:ok`, so pods will not become Ready until the cluster is initialized. Wait for pods to reach Running phase instead:

```bash
for i in 0 1 2 3 4 5; do
  kubectl wait --for=jsonpath='{.status.phase}'=Running \
    pod/valkey-$i -n valkey-cluster --timeout=300s
done
```

### Step 5: Initialize the Cluster

```bash
kubectl apply -f valkey-cluster-init-job.yaml
kubectl wait --for=condition=complete job/valkey-cluster-init \
  -n valkey-cluster --timeout=300s
kubectl logs job/valkey-cluster-init -n valkey-cluster
```

The init job is idempotent - it exits cleanly if the cluster is already formed.

### Step 6: Run Validation Tests

```bash
kubectl apply -f valkey-cluster-test-job.yaml
kubectl wait --for=condition=complete job/valkey-cluster-test \
  -n valkey-cluster --timeout=300s
kubectl logs job/valkey-cluster-test -n valkey-cluster
```

Expected output:

```
=== Cluster Health ===
[OK] cluster_state is ok
[OK] 6 nodes in cluster
[OK] 16384 slots assigned
=== Search Module ===
[OK] valkey-search module loaded
=== Search Index ===
[OK] FT.CREATE test-idx
=== Insert Documents ===
[OK] Inserted 5 documents
=== Full-Text Search ===
[OK] FT.SEARCH @title:Valkey returned 2 results (expected >= 2)
=== Tag Search ===
[OK] FT.SEARCH @category:{tutorial} returned 2 results (expected >= 2)
=== Numeric Range Search ===
[OK] FT.SEARCH @price:[0 5] returned 2 results (expected >= 2)
=== Combined Query ===
[OK] Combined tag+numeric query returned 2 results
=== TLS ===
[OK] Plaintext port disabled (tcp_port:0)
=== Results ===
9/9 passed
[OK] All tests passed
```

## Manifest Files

| File | Purpose |
|------|---------|
| `valkey-cluster-namespace.yaml` | Namespace `valkey-cluster` |
| `valkey-cluster-secret.yaml` | Auth password (change for production) |
| `valkey-cluster-tls.yaml` | TLS Secret reference template (not applied directly) |
| `valkey-cluster-configmap.yaml` | valkey.conf with cluster, TLS, and search module config |
| `valkey-cluster-service.yaml` | Headless service (pod DNS) + ClusterIP client service |
| `valkey-cluster-statefulset.yaml` | 6-replica StatefulSet with PVCs, probes, anti-affinity |
| `valkey-cluster-pdb.yaml` | Pod Disruption Budget (`maxUnavailable: 1`) |
| `valkey-cluster-init-job.yaml` | One-time cluster formation (idempotent) |
| `valkey-cluster-test-job.yaml` | Validation - cluster health, search index, queries |
| `generate-tls.sh` | Self-signed TLS certificate generator |
| `deploy.sh` | Automated end-to-end deployment script |

## Client Connection

### In-Cluster

Cluster-aware client using the headless service for discovery:

```bash
kubectl exec -it valkey-0 -n valkey-cluster -- \
  valkey-cli -c --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123
```

Or through the client service (entry point, clients still handle MOVED/ASK redirects):

```bash
valkey-cli -c --tls --cacert ca.crt \
  -h valkey-client.valkey-cluster.svc.cluster.local \
  -a valkeypassword123
```

### Port Forward (Development)

```bash
kubectl port-forward svc/valkey-client 6379:6379 -n valkey-cluster
valkey-cli -c --tls --cacert tls-certs/ca.crt -a valkeypassword123
```

## Monitoring

```bash
# Cluster state
kubectl exec valkey-0 -n valkey-cluster -- \
  valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 CLUSTER INFO

# Node topology
kubectl exec valkey-0 -n valkey-cluster -- \
  valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 CLUSTER NODES

# Memory usage
kubectl exec valkey-0 -n valkey-cluster -- \
  valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 INFO memory

# Search indexes
kubectl exec valkey-0 -n valkey-cluster -- \
  valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 FT._LIST
```

## Production Hardening

Before deploying to production, address these items:

1. **Change the auth password** in `valkey-cluster-secret.yaml` and `valkey-cluster-configmap.yaml`
2. **Use cert-manager or your PKI** instead of self-signed certificates
3. **Set `tls-auth-clients yes`** in the ConfigMap for mutual TLS
4. **Adjust `maxmemory`** in the ConfigMap to match your pod memory requests
5. **Add NetworkPolicy** to restrict traffic to the valkey-cluster namespace
6. **Use a production StorageClass** - replace `standard` with your SSD-backed class
7. **Increase PVC size** based on your dataset (current: 10Gi, rule: 3x dataset for AOF)
8. **Add Prometheus exporter** sidecar for observability
9. **Configure ACL users** instead of a shared password

## Cleanup

```bash
# Delete everything except PVCs
kubectl delete namespace valkey-cluster

# Delete PVCs manually (safety feature - not auto-deleted)
kubectl delete pvc -l app=valkey -n valkey-cluster
```
