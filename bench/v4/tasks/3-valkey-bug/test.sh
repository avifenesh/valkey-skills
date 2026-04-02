#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 3: Valkey Bug Fix (two bugs: AOF key duplication + epoch split-brain)
# Usage: test.sh <workspace_dir>
#
# Bug 1 (db.c): isReplicatedClient should be mustObeyClient in getKeySlot slot cache
# Bug 2 (cluster_legacy.c): clusterShouldDeferEpochBump prevents epoch collision resolution

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

DB_SRC="$WORK_DIR/src/db.c"
CLUSTER_SRC="$WORK_DIR/src/cluster_legacy.c"

# =========================================
# BUG 1: AOF key duplication (db.c)
# =========================================

echo "=== Bug 1: AOF key duplication (db.c) ==="

# Check 1: db.c was modified
if [ ! -f "$DB_SRC" ]; then
  check "db.c exists" 1
  check "mustObeyClient used in getKeySlot" 1
  check "isReplicatedClient removed from slot cache" 1
else
  check "db.c exists" 0

  # Check 2: mustObeyClient appears at least 2 times (cache check + backfill)
  MUST_OBEY=$(grep -c 'mustObeyClient' "$DB_SRC" 2>/dev/null || true)
  MUST_OBEY=${MUST_OBEY:-0}
  if [ "$MUST_OBEY" -ge 2 ]; then
    check "mustObeyClient used in getKeySlot" 0
  else
    check "mustObeyClient used in getKeySlot" 1
  fi

  # Check 3: isReplicatedClient NOT on the executing_command line
  BUG_LINE=$(grep 'executing_command' "$DB_SRC" 2>/dev/null | grep -c 'isReplicatedClient' 2>/dev/null || true)
  BUG_LINE=${BUG_LINE:-0}
  if [ "$BUG_LINE" = "0" ]; then
    check "isReplicatedClient removed from slot cache" 0
  else
    check "isReplicatedClient removed from slot cache" 1
  fi
fi

# =========================================
# BUG 2: Epoch split-brain (cluster_legacy.c)
# =========================================

echo ""
echo "=== Bug 2: Epoch split-brain (cluster_legacy.c) ==="

if [ ! -f "$CLUSTER_SRC" ]; then
  check "cluster_legacy.c exists" 1
  check "clusterShouldDeferEpochBump neutralized" 1
  check "clusterHandleConfigEpochCollision preserved" 1
else
  check "cluster_legacy.c exists" 0

  # Check 5: clusterShouldDeferEpochBump removed or neutralized
  DEFER_CALL=$(grep -c 'clusterShouldDeferEpochBump()' "$CLUSTER_SRC" 2>/dev/null || true)
  DEFER_CALL=${DEFER_CALL:-0}
  DEFER_SET=$(grep -c 'defer = 1' "$CLUSTER_SRC" 2>/dev/null || true)
  DEFER_SET=${DEFER_SET:-0}

  if [ "$DEFER_CALL" = "0" ] || [ "$DEFER_SET" = "0" ]; then
    check "clusterShouldDeferEpochBump neutralized" 0
  else
    ACTIVE=$(grep -E '^\s*(if\s*\()?\s*clusterShouldDeferEpochBump' "$CLUSTER_SRC" 2>/dev/null | grep -v '^\s*//' | grep -v '^\s*\*' | grep -c 'clusterShouldDeferEpochBump' || true)
    ACTIVE=${ACTIVE:-0}
    if [ "$ACTIVE" = "0" ]; then
      check "clusterShouldDeferEpochBump neutralized" 0
    else
      check "clusterShouldDeferEpochBump neutralized" 1
    fi
  fi

  # Check 6: currentEpoch++ still in clusterHandleConfigEpochCollision
  EPOCH_INC=$(grep -c 'currentEpoch++' "$CLUSTER_SRC" 2>/dev/null || true)
  EPOCH_INC=${EPOCH_INC:-0}
  if [ "$EPOCH_INC" -ge 1 ]; then
    check "clusterHandleConfigEpochCollision preserved" 0
  else
    check "clusterHandleConfigEpochCollision preserved" 1
  fi
fi

# =========================================
# COMPILATION
# =========================================

echo ""
echo "=== Compilation ==="
echo "Building valkey (make -j4)..."
cd "$WORK_DIR"
if make -j4 > /dev/null 2>&1; then
  check "make succeeds" 0
else
  check "make succeeds" 1
fi

# =========================================
# SUMMARY
# =========================================

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="
