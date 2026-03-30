# Quick Reference Card

## One-Liner Deployment

```bash
bash generate-tls.sh && kubectl create ns valkey-cluster && \
  kubectl create secret generic valkey-tls \
    --from-file=ca.crt=tls-certs/ca.crt \
    --from-file=server.crt=tls-certs/server.crt \
    --from-file=server.key=tls-certs/server.key \
    -n valkey-cluster && \
  kubectl apply -f valkey-cluster-*.yaml && \
  kubectl rollout status sts/valkey -n valkey-cluster --timeout=5m
```

Or use orchestration script:

```bash
bash deploy.sh
```

## Essential Commands

### Check Status

```bash
# All pods
kubectl get pods -n valkey-cluster

# StatefulSet rollout
kubectl rollout status sts/valkey -n valkey-cluster --timeout=5m

# PVCs
kubectl get pvc -n valkey-cluster

# Services
kubectl get svc -n valkey-cluster
```

### Connect to Cluster

```bash
# Interactive shell to primary
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  -c  # cluster mode

# From pod name
POD=valkey-0
kubectl exec -it $POD -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  PING
```

### Cluster Info

```bash
# Cluster state
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  CLUSTER INFO

# All nodes
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  CLUSTER NODES

# Memory usage
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  INFO memory | grep used_memory
```

### Module Status

```bash
# Load search module
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  MODULE LIST
```

### Logs

```bash
# Main container
kubectl logs valkey-0 -n valkey-cluster

# Init container
kubectl logs valkey-0 -n valkey-cluster -c cluster-init

# Follow real-time
kubectl logs -f valkey-0 -n valkey-cluster

# Last 50 lines
kubectl logs valkey-0 -n valkey-cluster --tail=50
```

### Troubleshooting

```bash
# Pod details and events
kubectl describe pod valkey-0 -n valkey-cluster

# Port forward for direct connection
kubectl port-forward valkey-0 6379:6379 -n valkey-cluster &
valkey-cli --tls --cacert ca.crt -a valkeypassword123 -p 6379 PING

# Check PVC
kubectl describe pvc valkey-data-valkey-0 -n valkey-cluster

# Test job logs
kubectl logs job/valkey-cluster-test -n valkey-cluster

# Test job details
kubectl describe job valkey-cluster-test -n valkey-cluster
```

## Key Passwords and Ports

| Item | Value |
|------|-------|
| Namespace | valkey-cluster |
| Password | valkeypassword123 |
| Client port | 6379 (TLS) |
| Cluster bus port | 16379 (TLS) |
| Service DNS | valkey-lb.valkey-cluster.svc.cluster.local |
| StatefulSet name | valkey |

## File Checklist

```
Required files for deployment:
  [x] valkey-cluster-namespace.yaml
  [x] valkey-cluster-secret.yaml
  [x] valkey-cluster-configmap.yaml
  [x] valkey-cluster-service.yaml
  [x] valkey-cluster-statefulset.yaml
  [x] valkey-cluster-pdb.yaml
  [x] valkey-cluster-test-job.yaml
  [x] generate-tls.sh
  [x] deploy.sh
  [x] README.md
  [x] DEPLOYMENT_GUIDE.md
  [x] MANIFEST_SUMMARY.md
  [x] QUICK_REFERENCE.md (this file)

Generated during setup:
  [x] tls-certs/ca.key
  [x] tls-certs/ca.crt
  [x] tls-certs/server.key
  [x] tls-certs/server.crt
```

## Common Modifications

### Change Password

```bash
# Edit secret
kubectl edit secret valkey-secret -n valkey-cluster

# Update ConfigMap
kubectl edit configmap valkey-config -n valkey-cluster
# Change: requirepass, masterauth

# Restart pods to apply
kubectl delete pods -l app=valkey -n valkey-cluster
```

### Increase Memory Limit

```bash
# Edit StatefulSet
kubectl edit sts valkey -n valkey-cluster

# Under resources.limits.memory:
# Change: 2Gi → 4Gi (or desired value)

# Rolling restart
kubectl rollout restart sts/valkey -n valkey-cluster
kubectl rollout status sts/valkey -n valkey-cluster --timeout=5m
```

### Expand Storage

```bash
# Enable volume expansion on StorageClass
kubectl patch storageclass standard -p '{"allowVolumeExpansion": true}'

# Update PVC (e.g., 20Gi → 50Gi)
kubectl patch pvc valkey-data-valkey-0 -n valkey-cluster \
  -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

# Verify in Valkey
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  INFO server | grep dir
```

### Update Configuration

```bash
# Edit ConfigMap
kubectl edit configmap valkey-config -n valkey-cluster

# Roll restart to apply
kubectl rollout restart sts/valkey -n valkey-cluster

# Verify new config
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  CONFIG GET maxmemory
```

## Search Module Examples

### Create Index

```bash
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  FT.CREATE products-idx ON JSON \
  SCHEMA \
  '$.name' AS name TEXT \
  '$.price' AS price NUMERIC
```

### Insert Document

```bash
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  JSON.SET product:1 '$' '{"name":"Widget","price":19.99}'
```

### Search

```bash
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  FT.SEARCH products-idx "widget" LIMIT 0 10
```

## Metrics to Monitor

```bash
# Cluster health
CLUSTER_STATE=$(kubectl exec valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  CLUSTER INFO | grep cluster_state)

# Nodes
NODES=$(kubectl exec valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  CLUSTER INFO | grep cluster_known_nodes)

# Memory per node
MEM=$(kubectl exec valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  INFO memory | grep used_memory_rss)

echo "$CLUSTER_STATE | $NODES | $MEM"
```

## Cleanup

```bash
# Delete namespace (including all pods, services, pvc)
kubectl delete namespace valkey-cluster

# Note: PVCs persist after namespace deletion (safety feature)
# Manual cleanup if needed:
kubectl delete pvc -l app=valkey -n valkey-cluster

# Remove TLS certificates
rm -rf tls-certs/
```

## Performance Baseline

After deployment, baseline metrics:

```bash
# Connect and get baseline
valkey-cli -c -h <LOADBALANCER_IP> --tls --cacert ca.crt -a valkeypassword123

> INFO stats
> INFO replication
> CLUSTER INFO

# Typical healthy state:
# - cluster_state:ok
# - cluster_slots_assigned:16384
# - connected_clients: 1+ per connection
# - instantaneous_ops_per_sec: varies with load
# - master_repl_offset: increasing with writes
```

## Health Check Signals

| Signal | Expected Value | Action |
|--------|----------------|--------|
| Pods Ready | 6/6 | [OK] Cluster ready |
| cluster_state | ok | [OK] All slots covered |
| cluster_known_nodes | 6 | [OK] Full topology |
| cluster_size | 3 | [OK] 3 primaries |
| Replication lag | < 1s | [OK] All replicas synced |
| Memory usage | < maxmemory | [OK] Within limits |

## Emergency Restart

If cluster becomes unresponsive:

```bash
# Kill all pods (clean restart)
kubectl delete pods -l app=valkey -n valkey-cluster

# Wait for StatefulSet to restart
kubectl wait --for=condition=ready pod -l app=valkey -n valkey-cluster --timeout=300s

# Verify recovery
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  CLUSTER INFO
```

Cluster auto-recovers from PVC data on restart.
