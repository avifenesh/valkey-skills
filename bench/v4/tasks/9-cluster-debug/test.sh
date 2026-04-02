#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 9: Cluster Failover Debug
# Usage: test.sh <workspace_dir>
# Validates that the agent correctly diagnosed the cluster failover issue.

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

# Helper: word count across all output files
total_words() {
  local count=0
  for f in "$WORK_DIR/diagnosis.md" "$WORK_DIR/immediate-fix.md" "$WORK_DIR/prevention.md"; do
    if [ -f "$f" ]; then
      local wc
      wc=$(wc -w < "$f" 2>/dev/null || echo 0)
      count=$((count + wc))
    fi
  done
  echo "$count"
}

# =========================================
# DIAGNOSIS CHECKS
# =========================================

DIAG="$WORK_DIR/diagnosis.md"

# Check 1: diagnosis.md exists
if [ -f "$DIAG" ]; then
  check "diagnosis.md exists" 0
else
  check "diagnosis.md exists" 1
fi

# Check 2: Mentions cluster-replica-validity-factor or validity factor
if [ -f "$DIAG" ] && file_has "cluster-replica-validity-factor|validity.factor" "$DIAG"; then
  check "Diagnosis: mentions replica validity factor" 0
else
  check "Diagnosis: mentions replica validity factor" 1
fi

# Check 3: Mentions master_last_io_seconds_ago or 55 seconds
if [ -f "$DIAG" ] && file_has "master_last_io_seconds_ago|55 seconds|55s" "$DIAG"; then
  check "Diagnosis: mentions 55-second disconnection" 0
else
  check "Diagnosis: mentions 55-second disconnection" 1
fi

# Check 4: Shows the calculation - 55 > 50 or 55 > 10*5 or similar
if [ -f "$DIAG" ] && file_has "55.*>.*50|55.*exceed|10 ?\* ?5|10 ?x ?5|validity.window.*(50|5000)" "$DIAG"; then
  check "Diagnosis: shows validity window calculation" 0
else
  check "Diagnosis: shows validity window calculation" 1
fi

# Check 5: References the exact log line
if [ -f "$DIAG" ] && file_has "Replica validity factor test failed" "$DIAG"; then
  check "Diagnosis: cites 'Replica validity factor test failed' log line" 0
else
  check "Diagnosis: cites 'Replica validity factor test failed' log line" 1
fi

# =========================================
# IMMEDIATE FIX CHECKS
# =========================================

FIX="$WORK_DIR/immediate-fix.md"

# Check 6: immediate-fix.md exists
if [ -f "$FIX" ]; then
  check "immediate-fix.md exists" 0
else
  check "immediate-fix.md exists" 1
fi

# Check 7: Contains CLUSTER FAILOVER FORCE
if [ -f "$FIX" ] && file_has "CLUSTER FAILOVER FORCE" "$FIX"; then
  check "Immediate fix: includes CLUSTER FAILOVER FORCE command" 0
else
  check "Immediate fix: includes CLUSTER FAILOVER FORCE command" 1
fi

# =========================================
# PREVENTION CHECKS
# =========================================

PREV="$WORK_DIR/prevention.md"

# Check 8: prevention.md exists
if [ -f "$PREV" ]; then
  check "prevention.md exists" 0
else
  check "prevention.md exists" 1
fi

# Check 9: Mentions changing cluster-replica-validity-factor (to 0 or lower)
if [ -f "$PREV" ] && file_has "cluster-replica-validity-factor" "$PREV"; then
  check "Prevention: mentions cluster-replica-validity-factor config change" 0
else
  check "Prevention: mentions cluster-replica-validity-factor config change" 1
fi

# Check 10: Mentions monitoring or alerting
if [ -f "$PREV" ] && file_has "monitor|alert|observ" "$PREV"; then
  check "Prevention: mentions monitoring/alerting" 0
else
  check "Prevention: mentions monitoring/alerting" 1
fi

# Check 11: Mentions cluster-node-timeout as related config
if [ -f "$PREV" ] && file_has "cluster-node-timeout" "$PREV"; then
  check "Prevention: mentions cluster-node-timeout" 0
else
  check "Prevention: mentions cluster-node-timeout" 1
fi

# =========================================
# OVERALL QUALITY CHECKS
# =========================================

# Check 12: Total word count across all files is 200+
WORDS=$(total_words)
if [ "$WORDS" -ge 200 ]; then
  check "Quality: 200+ words total across all files ($WORDS words)" 0
else
  check "Quality: 200+ words total across all files ($WORDS words)" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
