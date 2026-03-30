#!/bin/bash
# Deploy a 3-primary 3-replica Valkey cluster with TLS and valkey-search.
# Usage: bash deploy.sh

set -e

log() { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }
die() { echo "[ERROR] $1"; exit 1; }

NAMESPACE="valkey-cluster"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# --- Prerequisites ---
log "Checking prerequisites..."
command -v kubectl > /dev/null || die "kubectl not found"
command -v openssl > /dev/null || die "openssl not found"

# --- TLS certificates ---
if [ -f tls-certs/ca.crt ] && [ -f tls-certs/server.crt ] && [ -f tls-certs/server.key ]; then
  warn "TLS certificates already exist in tls-certs/, skipping generation"
else
  log "Generating TLS certificates..."
  bash generate-tls.sh
fi

# --- Namespace ---
if kubectl get ns "$NAMESPACE" > /dev/null 2>&1; then
  warn "Namespace $NAMESPACE already exists"
else
  log "Creating namespace..."
  kubectl apply -f valkey-cluster-namespace.yaml
fi

# --- TLS secret (from generated certs, not the template yaml) ---
log "Creating TLS secret from generated certificates..."
kubectl create secret generic valkey-tls \
  --from-file=ca.crt=tls-certs/ca.crt \
  --from-file=server.crt=tls-certs/server.crt \
  --from-file=server.key=tls-certs/server.key \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Core manifests ---
log "Applying manifests..."
kubectl apply -f valkey-cluster-secret.yaml
kubectl apply -f valkey-cluster-configmap.yaml
kubectl apply -f valkey-cluster-service.yaml
kubectl apply -f valkey-cluster-statefulset.yaml
kubectl apply -f valkey-cluster-pdb.yaml

# --- Wait for pods ---
# Do NOT use "rollout status" here - it waits for Ready, but the readiness
# probe checks cluster_state:ok which requires the init job below. Instead,
# wait for each pod to reach the Running phase (containers started, PING works).
log "Waiting for all 6 pods to reach Running phase..."
for i in 0 1 2 3 4 5; do
  kubectl wait --for=jsonpath='{.status.phase}'=Running \
    pod/valkey-$i -n "$NAMESPACE" --timeout=300s
  echo "  valkey-$i: running"
done

# --- Cluster initialization ---
log "Applying cluster-init Job..."
kubectl delete job valkey-cluster-init -n "$NAMESPACE" 2>/dev/null || true
kubectl apply -f valkey-cluster-init-job.yaml

log "Waiting for cluster initialization (timeout: 5m)..."
kubectl wait --for=condition=complete job/valkey-cluster-init -n "$NAMESPACE" --timeout=300s

log "Cluster init logs:"
kubectl logs job/valkey-cluster-init -n "$NAMESPACE"

# --- Validation ---
log "Running test Job..."
kubectl delete job valkey-cluster-test -n "$NAMESPACE" 2>/dev/null || true
kubectl apply -f valkey-cluster-test-job.yaml

log "Waiting for tests (timeout: 5m)..."
kubectl wait --for=condition=complete job/valkey-cluster-test -n "$NAMESPACE" --timeout=300s

echo ""
echo "=== Test Results ==="
kubectl logs job/valkey-cluster-test -n "$NAMESPACE"

# --- Summary ---
echo ""
echo "========================================"
echo " Valkey Cluster Deployed"
echo "========================================"
echo ""
echo " Namespace:  $NAMESPACE"
echo " Topology:   3 primaries + 3 replicas"
echo " TLS:        enabled (replication + cluster bus)"
echo " Module:     valkey-search"
echo ""
echo " Connect (in-cluster):"
echo "   valkey-cli -c --tls --cacert ca.crt \\"
echo "     -a valkeypassword123 \\"
echo "     -h valkey-client.$NAMESPACE.svc.cluster.local"
echo ""
echo " Monitor:"
echo "   kubectl get pods -n $NAMESPACE -w"
echo "   kubectl exec valkey-0 -n $NAMESPACE -- \\"
echo "     valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \\"
echo "     -a valkeypassword123 CLUSTER INFO"
echo ""
echo "========================================"
