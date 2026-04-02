#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 3: Valkey Bug Fix (split-brain / epoch collision)
# Usage: test.sh <workspace_dir>
# Validates that the agent found and fixed the clusterShouldDeferEpochBump bug.

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

SRC="$WORK_DIR/src/cluster_legacy.c"

# --- Check 1: clusterShouldDeferEpochBump was neutralized ---
# The buggy function must be removed, commented out, or its call site disabled.
# We check that the function no longer returns 1 in a way that blocks collision resolution.

if [ ! -f "$SRC" ]; then
  check "cluster_legacy.c exists" 1
  check "clusterShouldDeferEpochBump neutralized" 1
  check "clusterHandleConfigEpochCollision preserved" 1
else
  check "cluster_legacy.c exists" 0

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

  # --- Check 2: clusterHandleConfigEpochCollision still increments currentEpoch ---
  # The epoch collision handler must still be functional - it must contain currentEpoch++

  EPOCH_INC_COUNT=$(grep -c 'currentEpoch++' "$SRC" 2>/dev/null || true)
  EPOCH_INC_COUNT=${EPOCH_INC_COUNT:-0}

  if [ "$EPOCH_INC_COUNT" -ge 1 ]; then
    check "clusterHandleConfigEpochCollision preserved" 0
  else
    check "clusterHandleConfigEpochCollision preserved" 1
  fi
fi

# --- Check 3: Code compiles ---
echo ""
echo "Building valkey (make -j$(nproc))..."
cd "$WORK_DIR"
if make -j"$(nproc)" 2>&1; then
  check "make succeeds" 0
else
  check "make succeeds" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
