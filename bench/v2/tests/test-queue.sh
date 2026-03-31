#!/bin/bash
# Validates Task 2 (message queue) response
# Checks GLIDE stream API usage and queue patterns
# Input: $1 = directory containing agent's code

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

echo "=== Task 2: Message Queue Validation ==="

# Collect all JS/TS source (exclude node_modules)
CODE=$(find "$DIR" -name "*.js" -o -name "*.ts" | grep -v node_modules | xargs cat 2>/dev/null)

if [ -z "$CODE" ]; then
  echo "  [ERROR] No source files found"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Check 1: Uses GlideClient (not ioredis/node-redis)
uses_glide=$(echo "$CODE" | grep -ci "GlideClient\|valkey-glide\|@valkey/valkey-glide" || true)
uses_other=$(echo "$CODE" | grep -ci "import.*ioredis\|import.*redis\|require.*ioredis\|require.*redis\"" || true)
check "Uses GLIDE client (not ioredis/node-redis)" "$([ "$uses_glide" -gt 0 ] && [ "$uses_other" -eq 0 ] && echo 1 || echo 0)"

# Check 2: XADD for producing messages
has_xadd=$(echo "$CODE" | grep -ci "xadd\|XADD\|\.xadd(" || true)
check "Uses XADD for producing messages" "$([ "$has_xadd" -gt 0 ] && echo 1 || echo 0)"

# Check 3: XGROUP CREATE for consumer groups
has_xgroup=$(echo "$CODE" | grep -ci "xgroupCreate\|XGROUP.*CREATE\|xgroup_create\|customCommand.*XGROUP" || true)
check "Uses XGROUP CREATE for consumer groups" "$([ "$has_xgroup" -gt 0 ] && echo 1 || echo 0)"

# Check 4: XREADGROUP for consuming (not plain XREAD)
has_xreadgroup=$(echo "$CODE" | grep -ci "xreadgroup\|XREADGROUP\|xread.*group\|customCommand.*XREADGROUP" || true)
check "Uses XREADGROUP for consuming" "$([ "$has_xreadgroup" -gt 0 ] && echo 1 || echo 0)"

# Check 5: XACK for acknowledgment
has_xack=$(echo "$CODE" | grep -ci "xack\|XACK\|\.xack(" || true)
check "Uses XACK for message acknowledgment" "$([ "$has_xack" -gt 0 ] && echo 1 || echo 0)"

# Check 6: Dead letter queue (XPENDING + XCLAIM or XAUTOCLAIM)
has_pending=$(echo "$CODE" | grep -ci "xpending\|XPENDING\|xautoclaim\|XAUTOCLAIM" || true)
has_claim=$(echo "$CODE" | grep -ci "xclaim\|XCLAIM\|xautoclaim\|XAUTOCLAIM" || true)
check "Dead letter handling (XPENDING/XCLAIM)" "$([ "$has_pending" -gt 0 ] && [ "$has_claim" -gt 0 ] && echo 1 || echo 0)"

# Check 7: Multiple workers (3 concurrent consumers)
has_workers=$(echo "$CODE" | grep -ci "worker.*1\|worker.*2\|worker.*3\|workers\[.*\]\|Promise\.all.*worker\|concurrent.*worker\|consumer.*name" || true)
check "Multiple concurrent workers" "$([ "$has_workers" -gt 0 ] && echo 1 || echo 0)"

# Check 8: Graceful shutdown (SIGTERM/SIGINT handling)
has_shutdown=$(echo "$CODE" | grep -ci "SIGTERM\|SIGINT\|graceful.*shut\|process\.on" || true)
check "Graceful shutdown handling" "$([ "$has_shutdown" -gt 0 ] && echo 1 || echo 0)"

# Check 9: Dashboard/status (XLEN or XPENDING for monitoring)
has_dashboard=$(echo "$CODE" | grep -ci "xlen\|XLEN\|dashboard\|status\|pending.*count\|stream.*length" || true)
check "Dashboard/monitoring (XLEN/XPENDING)" "$([ "$has_dashboard" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
