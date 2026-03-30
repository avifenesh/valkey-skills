#!/bin/bash
# Validates Task 1 (bug investigation) response
# Checks if the agent identified the correct root cause
# Input: $1 = directory containing agent's response files

DIR="$1"
PASS=0
FAIL=0
TOTAL=6

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

# Search all text files for the response content
RESPONSE=$(find "$DIR" -name "*.md" -o -name "*.txt" -o -name "*.c" -o -name "*.patch" | xargs cat 2>/dev/null)

# If no separate files, check if response was written inline
if [ -z "$RESPONSE" ]; then
  RESPONSE=$(find "$DIR" -name "*.md" | xargs cat 2>/dev/null)
fi

# Check 1: Identifies cluster_legacy.c as the relevant source file
found_file=$(echo "$RESPONSE" | grep -ci "cluster_legacy" || true)
check "Identifies cluster_legacy.c" "$([ "$found_file" -gt 0 ] && echo 1 || echo 0)"

# Check 2: References the failover auth epoch increment
found_failover=$(echo "$RESPONSE" | grep -ci "failover_auth_epoch\|failover_auth_sent\|clusterHandleReplicaFailover" || true)
check "References failover auth mechanism" "$([ "$found_failover" -gt 0 ] && echo 1 || echo 0)"

# Check 3: References currentEpoch increment
found_epoch=$(echo "$RESPONSE" | grep -ci "currentEpoch" || true)
check "References currentEpoch" "$([ "$found_epoch" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Explains that epoch must increment before requesting votes
found_mechanism=$(echo "$RESPONSE" | grep -ci "increment.*before.*vote\|epoch.*increment.*failover\|bump.*epoch\|epoch.*advance" || true)
check "Explains epoch increment during failover" "$([ "$found_mechanism" -gt 0 ] && echo 1 || echo 0)"

# Check 5: References clusterRequestFailoverAuth or vote requesting
found_vote=$(echo "$RESPONSE" | grep -ci "clusterRequestFailoverAuth\|RequestFailoverAuth\|failover.*auth\|vote.*request" || true)
check "References vote/auth request function" "$([ "$found_vote" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Proposes a fix or workaround
found_fix=$(echo "$RESPONSE" | grep -ci "fix\|patch\|workaround\|solution\|restore.*increment\|re-enable\|uncomment" || true)
check "Proposes a fix or workaround" "$([ "$found_fix" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
