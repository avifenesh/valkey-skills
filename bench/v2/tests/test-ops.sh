#!/bin/bash
# Validates Task 3 (ops cluster) - deploys to kind and verifies
# Input: $1 = directory containing agent's manifests and scripts

DIR="$1"
PASS=0
FAIL=0
TOTAL=9

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" -eq 1 ]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Task 3: Ops Cluster Validation ==="

cd "$DIR"

# Clean any leftover kind cluster from previous runs
kind delete cluster --name bench-ops 2>/dev/null || true

# --- Static checks (3) ---

ALL_FILES=$(find "$DIR" \( -name "*.yaml" -o -name "*.yml" -o -name "*.sh" -o -name "*.conf" \) ! -name "docker-compose.yml" -exec cat {} + 2>/dev/null)
YAMLS=$(find "$DIR" -name "*.yaml" -o -name "*.yml" | grep -v docker-compose | xargs cat 2>/dev/null)

yaml_count=$(find "$DIR" -name "*.yaml" -o -name "*.yml" | grep -v docker-compose | wc -l)
check "YAML files present ($yaml_count)" "$([ "$yaml_count" -gt 0 ] && echo 1 || echo 0)"

has_search=$(echo "$ALL_FILES" | grep -ci "loadmodule.*search\|search\.so\|valkey-search" || true)
check "valkey-search module referenced" "$([ "$has_search" -gt 0 ] && echo 1 || echo 0)"

has_acl=$(echo "$ALL_FILES" | grep -ci "user app\|user admin\|user monitor\|aclfile\|ACL SETUSER" || true)
check "ACL users defined" "$([ "$has_acl" -gt 0 ] && echo 1 || echo 0)"

# --- Runtime checks (6) ---

# Find deploy script
DEPLOY_SCRIPT=""
for s in deploy.sh setup.sh install.sh run.sh; do
  [ -f "$DIR/$s" ] && DEPLOY_SCRIPT="$DIR/$s" && break
done

if [ -z "$DEPLOY_SCRIPT" ]; then
  echo "  [WARN] No deploy script found (expected deploy.sh)"
  for i in $(seq 1 6); do FAIL=$((FAIL + 1)); done
  echo ""
  echo "Result: $PASS/$TOTAL passed"
  echo "SCORE=$PASS/$TOTAL"
  exit 0
fi

# Check 4: Create kind cluster and deploy
echo "  Deploying to kind (this may take a few minutes)..."

# Delete any existing test cluster
kind delete cluster --name bench-ops 2>/dev/null || true

# Create a fresh kind cluster
kind create cluster --name bench-ops --wait 60s 2>/dev/null
kind_ok=$?
check "kind cluster created" "$([ "$kind_ok" -eq 0 ] && echo 1 || echo 0)"

if [ "$kind_ok" -ne 0 ]; then
  echo "  kind cluster creation failed, skipping runtime checks"
  for i in $(seq 1 5); do FAIL=$((FAIL + 1)); done
  echo ""
  echo "Result: $PASS/$TOTAL passed"
  echo "SCORE=$PASS/$TOTAL"
  exit 0
fi

# Set kubectl context
kubectl cluster-info --context kind-bench-ops 2>/dev/null

# Run the deploy script
chmod +x "$DEPLOY_SCRIPT"
echo "  Running $DEPLOY_SCRIPT..."
KUBECONFIG=$(kind get kubeconfig-path --name bench-ops 2>/dev/null || echo "$HOME/.kube/config")
export KUBECONFIG
bash "$DEPLOY_SCRIPT" 2>&1 | tail -20
deploy_ok=$?

# Wait for pods to be ready (up to 120s)
echo "  Waiting for pods (120s max)..."
kubectl wait --for=condition=ready pod -l app=valkey --timeout=120s 2>/dev/null || \
kubectl wait --for=condition=ready pod --all --timeout=120s 2>/dev/null || true

# Check 5: Valkey pods running
valkey_pods=$(kubectl get pods 2>/dev/null | grep -ci "valkey.*Running\|valkey.*1/1\|valkey.*2/2" || true)
check "Valkey pods running ($valkey_pods)" "$([ "$valkey_pods" -gt 0 ] && echo 1 || echo 0)"

# Check 6: At least 3 pods (primaries)
check "At least 3 pods (primaries)" "$([ "$valkey_pods" -ge 3 ] && echo 1 || echo 0)"

# Check 7: Can connect to Valkey and PING
ping_ok=0
# Try to find a valkey pod and exec into it
VPOD=$(kubectl get pods -o name 2>/dev/null | grep valkey | head -1)
if [ -n "$VPOD" ]; then
  pong=$(kubectl exec "$VPOD" -- valkey-cli PING 2>/dev/null || kubectl exec "$VPOD" -- redis-cli PING 2>/dev/null || true)
  [ "$pong" = "PONG" ] && ping_ok=1
fi
check "Can PING Valkey from pod" "$ping_ok"

# Check 8: Cluster mode enabled (if cluster mode was requested)
cluster_ok=0
if [ -n "$VPOD" ]; then
  cluster_info=$(kubectl exec "$VPOD" -- valkey-cli CLUSTER INFO 2>/dev/null || true)
  if echo "$cluster_info" | grep -q "cluster_enabled:1\|cluster_state:ok"; then
    cluster_ok=1
  fi
fi
check "Cluster mode enabled" "$cluster_ok"

# Check 9: Uses valkey-cli in probes (not redis-cli)
has_valkey_probe=$(echo "$YAMLS" | grep -ci "valkey-cli" || true)
check "Probes use valkey-cli (not redis-cli)" "$([ "$has_valkey_probe" -gt 0 ] && echo 1 || echo 0)"

# Cleanup
echo "  Cleaning up kind cluster..."
kind delete cluster --name bench-ops 2>/dev/null || true

cd - > /dev/null

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
