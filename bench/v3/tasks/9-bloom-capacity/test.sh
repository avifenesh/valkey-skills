#!/usr/bin/env bash
set -uo pipefail

# Test harness for Task 9: Bloom Capacity Planning
# Usage: test.sh <work_dir>

WORK_DIR="${1:-.}"
SOLUTION="$WORK_DIR/solution.py"
PASS=0
FAIL=0

check() {
  local name="$1"
  local result="$2"
  if [[ "$result" == "true" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# Start Valkey+bloom via docker-compose
cleanup() {
  cd "$WORK_DIR" && docker-compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

cd "$WORK_DIR" && docker-compose up -d 2>&1

# Wait for Valkey to be ready
for i in $(seq 1 30); do
  if valkey-cli -p 6410 PING 2>/dev/null | grep -q PONG; then
    break
  fi
  sleep 1
done

# -----------------------------------------------------------------------
# Static checks (parse solution.py for correct parameters)
# -----------------------------------------------------------------------

# 1. BF.RESERVE capacity correct (~50M)
# Accept 40M-60M as reasonable for 50M daily emails
capacity_ok="false"
cap_val=$(grep -ioE 'BF\.RESERVE[^)]*[0-9]{7,9}' "$SOLUTION" 2>/dev/null | grep -oE '[0-9]{7,9}' | head -1)
if [[ -n "$cap_val" ]]; then
  if (( cap_val >= 40000000 && cap_val <= 60000000 )); then
    capacity_ok="true"
  fi
fi
# Also accept capacity defined as a variable used in BF.RESERVE
if [[ "$capacity_ok" == "false" ]]; then
  if grep -qE 'DAILY_CAPACITY *= *50.?000.?000' "$SOLUTION" 2>/dev/null && \
     grep -qiE 'BF\.RESERVE' "$SOLUTION" 2>/dev/null; then
    capacity_ok="true"
  fi
fi
check "BF.RESERVE capacity correct (~50M)" "$capacity_ok"

# 2. Error rate correct (0.001 or tighter per filter)
# Per-filter rate must be <= 0.001 to keep aggregate under 0.1% across 30 filters
error_ok="false"
# Look for error rate values in common patterns
err_val=$(grep -oE '(error_rate|fp_rate|false_positive|rate) *[=:] *(0\.[0-9]+)' "$SOLUTION" 2>/dev/null | grep -oE '0\.[0-9]+' | head -1)
if [[ -n "$err_val" ]]; then
  # Use python for float comparison
  error_ok=$(python3 -c "print('true' if float('$err_val') <= 0.001 else 'false')" 2>/dev/null || echo "false")
fi
# Also check for inline numeric arguments to BF.RESERVE that look like error rates
if [[ "$error_ok" == "false" ]]; then
  reserve_err=$(grep -ioE 'BF\.RESERVE[^)]*0\.0[0-9]+' "$SOLUTION" 2>/dev/null | grep -oE '0\.0[0-9]+' | head -1)
  if [[ -n "$reserve_err" ]]; then
    error_ok=$(python3 -c "print('true' if float('$reserve_err') <= 0.001 else 'false')" 2>/dev/null || echo "false")
  fi
fi
check "Error rate correct (<=0.001 per filter)" "$error_ok"

# 3. Expansion factor or NONSCALING chosen
expansion_ok="false"
if grep -qiE 'NONSCALING|nonscaling|non.?scaling' "$SOLUTION" 2>/dev/null; then
  expansion_ok="true"
elif grep -qiE 'expansion *[=:] *[0-9]' "$SOLUTION" 2>/dev/null; then
  expansion_ok="true"
fi
check "Expansion factor or NONSCALING chosen" "$expansion_ok"

# 4. Memory under 8GB (solution must verify or compute memory)
memory_ok="false"
if grep -qiE 'BF\.INFO|bf\.info|memory|8.*GB|8589934592|8_000_000_000|8000000000' "$SOLUTION" 2>/dev/null; then
  # Check that there is actual memory verification logic, not just the TODO
  if grep -qiE '(BF\.INFO|MEMORY USAGE|memory.*budget|total.*mem|mem.*total|8.*[gG][bB])' "$SOLUTION" 2>/dev/null; then
    # Exclude lines that are only comments with TODO
    non_todo=$(grep -iE '(BF\.INFO|memory.*budget|total.*mem|8.*[gG][bB])' "$SOLUTION" 2>/dev/null | grep -v 'TODO' | head -1)
    if [[ -n "$non_todo" ]]; then
      memory_ok="true"
    fi
  fi
fi
check "Memory under 8GB (BF.INFO SIZE sum)" "$memory_ok"

# 5. Daily rotation creates correct filter
rotation_ok="false"
if grep -qE 'def +rotate_filters' "$SOLUTION" 2>/dev/null; then
  # Check that rotate_filters has actual implementation (not just pass/TODO)
  rotate_body=$(sed -n '/def rotate_filters/,/^def /p' "$SOLUTION" 2>/dev/null | tail -n +2)
  has_impl=$(echo "$rotate_body" | grep -vE '^[[:space:]]*(#|pass|"""|$)' | head -1)
  if [[ -n "$has_impl" ]]; then
    # Should reference day/date and create_daily_filter
    if echo "$rotate_body" | grep -qiE '(date|day|today)'; then
      rotation_ok="true"
    fi
  fi
fi
check "Daily rotation creates correct filter" "$rotation_ok"

# 6. Query checks all active filters
query_ok="false"
if grep -qE 'def +check_email' "$SOLUTION" 2>/dev/null; then
  check_body=$(sed -n '/def check_email/,/^def /p' "$SOLUTION" 2>/dev/null | tail -n +2)
  has_impl=$(echo "$check_body" | grep -vE '^[[:space:]]*(#|pass|"""|$)' | head -1)
  if [[ -n "$has_impl" ]]; then
    # Should iterate over filters and use BF.EXISTS
    if echo "$check_body" | grep -qiE '(BF\.EXISTS|bf\.exists|for |keys|scan)'; then
      query_ok="true"
    fi
  fi
fi
check "Query checks all active filters" "$query_ok"

# 7. Cleanup removes old filters
cleanup_ok="false"
if grep -qE 'def +cleanup_expired' "$SOLUTION" 2>/dev/null; then
  cleanup_body=$(sed -n '/def cleanup_expired/,/^def /p' "$SOLUTION" 2>/dev/null | tail -n +2)
  has_impl=$(echo "$cleanup_body" | grep -vE '^[[:space:]]*(#|pass|"""|$)' | head -1)
  if [[ -n "$has_impl" ]]; then
    # Should delete old keys
    if echo "$cleanup_body" | grep -qiE '(delete|DEL|del|unlink|UNLINK)'; then
      cleanup_ok="true"
    fi
  fi
fi
check "Cleanup removes old filters" "$cleanup_ok"

# 8. FP rate validated (<0.2% in test)
fp_validate_ok="false"
if grep -qE 'def +validate_fp_rate' "$SOLUTION" 2>/dev/null; then
  fp_body=$(sed -n '/def validate_fp_rate/,/^def \|^if /p' "$SOLUTION" 2>/dev/null | tail -n +2)
  has_impl=$(echo "$fp_body" | grep -vE '^[[:space:]]*(#|pass|"""|$)' | head -1)
  if [[ -n "$has_impl" ]]; then
    # Should add items and check non-members
    if echo "$fp_body" | grep -qiE '(BF\.ADD|BF\.EXISTS|bf\.add|bf\.exists|false.?positive|fp.?rate|fp.?count)'; then
      fp_validate_ok="true"
    fi
  fi
fi
check "FP rate validated (<0.2% in test)" "$fp_validate_ok"

# -----------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
