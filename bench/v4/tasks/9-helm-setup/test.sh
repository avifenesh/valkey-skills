#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 9: Helm Setup for Valkey Cluster
# Usage: test.sh <workspace_dir>
# Validates generated Helm values, setup script, and README.
# No Kubernetes cluster needed - file content validation only.

WORK_DIR="$(cd "${1:-.}" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" result="$2"
  if [ "$result" = "0" ]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Helper: check if a pattern appears in a file (case-insensitive)
file_has() {
  grep -qiE "$1" "$2" 2>/dev/null
}

VALUES="$WORK_DIR/values.yaml"
SETUP="$WORK_DIR/setup.sh"
README="$WORK_DIR/README.md"

# =========================================
# FILE EXISTENCE CHECKS
# =========================================

# Check 1: values.yaml exists
if [ -f "$VALUES" ]; then
  check "values.yaml exists" 0
else
  check "values.yaml exists" 1
fi

# Check 2: setup.sh exists
if [ -f "$SETUP" ]; then
  check "setup.sh exists" 0
else
  check "setup.sh exists" 1
fi

# Check 3: README.md exists
if [ -f "$README" ]; then
  check "README.md exists" 0
else
  check "README.md exists" 1
fi

# =========================================
# VALUES.YAML CONTENT CHECKS
# =========================================

if [ -f "$VALUES" ]; then
  # Check 4: Cluster sizing - replicas/replicaCount with 3 or cluster.nodes with 6
  if file_has "(replicas|replicaCount):? *(3|6)" "$VALUES" || \
     file_has "nodes:? *6" "$VALUES" || \
     file_has "shards:? *3" "$VALUES"; then
    check "values.yaml: cluster sizing (3 primaries or 6 nodes)" 0
  else
    check "values.yaml: cluster sizing (3 primaries or 6 nodes)" 1
  fi

  # Check 5: TLS section with enabled: true
  if file_has "tls:" "$VALUES" && file_has "enabled:? *true" "$VALUES"; then
    check "values.yaml: TLS enabled" 0
  else
    check "values.yaml: TLS enabled" 1
  fi

  # Check 6: Auth or password configuration
  if file_has "(auth:|password:|existingSecret:)" "$VALUES"; then
    check "values.yaml: authentication configured" 0
  else
    check "values.yaml: authentication configured" 1
  fi

  # Check 7: maxmemory with 512 reference
  if file_has "maxmemory.*(512|512mb|512M)" "$VALUES" || \
     file_has "512.*(mb|Mi|m)" "$VALUES"; then
    check "values.yaml: 512MB memory limit" 0
  else
    check "values.yaml: 512MB memory limit" 1
  fi

  # Check 8: maxmemory-policy allkeys-lru
  if file_has "maxmemory-policy.*allkeys-lru" "$VALUES"; then
    check "values.yaml: maxmemory-policy allkeys-lru" 0
  else
    check "values.yaml: maxmemory-policy allkeys-lru" 1
  fi

  # Check 9: Persistence enabled
  if file_has "persistence:" "$VALUES" && file_has "enabled:? *true" "$VALUES"; then
    check "values.yaml: persistence enabled" 0
  else
    check "values.yaml: persistence enabled" 1
  fi

  # Check 10: Resources with CPU/memory requests
  if file_has "resources:" "$VALUES" && \
     (file_has "cpu:" "$VALUES" || file_has "cpu " "$VALUES") && \
     (file_has "memory:" "$VALUES" || file_has "memory " "$VALUES"); then
    check "values.yaml: resource requests (CPU and memory)" 0
  else
    check "values.yaml: resource requests (CPU and memory)" 1
  fi

  # Check 11: AOF / appendonly reference
  if file_has "(appendonly|aof)" "$VALUES"; then
    check "values.yaml: AOF persistence reference" 0
  else
    check "values.yaml: AOF persistence reference" 1
  fi

  # Check 12: Correct Helm chart repo reference
  if file_has "(valkey\.io|bitnami)" "$VALUES" || \
     file_has "(valkey/valkey|bitnamicharts/valkey)" "$VALUES"; then
    check "values.yaml: references correct Helm chart repo" 0
  else
    check "values.yaml: references correct Helm chart repo" 1
  fi
else
  # If values.yaml missing, fail all content checks
  for name in "cluster sizing" "TLS enabled" "authentication" "512MB memory" \
              "maxmemory-policy" "persistence" "resource requests" "AOF" "chart repo"; do
    check "values.yaml: $name" 1
  done
fi

# =========================================
# SETUP.SH CONTENT CHECKS
# =========================================

if [ -f "$SETUP" ]; then
  # Check 13: Creates namespace
  if file_has "(kubectl create namespace|kubectl create ns|namespace)" "$SETUP"; then
    check "setup.sh: creates namespace" 0
  else
    check "setup.sh: creates namespace" 1
  fi

  # Check 14: Contains helm install or helm upgrade --install
  if file_has "(helm install|helm upgrade --install|helm upgrade -i)" "$SETUP"; then
    check "setup.sh: contains helm install" 0
  else
    check "setup.sh: contains helm install" 1
  fi

  # Check 15: References TLS cert generation
  if file_has "(openssl|cert-manager|cfssl|mkcert|generate.*cert|tls.*cert|cert.*tls|create.*cert)" "$SETUP"; then
    check "setup.sh: TLS cert generation" 0
  else
    check "setup.sh: TLS cert generation" 1
  fi
else
  for name in "creates namespace" "contains helm install" "TLS cert generation"; do
    check "setup.sh: $name" 1
  done
fi

# =========================================
# README.MD CONTENT CHECKS
# =========================================

if [ -f "$README" ]; then
  # Check 16: README has 50+ words
  WORD_COUNT=$(wc -w < "$README" 2>/dev/null || echo "0")
  WORD_COUNT=$(echo "$WORD_COUNT" | tr -d '[:space:]')
  if [ "$WORD_COUNT" -ge 50 ]; then
    check "README.md: has 50+ words ($WORD_COUNT words)" 0
  else
    check "README.md: has 50+ words ($WORD_COUNT words)" 1
  fi
else
  check "README.md: has 50+ words" 1
fi

# =========================================
# SUMMARY
# =========================================
echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
