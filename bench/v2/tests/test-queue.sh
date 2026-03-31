#!/bin/bash
# Validates Task 2 (message queue) - runs the actual queue against real Valkey
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

cd "$DIR"

# Clean any leftover Docker state from previous runs
docker compose down -v 2>/dev/null || true

# --- Static checks (3) ---

CODE=$(find "$DIR" -name "*.js" -o -name "*.ts" | grep -v node_modules | xargs cat 2>/dev/null)

if [ -z "$CODE" ]; then
  echo "  [ERROR] No source files found"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Check 1: Uses GLIDE (not ioredis/node-redis)
uses_glide=$(echo "$CODE" | grep -ci "GlideClient\|valkey-glide\|@valkey/valkey-glide" || true)
uses_other=$(echo "$CODE" | grep -ci "import.*ioredis\|import.*redis\|require.*ioredis\|require.*\"redis\"" || true)
check "Uses GLIDE client (not ioredis/node-redis)" "$([ "$uses_glide" -gt 0 ] && [ "$uses_other" -eq 0 ] && echo 1 || echo 0)"

# Check 2: Has consumer group code (XGROUP + XREADGROUP + XACK)
has_xgroup=$(echo "$CODE" | grep -ci "xgroupCreate\|XGROUP\|customCommand.*XGROUP" || true)
has_xreadgroup=$(echo "$CODE" | grep -ci "xreadgroup\|XREADGROUP\|customCommand.*XREADGROUP" || true)
has_xack=$(echo "$CODE" | grep -ci "xack\|XACK" || true)
check "Consumer group APIs (XGROUP + XREADGROUP + XACK)" "$([ "$has_xgroup" -gt 0 ] && [ "$has_xreadgroup" -gt 0 ] && [ "$has_xack" -gt 0 ] && echo 1 || echo 0)"

# Check 3: Dead letter handling (XPENDING + XCLAIM/XAUTOCLAIM)
has_dlq=$(echo "$CODE" | grep -ci "xpending\|XPENDING\|xclaim\|XCLAIM\|xautoclaim\|XAUTOCLAIM" || true)
check "Dead letter handling (XPENDING/XCLAIM)" "$([ "$has_dlq" -gt 0 ] && echo 1 || echo 0)"

# --- Runtime checks (6) ---

# Start Valkey and the app
echo "  Starting docker compose..."
docker compose up -d --build 2>/dev/null

# Wait for Valkey to be ready
for i in $(seq 1 15); do
  docker compose exec -T valkey valkey-cli PING 2>/dev/null | grep -q PONG && break
  sleep 1
done

# Check 4: Valkey is running
valkey_up=$(docker compose exec -T valkey valkey-cli PING 2>/dev/null | grep -c PONG || true)
check "Valkey is running" "$([ "$valkey_up" -gt 0 ] && echo 1 || echo 0)"

if [ "$valkey_up" -eq 0 ]; then
  echo "  Valkey not running, skipping runtime checks"
  FAIL=$((FAIL + 5))
  echo ""
  echo "Result: $PASS/$TOTAL passed"
  echo "SCORE=$PASS/$TOTAL"
  docker compose down -v 2>/dev/null
  exit 0
fi

# Wait for the app to produce and consume messages (up to 30s)
echo "  Waiting for queue processing (30s max)..."
for i in $(seq 1 30); do
  stream_len=$(docker compose exec -T valkey valkey-cli XLEN tasks:queue 2>/dev/null | tr -d '[:space:]' || echo "0")
  [ "$stream_len" != "0" ] && break
  sleep 1
done

# Check 5: Stream exists with messages produced (XLEN > 0 or messages were consumed)
stream_exists=$(docker compose exec -T valkey valkey-cli EXISTS tasks:queue 2>/dev/null | tr -d '[:space:]' || echo "0")
xlen=$(docker compose exec -T valkey valkey-cli XLEN tasks:queue 2>/dev/null | tr -d '[:space:]' || echo "0")
check "Stream exists (tasks:queue)" "$([ "$stream_exists" = "1" ] && echo 1 || echo 0)"

# Check 6: Consumer group was created
groups=$(docker compose exec -T valkey valkey-cli XINFO GROUPS tasks:queue 2>/dev/null | grep -c "name" || true)
check "Consumer group created" "$([ "$groups" -gt 0 ] && echo 1 || echo 0)"

# Check 7: Messages were consumed (check pending or acked)
xinfo=$(docker compose exec -T valkey valkey-cli XINFO GROUPS tasks:queue 2>/dev/null)
consumers=$(echo "$xinfo" | grep -c "consumers" || true)
# Also check if there are consumers registered
consumer_count=$(docker compose exec -T valkey valkey-cli XINFO CONSUMERS tasks:queue workers 2>/dev/null | grep -c "name" || true)
check "Consumers registered ($consumer_count)" "$([ "$consumer_count" -gt 0 ] && echo 1 || echo 0)"

# Check 8: Multiple workers (at least 2 consumers)
check "Multiple workers (>= 2 consumers)" "$([ "$consumer_count" -ge 2 ] && echo 1 || echo 0)"

# Check 9: Some messages were acknowledged (delivered count > 0 in group info)
delivered=$(docker compose exec -T valkey valkey-cli XINFO GROUPS tasks:queue 2>/dev/null | grep -A1 "last-delivered-id" | tail -1 | tr -d '[:space:]' || echo "0-0")
check "Messages delivered (last-delivered-id != 0-0)" "$([ "$delivered" != "0-0" ] && [ -n "$delivered" ] && echo 1 || echo 0)"

# Cleanup
docker compose down -v 2>/dev/null

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
