#!/bin/bash
# Validates Task 3 (ops cluster) response
# Input: $1 = directory containing agent's K8s manifests

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

YAMLS=$(find "$DIR" -name "*.yaml" -o -name "*.yml" | grep -v docker-compose | xargs cat 2>/dev/null)
ALL_FILES=$(find "$DIR" \( -name "*.yaml" -o -name "*.yml" -o -name "*.sh" -o -name "*.md" -o -name "*.conf" \) | xargs cat 2>/dev/null)

# Check 1: YAML files exist and pass dry-run (if kubectl available)
yaml_count=$(find "$DIR" -name "*.yaml" -o -name "*.yml" | grep -v docker-compose | wc -l)
if command -v kubectl &>/dev/null && [ "$yaml_count" -gt 0 ]; then
  yaml_errors=0
  for f in $(find "$DIR" -name "*.yaml" -o -name "*.yml" | grep -v docker-compose); do
    kubectl apply --dry-run=client -f "$f" 2>/dev/null
    [ $? -ne 0 ] && yaml_errors=$((yaml_errors + 1))
  done
  check "YAML valid ($yaml_count files, $yaml_errors errors)" "$([ "$yaml_errors" -eq 0 ] && echo 1 || echo 0)"
else
  check "YAML files present ($yaml_count files)" "$([ "$yaml_count" -gt 0 ] && echo 1 || echo 0)"
fi

# Check 2: StatefulSet present
has_statefulset=$(echo "$YAMLS" | grep -c "kind: StatefulSet" || true)
check "StatefulSet defined" "$([ "$has_statefulset" -gt 0 ] && echo 1 || echo 0)"

# Check 3: valkey-search module loaded
has_search=$(echo "$ALL_FILES" | grep -ci "loadmodule.*search\|search\.so\|valkey-search" || true)
check "valkey-search module loaded" "$([ "$has_search" -gt 0 ] && echo 1 || echo 0)"

# Check 4: ACL users defined (not just default)
has_acl=$(echo "$ALL_FILES" | grep -ci "user app\|user admin\|user monitor\|aclfile\|ACL SETUSER" || true)
check "ACL users defined" "$([ "$has_acl" -gt 0 ] && echo 1 || echo 0)"

# Check 5: TLS configuration
has_tls=$(echo "$ALL_FILES" | grep -ci "tls-cert-file\|tls-key-file\|tls-ca-cert\|tls-port\|tls-replication" || true)
check "TLS configured" "$([ "$has_tls" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Readiness probes use valkey-cli (not redis-cli)
has_valkey_probe=$(echo "$YAMLS" | grep -ci "valkey-cli" || true)
check "Probes use valkey-cli (not redis-cli)" "$([ "$has_valkey_probe" -gt 0 ] && echo 1 || echo 0)"

# Check 7: PodDisruptionBudget present
has_pdb=$(echo "$YAMLS" | grep -c "kind: PodDisruptionBudget" || true)
check "PodDisruptionBudget defined" "$([ "$has_pdb" -gt 0 ] && echo 1 || echo 0)"

# Check 8: PersistentVolumeClaim or volumeClaimTemplates
has_pvc=$(echo "$YAMLS" | grep -ci "volumeClaimTemplates\|PersistentVolumeClaim" || true)
check "Persistent storage configured" "$([ "$has_pvc" -gt 0 ] && echo 1 || echo 0)"

# Check 9: Prometheus metrics exporter
has_prom=$(echo "$ALL_FILES" | grep -ci "prometheus\|exporter\|valkey-exporter\|metrics.*port" || true)
check "Prometheus metrics exporter" "$([ "$has_prom" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
