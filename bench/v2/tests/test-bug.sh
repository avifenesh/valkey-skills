#!/bin/bash
# Validates Task 1 (bug investigation) response
# Checks both analysis quality AND presence of a concrete fix
# Input: $1 = directory containing agent's response

DIR="$1"
PASS=0
FAIL=0
TOTAL=8

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
  RESPONSE=$(find "$DIR" -maxdepth 1 \( -name "*.md" -o -name "*.txt" \) ! -name "symptoms.md" ! -name "README.md" -exec cat {} + 2>/dev/null)
fi

if [ -z "$RESPONSE" ]; then
  echo "  [ERROR] No analysis output found (expected ANALYSIS.md)"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Also check for .patch or .diff files
PATCH_FILES=$(find "$DIR" -maxdepth 1 \( -name "*.patch" -o -name "*.diff" \) -exec cat {} + 2>/dev/null)
ALL="$RESPONSE $PATCH_FILES"

# --- Analysis checks ---

# Check 1: Identifies cluster_legacy.c
found_file=$(echo "$ALL" | grep -ci "cluster_legacy" || true)
check "Identifies cluster_legacy.c" "$([ "$found_file" -gt 0 ] && echo 1 || echo 0)"

# Check 2: References failover auth mechanism
found_failover=$(echo "$ALL" | grep -ci "failover_auth_epoch\|failover_auth_sent\|clusterHandleReplicaFailover" || true)
check "References failover auth mechanism" "$([ "$found_failover" -gt 0 ] && echo 1 || echo 0)"

# Check 3: References currentEpoch
found_epoch=$(echo "$ALL" | grep -ci "currentEpoch" || true)
check "References currentEpoch" "$([ "$found_epoch" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Explains epoch must increment
found_mechanism=$(echo "$ALL" | grep -ci "increment.*epoch\|epoch.*increment\|epoch.*advance\|bump.*epoch\|epoch.*bump" || true)
check "Explains epoch must increment during failover" "$([ "$found_mechanism" -gt 0 ] && echo 1 || echo 0)"

# Check 5: References vote/auth request function
found_vote=$(echo "$ALL" | grep -ci "clusterRequestFailoverAuth\|RequestFailoverAuth\|failover.*auth.*request\|request.*vote" || true)
check "References vote/auth request function" "$([ "$found_vote" -gt 0 ] && echo 1 || echo 0)"

# --- Fix checks ---

# Check 6: Contains a concrete code fix (diff, sed, or actual C code)
has_diff=$(echo "$ALL" | grep -ci "^diff\|^---.*cluster_legacy\|^+++.*cluster_legacy\|@@.*@@" || true)
has_sed=$(echo "$ALL" | grep -ci "sed.*currentEpoch\|sed.*cluster_legacy" || true)
has_code_fix=$(echo "$ALL" | grep -ci "server\.cluster->currentEpoch++\|server\.cluster->currentEpoch ++" || true)
check "Contains concrete code fix (diff/sed/C code)" "$([ "$has_diff" -gt 0 ] || [ "$has_sed" -gt 0 ] || [ "$has_code_fix" -gt 0 ] && echo 1 || echo 0)"

# Check 7: Fix targets the correct location (failover auth block, not other epoch increments)
has_correct_location=$(echo "$ALL" | grep -ci "failover_auth_sent.*currentEpoch\|currentEpoch.*failover_auth\|before.*RequestFailoverAuth\|before.*requesting.*vote" || true)
check "Fix targets correct location (failover auth block)" "$([ "$has_correct_location" -gt 0 ] && echo 1 || echo 0)"

# Check 8: Fix is not just "undo the Dockerfile" or "use stock image"
is_docker_workaround=$(echo "$ALL" | grep -ci "remove.*sed\|undo.*patch\|remove.*Dockerfile\|use.*official.*image\|use.*stock" || true)
has_real_fix=$(echo "$ALL" | grep -ci "restore.*increment\|add.*currentEpoch++\|uncomment.*currentEpoch\|re-enable.*increment\|patch.*source" || true)
check "Fix is a source code change (not Docker workaround)" "$([ "$has_real_fix" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
