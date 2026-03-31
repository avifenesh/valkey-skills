#!/bin/bash
# Validates Task 4 (Java code improvement) response
# Checks which anti-patterns were fixed in the actual code
# Input: $1 = directory containing agent's improved code

DIR="$1"
PASS=0
FAIL=0
TOTAL=9

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

# Check Java source files (exclude node_modules, .mvn)
CODE=$(find "$DIR/src" -name "*.java" 2>/dev/null | xargs cat 2>/dev/null)

if [ -z "$CODE" ]; then
  echo "  [ERROR] No Java source files found"
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

# Check 3: Individual GETs replaced with MGET
has_mget=$(echo "$CODE" | grep -ci "\.mget\|\"MGET\"" || true)
check "Individual GETs replaced with MGET" "$([ "$has_mget" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Sequential SET replaced with batch/pipeline
has_batch=$(echo "$CODE" | grep -ci "Batch\|\.exec(\|batch(" || true)
check "Sequential writes use batching" "$([ "$has_batch" -gt 0 ] && echo 1 || echo 0)"

# Check 5: Cache entries have TTL
has_ttl=$(echo "$CODE" | grep -ci "expire\|ttl\|\.pexpire\|\.expire\|SetOptions.*expiry\|Expiry\|\"EX\"\|\"PX\"" || true)
check "Cache entries have TTL" "$([ "$has_ttl" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Session data has TTL/expiry
has_session_ttl=$(echo "$CODE" | grep -B5 -A5 "session" | grep -ci "expire\|ttl\|Expiry\|\"EX\"\|\"PX\"" || true)
check "Session data has TTL" "$([ "$has_session_ttl" -gt 0 ] && echo 1 || echo 0)"

# Check 7: Connection error handling
has_error_handling=$(echo "$CODE" | grep -ci "try.*createClient\|catch.*Exception\|connectionBackoff\|reconnect\|retry" || true)
has_try_create=$(echo "$CODE" | grep -B2 -A2 "createClient" | grep -ci "try\|catch" || true)
check "Connection error handling" "$([ "$has_error_handling" -gt 0 ] || [ "$has_try_create" -gt 0 ] && echo 1 || echo 0)"

# Check 8: SORT replaced with sorted set (ZADD/ZRANGE)
has_sorted_set=$(echo "$CODE" | grep -ci "zadd\|zrange\|ZADD\|ZRANGE\|\"ZRANGEBYSCORE\"\|customCommand.*ZADD\|customCommand.*ZRANGE" || true)
check "SORT replaced with sorted set" "$([ "$has_sorted_set" -gt 0 ] && echo 1 || echo 0)"

# Check 9: Category counting uses secondary index or set, not full scan
no_full_scan=$(echo "$CODE" | grep -A10 "countProducts" | grep -ci "SCARD\|SMEMBERS\|FT\.SEARCH\|scard\|secondary.*index\|category:.*set" || true)
check "Category count uses index/set instead of full scan" "$([ "$no_full_scan" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
