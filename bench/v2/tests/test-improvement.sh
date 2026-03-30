#!/bin/bash
# Validates Task 4 (code improvement) response
# Checks which anti-patterns were fixed in the actual code
# Input: $1 = directory containing agent's improved code

DIR="$1"
PASS=0
FAIL=0
TOTAL=7

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

echo "=== Task 4: Code Improvement Validation ==="

# Only check the actual code file, not docs/READMEs
CODE=$(cat "$DIR/app.js" "$DIR/app.ts" 2>/dev/null)

if [ -z "$CODE" ]; then
  echo "  [ERROR] No app.js or app.ts found"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Check 1: KEYS replaced with SCAN
still_has_keys=$(echo "$CODE" | grep -c '"KEYS"' || true)
has_scan=$(echo "$CODE" | grep -ci '"SCAN"\|customCommand.*SCAN\|\.scan(' || true)
check "KEYS replaced with SCAN" "$([ "$still_has_keys" -eq 0 ] && [ "$has_scan" -gt 0 ] && echo 1 || echo 0)"

# Check 2: DEL replaced with UNLINK
has_unlink=$(echo "$CODE" | grep -ci "\.unlink\|\"UNLINK\"" || true)
check "DEL replaced with UNLINK" "$([ "$has_unlink" -gt 0 ] && echo 1 || echo 0)"

# Check 3: Promise.all(GET) replaced with MGET
has_mget=$(echo "$CODE" | grep -ci "\.mget\|\"MGET\"" || true)
check "Individual GETs replaced with MGET" "$([ "$has_mget" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Sequential SET replaced with batch/pipeline (in code, not comments)
has_batch=$(echo "$CODE" | grep -ci "new Batch\|\.exec(\|pipeline\|\.batch(" || true)
still_sequential=$(echo "$CODE" | grep -c "for.*await.*client\.set\|for.*of.*await.*\.set(" || true)
check "Sequential writes use batching" "$([ "$has_batch" -gt 0 ] || [ "$still_sequential" -eq 0 ] && echo 1 || echo 0)"

# Check 5: Cache entries have TTL (in SET calls, not just comments)
has_ttl=$(echo "$CODE" | grep -ci "conditionalSet\|options.*expire\|\.setex\|\.set(.*{.*expiry\|\"EX\"\|\"PX\"" || true)
check "Cache entries have TTL" "$([ "$has_ttl" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Connection error handling
has_error_handling=$(echo "$CODE" | grep -ci "try {.*createClient\|catch.*ConnectionError\|catch.*ClosingError\|connectionBackoff\|\.on.*error" || true)
# Also check for try/catch wrapping the client creation
has_try_create=$(echo "$CODE" | grep -B2 -A2 "createClient" | grep -ci "try\|catch" || true)
check "Connection error handling" "$([ "$has_error_handling" -gt 0 ] || [ "$has_try_create" -gt 0 ] && echo 1 || echo 0)"

# Check 7: SORT anti-pattern addressed (use server-side sorted sets or search)
has_server_sort=$(echo "$CODE" | grep -ci "zadd\|zrange\|ZADD\|ZRANGE\|FT\.SEARCH\|FT\.CREATE\|customCommand.*ZADD\|customCommand.*ZRANGE" || true)
check "Client-side sort replaced with server-side structure" "$([ "$has_server_sort" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
