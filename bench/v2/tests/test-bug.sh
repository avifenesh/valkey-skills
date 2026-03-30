#!/bin/bash
# Validates Task 1 (bug investigation) response
# Only checks ANALYSIS.md - the file the agent is asked to write
# Input: $1 = directory containing agent's response

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

# Only search the agent's analysis output - NOT source code files
RESPONSE=""
if [ -f "$DIR/ANALYSIS.md" ]; then
  RESPONSE=$(cat "$DIR/ANALYSIS.md")
elif [ -f "$DIR/analysis.md" ]; then
  RESPONSE=$(cat "$DIR/analysis.md")
else
  # Fallback: search .md and .txt files, exclude source code
  RESPONSE=$(find "$DIR" -maxdepth 1 \( -name "*.md" -o -name "*.txt" \) ! -name "symptoms.md" ! -name "README.md" | xargs cat 2>/dev/null)
fi

if [ -z "$RESPONSE" ]; then
  echo "  [ERROR] No analysis output found (expected ANALYSIS.md)"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Check 1: Identifies cluster_legacy.c as the relevant source file
found_file=$(echo "$RESPONSE" | grep -ci "cluster_legacy" || true)
check "Identifies cluster_legacy.c" "$([ "$found_file" -gt 0 ] && echo 1 || echo 0)"

# Check 2: References the failover auth epoch increment mechanism
found_failover=$(echo "$RESPONSE" | grep -ci "failover_auth_epoch\|failover_auth_sent\|clusterHandleReplicaFailover" || true)
check "References failover auth mechanism" "$([ "$found_failover" -gt 0 ] && echo 1 || echo 0)"

# Check 3: References currentEpoch increment
found_epoch=$(echo "$RESPONSE" | grep -ci "currentEpoch" || true)
check "References currentEpoch" "$([ "$found_epoch" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Explains that epoch must increment for failover to work
found_mechanism=$(echo "$RESPONSE" | grep -ci "increment.*epoch\|epoch.*increment\|epoch.*advance\|bump.*epoch\|epoch.*bump" || true)
check "Explains epoch must increment during failover" "$([ "$found_mechanism" -gt 0 ] && echo 1 || echo 0)"

# Check 5: References vote/auth request function
found_vote=$(echo "$RESPONSE" | grep -ci "clusterRequestFailoverAuth\|RequestFailoverAuth\|failover.*auth.*request\|vote.*request\|request.*vote" || true)
check "References vote/auth request function" "$([ "$found_vote" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Proposes a fix or workaround
found_fix=$(echo "$RESPONSE" | grep -ci "fix\|patch\|workaround\|solution\|restore.*increment\|re-enable\|uncomment\|add.*increment" || true)
check "Proposes a fix or workaround" "$([ "$found_fix" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
