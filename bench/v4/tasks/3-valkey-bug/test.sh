#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 3: Valkey Bug Fix (split-brain / epoch collision)
# Usage: test.sh <workspace_dir>
# Validates that the agent found and fixed the clusterShouldDeferEpochBump bug.
#
# Checks 1-4: Static analysis and compilation (always run)
# Checks 5-7: Docker-based cluster partition test (skipped if Docker unavailable)

WORK_DIR="$(cd "${1:-.}" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

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

skip() {
  local name="$1"
  echo "SKIP: $name"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

SRC="$WORK_DIR/src/cluster_legacy.c"
ORIG="$SCRIPT_DIR/workspace/src/cluster_legacy.c"

# =========================================
# CHECK 1: Source was modified
# =========================================

if [ ! -f "$SRC" ]; then
  check "Source was modified" 1
else
  # Compare against original buggy source
  if [ -f "$ORIG" ] && ! diff -q "$SRC" "$ORIG" > /dev/null 2>&1; then
    check "Source was modified" 0
  elif [ -f "$ORIG" ]; then
    check "Source was modified" 1
  else
    # No original to compare - check if any cluster file was touched
    check "Source was modified" 1
  fi
fi

# =========================================
# CHECK 2: clusterShouldDeferEpochBump neutralized
# =========================================

if [ ! -f "$SRC" ]; then
  check "clusterShouldDeferEpochBump neutralized" 1
else
  # Count active (non-commented) calls to clusterShouldDeferEpochBump that gate a return
  DEFER_CALL_COUNT=$(grep -c 'clusterShouldDeferEpochBump()' "$SRC" 2>/dev/null || true)
  DEFER_CALL_COUNT=${DEFER_CALL_COUNT:-0}

  # Count active lines of the function body that set defer = 1
  DEFER_SET_COUNT=$(grep -c 'defer = 1' "$SRC" 2>/dev/null || true)
  DEFER_SET_COUNT=${DEFER_SET_COUNT:-0}

  # The fix could be any of:
  # a) Remove the function entirely (DEFER_CALL_COUNT=0)
  # b) Remove or comment out the call site (call exists but gated return is gone)
  # c) Make the function always return 0 (defer = 1 is removed)
  # d) Comment out the defer = 1 line
  #
  # We check: either the call is gone, OR the defer=1 assignment is gone.
  # If both are still present and active, the bug is NOT fixed.

  if [ "$DEFER_CALL_COUNT" = "0" ] || [ "$DEFER_SET_COUNT" = "0" ]; then
    check "clusterShouldDeferEpochBump neutralized" 0
  else
    # Double-check: maybe the call site line is commented out
    ACTIVE_CALL=$(grep -E '^\s*(if\s*\()?\s*clusterShouldDeferEpochBump' "$SRC" 2>/dev/null | grep -v '^\s*//' | grep -v '^\s*\*' | grep -c 'clusterShouldDeferEpochBump' || true)
    ACTIVE_CALL=${ACTIVE_CALL:-0}
    if [ "$ACTIVE_CALL" = "0" ]; then
      check "clusterShouldDeferEpochBump neutralized" 0
    else
      check "clusterShouldDeferEpochBump neutralized" 1
    fi
  fi
fi

# =========================================
# CHECK 3: clusterHandleConfigEpochCollision preserved
# =========================================

if [ ! -f "$SRC" ]; then
  check "clusterHandleConfigEpochCollision preserved" 1
else
  # The epoch collision handler must still be functional - it must contain currentEpoch++
  EPOCH_INC_COUNT=$(grep -c 'currentEpoch++' "$SRC" 2>/dev/null || true)
  EPOCH_INC_COUNT=${EPOCH_INC_COUNT:-0}

  if [ "$EPOCH_INC_COUNT" -ge 1 ]; then
    check "clusterHandleConfigEpochCollision preserved" 0
  else
    check "clusterHandleConfigEpochCollision preserved" 1
  fi
fi

# =========================================
# CHECK 4: Code compiles (make -j4)
# =========================================

echo ""
echo "Building valkey (make -j4)..."
cd "$WORK_DIR"
if make -j4 > /dev/null 2>&1; then
  check "make succeeds" 0
else
  check "make succeeds" 1
fi

# =========================================
# DOCKER CHECKS (5-7) - skip if Docker unavailable
# =========================================

DOCKER_CMD=""
if command -v docker-compose > /dev/null 2>&1; then
  DOCKER_CMD="docker-compose"
elif command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
  DOCKER_CMD="docker compose"
fi

if [ -z "$DOCKER_CMD" ]; then
  echo ""
  echo "Docker not available - skipping cluster integration checks"
  skip "Docker build succeeds"
  skip "Cluster forms (6 nodes, all slots covered)"
  skip "No split-brain after partition heal"
else
  COMPOSE_PROJECT="valkeytest3$$"

  cleanup() {
    cd "$WORK_DIR"
    $DOCKER_CMD -p "$COMPOSE_PROJECT" down -v --remove-orphans > /dev/null 2>&1 || true
  }
  trap cleanup EXIT

  # --- CHECK 5: Docker build succeeds ---
  echo ""
  echo "Building Docker image..."
  cd "$WORK_DIR"
  if $DOCKER_CMD -p "$COMPOSE_PROJECT" build > /dev/null 2>&1; then
    check "Docker build succeeds" 0
  else
    check "Docker build succeeds" 1
    skip "Cluster forms (6 nodes, all slots covered)"
    skip "No split-brain after partition heal"
    echo ""
    echo "========================================="
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped out of $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) checks"
    echo "========================================="
    exit 1
  fi

  # --- CHECK 6: Cluster forms (6 nodes, all slots covered) ---
  echo "Starting cluster..."
  cd "$WORK_DIR"
  $DOCKER_CMD -p "$COMPOSE_PROJECT" up -d > /dev/null 2>&1
  sleep 5

  # Create the cluster
  CLUSTER_CREATED=false
  if $DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli --cluster create \
    172.30.0.11:7001 172.30.0.12:7002 172.30.0.13:7003 \
    172.30.0.14:7004 172.30.0.15:7005 172.30.0.16:7006 \
    --cluster-replicas 1 --cluster-yes > /dev/null 2>&1; then
    CLUSTER_CREATED=true
  fi

  sleep 3

  if [ "$CLUSTER_CREATED" = true ]; then
    # Verify all 16384 slots are covered
    CLUSTER_INFO=$($DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -p 7001 CLUSTER INFO 2>/dev/null || true)
    SLOTS_OK=$(echo "$CLUSTER_INFO" | grep -c 'cluster_slots_ok:16384' || true)

    if [ "$SLOTS_OK" -ge 1 ]; then
      check "Cluster forms (6 nodes, all slots covered)" 0
    else
      check "Cluster forms (6 nodes, all slots covered)" 1
    fi
  else
    check "Cluster forms (6 nodes, all slots covered)" 1
  fi

  # --- CHECK 7: No split-brain after partition heal ---
  if [ "$CLUSTER_CREATED" = true ]; then
    echo "Running partition test..."

    # Get container and network for valkey-1
    CONTAINER=$($DOCKER_CMD -p "$COMPOSE_PROJECT" ps -q valkey-1 2>/dev/null)
    NETWORK=$(docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)

    if [ -n "$CONTAINER" ] && [ -n "$NETWORK" ]; then
      # Disconnect valkey-1
      docker network disconnect "$NETWORK" "$CONTAINER" 2>/dev/null || true

      # Wait for failover
      sleep 15

      # Reconnect
      docker network connect "$NETWORK" "$CONTAINER" --ip 172.30.0.11 2>/dev/null || \
        docker network connect "$NETWORK" "$CONTAINER" 2>/dev/null || true

      # Wait for gossip convergence
      sleep 10

      # Check for split-brain: count masters and verify no overlapping slot ranges
      NODES_OUTPUT=$($DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-2 valkey-cli -p 7002 CLUSTER NODES 2>/dev/null || true)
      MASTER_COUNT=$(echo "$NODES_OUTPUT" | grep -c ' master ' || true)

      # Extract slot ranges for all masters
      SLOT_RANGES=$(echo "$NODES_OUTPUT" | grep ' master ' | grep -oE '[0-9]+-[0-9]+' || true)
      UNIQUE_RANGES=$(echo "$SLOT_RANGES" | sort -u | wc -l)
      TOTAL_RANGES=$(echo "$SLOT_RANGES" | wc -l)

      # Split-brain indicators:
      # - More than 3 masters
      # - Duplicate slot ranges (two masters claiming same slots)
      if [ "$MASTER_COUNT" -le 3 ] && [ "$TOTAL_RANGES" -eq "$UNIQUE_RANGES" ] && [ "$MASTER_COUNT" -ge 1 ]; then
        check "No split-brain after partition heal" 0
      else
        echo "  Split-brain detected: $MASTER_COUNT masters, $TOTAL_RANGES ranges ($UNIQUE_RANGES unique)"
        echo "  Nodes output:"
        echo "$NODES_OUTPUT" | sed 's/^/    /'
        check "No split-brain after partition heal" 1
      fi
    else
      echo "  Could not identify container or network for partition test"
      check "No split-brain after partition heal" 1
    fi
  else
    skip "No split-brain after partition heal"
  fi
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped out of $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
