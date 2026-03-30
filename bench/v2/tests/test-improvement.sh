#!/bin/bash
# Validates Task 4 (code improvement) response
# Checks which anti-patterns were fixed
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

# Get the improved code
CODE=$(find "$DIR" -name "app.js" -o -name "app.ts" | xargs cat 2>/dev/null)
ALL=$(find "$DIR" -name "*.js" -o -name "*.ts" -o -name "*.md" | xargs cat 2>/dev/null)

# Check 1: KEYS replaced with SCAN
still_has_keys=$(echo "$CODE" | grep -c '"KEYS"' || true)
has_scan=$(echo "$ALL" | grep -ci "SCAN\|scan\|customCommand.*SCAN" || true)
check "KEYS replaced with SCAN" "$([ "$still_has_keys" -eq 0 ] && [ "$has_scan" -gt 0 ] && echo 1 || echo 0)"

# Check 2: DEL replaced with UNLINK (or explained)
has_unlink=$(echo "$ALL" | grep -ci "unlink\|UNLINK" || true)
check "DEL replaced with UNLINK" "$([ "$has_unlink" -gt 0 ] && echo 1 || echo 0)"

# Check 3: Promise.all(GET) replaced with MGET
has_mget=$(echo "$ALL" | grep -ci "mget\|MGET" || true)
check "Individual GETs replaced with MGET" "$([ "$has_mget" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Sequential SET replaced with batch/pipeline
has_batch=$(echo "$ALL" | grep -ci "Batch\|batch\|pipeline\|Pipeline" || true)
check "Sequential writes use batching/pipeline" "$([ "$has_batch" -gt 0 ] && echo 1 || echo 0)"

# Check 5: Cache entries have TTL
has_ttl=$(echo "$CODE" | grep -ci "expire\|ttl\|EX\|PX\|expiry\|setex\|options.*expire" || true)
check "Cache entries have TTL" "$([ "$has_ttl" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Connection error handling added
has_error_handling=$(echo "$CODE" | grep -ci "try.*catch\|reconnect\|connectionBackoff\|ClosingError\|ConnectionError" || true)
check "Connection error handling" "$([ "$has_error_handling" -gt 0 ] && echo 1 || echo 0)"

# Check 7: SORT anti-pattern addressed
has_sorted_set=$(echo "$ALL" | grep -ci "sorted.*set\|zrange\|ZRANGEBYSCORE\|zadd\|ZADD\|search\|FT\." || true)
check "SORT replaced with sorted set or search" "$([ "$has_sorted_set" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
