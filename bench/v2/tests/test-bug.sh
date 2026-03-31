#!/bin/bash
# Validates Task 1 (bug investigation) response
# Checks analysis quality, concrete fix, and actual source modification
# Input: $1 = directory containing agent's response

DIR="$1"
PASS=0
FAIL=0
TOTAL=12

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

echo "=== Task 1: Bug Investigation Validation ==="

# Get analysis from ANALYSIS.md only
RESPONSE=""
if [ -f "$DIR/ANALYSIS.md" ]; then
  RESPONSE=$(cat "$DIR/ANALYSIS.md")
elif [ -f "$DIR/analysis.md" ]; then
  RESPONSE=$(cat "$DIR/analysis.md")
else
  RESPONSE=$(find "$DIR" -maxdepth 1 \( -name "*.md" -o -name "*.txt" \) ! -name "symptoms.md" ! -name "README.md" ! -name "CLAUDE.md" ! -name "questions.md" -exec cat {} + 2>/dev/null)
fi

# Also check patch files
PATCH_FILES=$(find "$DIR" -maxdepth 1 \( -name "*.patch" -o -name "*.diff" \) -exec cat {} + 2>/dev/null)
ALL="$RESPONSE $PATCH_FILES"

# --- Source code fix checks ---

# Check 1: Did the agent actually modify cluster_legacy.c?
SRC="$DIR/src/cluster_legacy.c"
if [ -f "$SRC" ]; then
  # The bug is clusterShouldDeferEpochBump() always returning 1
  # Fix: remove/disable the deferral function or fix the logic
  has_defer=$(grep -c "clusterShouldDeferEpochBump" "$SRC" || true)
  defer_called=$(grep "if (clusterShouldDeferEpochBump())" "$SRC" | grep -c "return" || true)

  # Fixed if: the call is removed, commented out, or the function is fixed
  if [ "$defer_called" -eq 0 ]; then
    check "Source fixed: deferral call removed or disabled" 1
  else
    # Check if the function logic was fixed (no longer always returns 1)
    always_true=$(grep -A20 "clusterShouldDeferEpochBump" "$SRC" | grep -c "configEpoch == server.cluster->currentEpoch" || true)
    if [ "$always_true" -eq 0 ]; then
      check "Source fixed: deferral logic corrected" 1
    else
      check "Source fixed: buggy deferral still active" 0
    fi
  fi
else
  check "Source file exists" 0
fi

# Check 2: Does the fix preserve the epoch collision handler?
if [ -f "$SRC" ]; then
  has_collision_handler=$(grep -c "void clusterHandleConfigEpochCollision" "$SRC" || true)
  has_epoch_bump=$(grep -A20 "clusterHandleConfigEpochCollision" "$SRC" | grep -c "currentEpoch++" || true)
  check "Epoch collision handler preserved with bump" "$([ "$has_collision_handler" -gt 0 ] && [ "$has_epoch_bump" -gt 0 ] && echo 1 || echo 0)"
else
  check "Epoch collision handler preserved" 0
fi

# --- Build and runtime checks ---

cd "$DIR"

# Check 3: Does it build? (docker compose build)
echo "  Building fixed Valkey..."
build_ok=0
docker compose build --quiet 2>/dev/null && build_ok=1
check "Fixed source compiles (docker compose build)" "$build_ok"

# Check 4: Does the cluster start and work after fix?
if [ "$build_ok" -eq 1 ]; then
  echo "  Starting cluster..."
  docker compose up -d 2>/dev/null
  sleep 5

  # Try to create cluster
  docker compose exec -T valkey-1 valkey-cli --cluster create \
    172.30.0.11:7001 172.30.0.12:7002 172.30.0.13:7003 \
    172.30.0.14:7004 172.30.0.15:7005 172.30.0.16:7006 \
    --cluster-replicas 1 --cluster-yes 2>/dev/null

  sleep 3
  cluster_ok=$(docker compose exec -T valkey-1 valkey-cli -p 7001 CLUSTER INFO 2>/dev/null | grep -c "cluster_state:ok" || true)
  check "Cluster starts and is healthy" "$([ "$cluster_ok" -gt 0 ] && echo 1 || echo 0)"

  docker compose down -v 2>/dev/null
else
  check "Cluster starts and is healthy" 0
fi

cd - > /dev/null

# --- Analysis checks ---

if [ -z "$RESPONSE" ]; then
  echo "  [WARN] No ANALYSIS.md found - checking source fix only"
  for i in $(seq 3 $TOTAL); do
    FAIL=$((FAIL + 1))
  done
  echo ""
  echo "Result: $PASS/$TOTAL passed"
  echo "SCORE=$PASS/$TOTAL"
  exit 0
fi

# Check 5: Identifies clusterHandleConfigEpochCollision as the affected function
found_func=$(echo "$ALL" | grep -ci "clusterHandleConfigEpochCollision\|HandleConfigEpochCollision\|epoch.*collision" || true)
check "Identifies epoch collision handler" "$([ "$found_func" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Identifies clusterShouldDeferEpochBump as the buggy function
found_defer=$(echo "$ALL" | grep -ci "clusterShouldDeferEpochBump\|ShouldDeferEpochBump\|defer.*epoch.*bump" || true)
check "Identifies deferral function as the bug" "$([ "$found_defer" -gt 0 ] && echo 1 || echo 0)"

# Check 5: Explains WHY the deferral is always true
found_why=$(echo "$ALL" | grep -ci "always.*true\|always.*return.*1\|always.*defer\|currentEpoch.*always.*match\|never.*resolve\|configEpoch.*==.*currentEpoch.*always" || true)
check "Explains why deferral always triggers" "$([ "$found_why" -gt 0 ] && echo 1 || echo 0)"

# Check 6: References the relationship between currentEpoch and configEpoch
found_epoch=$(echo "$ALL" | grep -ci "currentEpoch.*max.*configEpoch\|currentEpoch.*highest\|at least one.*match\|by definition" || true)
check "Explains currentEpoch/configEpoch relationship" "$([ "$found_epoch" -gt 0 ] && echo 1 || echo 0)"

# Check 7: Explains the split-brain mechanism
found_mechanism=$(echo "$ALL" | grep -ci "collision.*never.*resolved\|same.*configEpoch.*forever\|both.*claim.*slot\|neither.*bump\|split.brain" || true)
check "Explains split-brain from unresolved collision" "$([ "$found_mechanism" -gt 0 ] && echo 1 || echo 0)"

# Check 8: References cluster_legacy.c as the file
found_file=$(echo "$ALL" | grep -ci "cluster_legacy" || true)
check "Identifies cluster_legacy.c" "$([ "$found_file" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
