#!/bin/bash
# Validates Task 2 (distributed lock) response
# Checks compilation and correct API usage
# Input: $1 = directory containing agent's modified project

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

echo "=== Task 2: Distributed Lock Validation ==="

# Collect all Java source files
SRC=$(find "$DIR" -name "*.java" | xargs cat 2>/dev/null)

# Check 1: Uses GlideClient or GlideClusterClient (not Jedis/Lettuce)
uses_glide=$(echo "$SRC" | grep -c "GlideClient\|GlideClusterClient" || true)
uses_jedis=$(echo "$SRC" | grep -c "import redis\.clients\|import io\.lettuce" || true)
check "Uses GLIDE client (not Jedis/Lettuce)" "$([ "$uses_glide" -gt 0 ] && [ "$uses_jedis" -eq 0 ] && echo 1 || echo 0)"

# Check 2: SET with NX option (not deprecated SETNX)
uses_nx=$(echo "$SRC" | grep -ci "ConditionalSet\|SetOptions.*nx\|NX\|conditionalSet\|\.set(.*nx" || true)
uses_setnx=$(echo "$SRC" | grep -c "\.setnx\b\|SETNX" || true)
check "Uses SET NX (not deprecated SETNX)" "$([ "$uses_nx" -gt 0 ] && [ "$uses_setnx" -eq 0 ] && echo 1 || echo 0)"

# Check 3: TTL on lock (EX or PX option)
has_ttl=$(echo "$SRC" | grep -ci "expiry\|TimeUnit\|\.EX\|\.PX\|ttl\|expire\|Expiry\|setex\|timeout.*millisec\|timeout.*sec" || true)
check "Lock has TTL-based expiration" "$([ "$has_ttl" -gt 0 ] && echo 1 || echo 0)"

# Check 4: Owner identification (stores unique value, not just "1" or "locked")
has_owner=$(echo "$SRC" | grep -ci "uuid\|UUID\|randomUUID\|owner\|token\|identifier\|threadId\|requestId" || true)
check "Owner identification (UUID/token)" "$([ "$has_owner" -gt 0 ] && echo 1 || echo 0)"

# Check 5: Safe release (compare-and-delete, not plain DEL)
has_safe_release=$(echo "$SRC" | grep -ci "IFEQ\|ifeq\|lua\|EVAL\|eval\|compare.*delete\|check.*value.*del\|customCommand.*EVAL" || true)
has_plain_del=$(echo "$SRC" | grep -c "\.del\b.*lock\|\.del(\[" || true)
check "Safe release (compare-and-delete)" "$([ "$has_safe_release" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Retry with backoff
has_retry=$(echo "$SRC" | grep -ci "retry\|backoff\|sleep\|Thread\.sleep\|exponential\|attempt\|maxRetries\|retryCount" || true)
check "Retry with backoff" "$([ "$has_retry" -gt 0 ] && echo 1 || echo 0)"

# Check 7: Compilation check (if mvnw available)
if [ -f "$DIR/mvnw" ]; then
  cd "$DIR"
  compile_result=$(./mvnw compile -q 2>&1; echo $?)
  last_line=$(echo "$compile_result" | tail -1)
  check "Code compiles (mvn compile)" "$([ "$last_line" -eq 0 ] && echo 1 || echo 0)"
  cd - > /dev/null
else
  echo "  [SKIP] Compilation (no mvnw)"
  TOTAL=$((TOTAL - 1))
fi

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
