#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 1 v2: Cluster Split-Brain Bug Investigation
# The bug: clusterShouldDeferEpochBump() prevents epoch collision resolution
# after failover, causing permanent split-brain.

WORK_DIR="$(cd "${1:-.}" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" result="$2"
  if [[ "$result" == "0" ]]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Part 1: Analysis quality (4 checks) ---

ANALYSIS=$(find "$WORK_DIR" -maxdepth 1 -iname "*.md" ! -iname "CLAUDE.md" ! -iname "symptoms.md" -type f | head -1)

if [[ -z "$ANALYSIS" || ! -f "$ANALYSIS" ]]; then
  check "Analysis file exists" 1
  check "Identifies cluster_legacy.c" 1
  check "Identifies epoch collision resolution" 1
  check "Identifies the defer mechanism as root cause" 1
else
  check "Analysis file exists" 0
  CONTENT=$(cat "$ANALYSIS" | tr '[:upper:]' '[:lower:]')

  echo "$CONTENT" | grep -qE 'cluster_legacy\.c|cluster.legacy'
  check "Identifies cluster_legacy.c as the source file" "$?"

  echo "$CONTENT" | grep -qE 'epoch.*(collision|conflict|resolution)|collision.*(epoch|resolution)|configepoch.*(collision|conflict)'
  check "Identifies epoch collision resolution" "$?"

  # The actual root cause: the defer function prevents collision resolution
  if echo "$CONTENT" | grep -qE 'defer|shoulddefer|clusterShouldDeferEpochBump|deferep|prevent.*resolv|block.*resolv|never.*resolv|skip.*resolv'; then
    check "Identifies the defer mechanism as root cause" 0
  else
    # Also accept if they identify the infinite/permanent stall
    echo "$CONTENT" | grep -qE 'always.*true|never.*false|infinite.*defer|permanent.*defer|always.*defer|stuck.*loop|never.*bump'
    check "Identifies the defer mechanism as root cause" "$?"
  fi
fi

# --- Part 2: Patch quality (5 checks) ---

# Look for a patch file (any .patch or .diff, or changes in cluster_legacy.c)
PATCH=$(find "$WORK_DIR" -maxdepth 1 -name "*.patch" -o -name "*.diff" | head -1)
CLUSTER_SRC="$WORK_DIR/src/cluster_legacy.c"

if [[ -n "$PATCH" && -f "$PATCH" ]]; then
  check "Patch file exists" 0

  grep -qE 'cluster_legacy\.c' "$PATCH" 2>/dev/null
  check "Patch targets cluster_legacy.c" "$?"

  grep -qE '^\-\-\- |^\+\+\+ |^@@' "$PATCH" 2>/dev/null
  check "Patch is valid unified diff" "$?"

  # Patch should modify/remove the defer logic
  PATCH_CONTENT=$(cat "$PATCH" | tr '[:upper:]' '[:lower:]')
  if echo "$PATCH_CONTENT" | grep -qE 'defer|shoulddefer|clusterShouldDeferEpochBump'; then
    check "Patch addresses the defer mechanism" 0
  else
    check "Patch addresses the defer mechanism" 1
  fi

  # Patch should preserve the epoch bump in clusterHandleConfigEpochCollision
  if echo "$PATCH_CONTENT" | grep -qE 'currentepoch\+\+|configepoch|handleconfigepochcollision'; then
    check "Patch preserves epoch collision handler" 0
  else
    check "Patch preserves epoch collision handler" 1
  fi

elif [[ -f "$CLUSTER_SRC" ]]; then
  # Check if they edited the source directly instead of creating a patch
  MODIFIED=$(cat "$CLUSTER_SRC" | tr '[:upper:]' '[:lower:]')

  # Check if clusterShouldDeferEpochBump was removed or neutered
  if echo "$MODIFIED" | grep -qE 'clustershoulddeferepochbump'; then
    # Function still exists - check if the call was removed or the function always returns 0
    FUNC_BODY=$(sed -n '/clusterShouldDeferEpochBump/,/^}/p' "$CLUSTER_SRC")
    if echo "$FUNC_BODY" | grep -qE 'return 0|return false'; then
      check "Patch file exists" 0
      check "Patch targets cluster_legacy.c" 0
      check "Patch is valid unified diff" 1
      check "Patch addresses the defer mechanism" 0
      check "Patch preserves epoch collision handler" 0
    else
      # Check if the call site was modified
      CALL_LINE=$(grep -n "clusterShouldDeferEpochBump" "$CLUSTER_SRC" | grep -v "^.*int\|^.*void\|^.*static\|^.*{" | head -1)
      if [[ -z "$CALL_LINE" ]] || echo "$CALL_LINE" | grep -qE '//|/\*|\bif\b.*!'; then
        check "Patch file exists" 0
        check "Patch targets cluster_legacy.c" 0
        check "Patch is valid unified diff" 1
        check "Patch addresses the defer mechanism" 0
        check "Patch preserves epoch collision handler" 0
      else
        check "Patch file exists" 0
        check "Patch targets cluster_legacy.c" 0
        check "Patch is valid unified diff" 1
        check "Patch addresses the defer mechanism" 1
        check "Patch preserves epoch collision handler" 0
      fi
    fi
  else
    # Function was completely removed - that's a valid fix
    check "Patch file exists" 0
    check "Patch targets cluster_legacy.c" 0
    check "Patch is valid unified diff" 1
    check "Patch addresses the defer mechanism" 0
    check "Patch preserves epoch collision handler" 0
  fi
else
  check "Patch file exists" 1
  check "Patch targets cluster_legacy.c" 1
  check "Patch is valid unified diff" 1
  check "Patch addresses the defer mechanism" 1
  check "Patch preserves epoch collision handler" 1
fi

# --- Part 3: Root cause accuracy (3 checks) ---

# Search all text files for evidence they found the right function
ALL_TEXT=$(find "$WORK_DIR" -maxdepth 1 \( -name "*.md" -o -name "*.txt" -o -name "*.patch" -o -name "*.diff" \) ! -name "symptoms.md" ! -name "CLAUDE.md" -exec cat {} + 2>/dev/null | tr '[:upper:]' '[:lower:]')

# Must mention clusterHandleConfigEpochCollision
echo "$ALL_TEXT" | grep -qE 'clusterhandleconfigepochcollision|handleconfigepochcollision|handle.*config.*epoch.*collision'
check "Mentions clusterHandleConfigEpochCollision" "$?"

# Must mention clusterShouldDeferEpochBump or the defer logic
echo "$ALL_TEXT" | grep -qE 'clustershoulddeferepochbump|shoulddeferepochbump|defer.*epoch.*bump|defer.*bump'
check "Mentions clusterShouldDeferEpochBump" "$?"

# Must explain WHY it causes permanent split-brain
echo "$ALL_TEXT" | grep -qE 'always.*defer|always.*true|never.*resolv|permanent|indefinit|infinite|stuck|deadlock|configepoch.*equal.*currentepoch|match.*currentepoch'
check "Explains why split-brain is permanent" "$?"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
