#!/usr/bin/env bash
set -uo pipefail

# Test harness for Task 7: valkey-search Query Debug
# Usage: test.sh <work_dir>

WORK_DIR="${1:-.}"

cleanup() { cd "$WORK_DIR"; docker compose down -v --remove-orphans 2>/dev/null || true; }
trap cleanup EXIT

PASS=0
FAIL=0

check() {
  local label="$1"
  local result="$2"
  if [[ "$result" == "true" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

cd "$WORK_DIR" || exit 1

# Start services if not running
docker compose up -d --wait 2>/dev/null || true
python3 setup.py > /dev/null 2>&1 || true

# Run the fixed queries and capture output
QUERY_OUTPUT=$(python3 queries.py 2>&1)

# -----------------------------------------------------------------------
# Test 1: Query 1 returns >0 matches (full-text search on name field)
# -----------------------------------------------------------------------
Q1_MATCHES=$(echo "$QUERY_OUTPUT" | grep -A2 "Find products with" | grep -oP 'Results: \K\d+' || echo "0")
check "Query 1: full-text search returns >0 matches" \
  "$([ "$Q1_MATCHES" -gt 0 ] 2>/dev/null && echo true || echo false)"

# -----------------------------------------------------------------------
# Test 2: Query 2 returns records in price range 100-500
# The fixed query should use correct numeric filter syntax
# -----------------------------------------------------------------------
Q2_MATCHES=$(echo "$QUERY_OUTPUT" | grep -A2 "Products priced between" | grep -oP 'Results: \K\d+' || echo "0")
check "Query 2: numeric range returns >0 matches" \
  "$([ "$Q2_MATCHES" -gt 0 ] 2>/dev/null && echo true || echo false)"

# Verify prices are actually in range by spot-checking via valkey-cli
Q2_VERIFY=$(python3 -c "
import valkey
c = valkey.Valkey(host='localhost', port=6408, decode_responses=True)
res = c.execute_command('FT.SEARCH', 'products', '@price:[100 500]', 'LIMIT', '0', '5')
if not isinstance(res, list) or res[0] == 0:
    print('empty')
else:
    prices = []
    for i in range(1, len(res), 2):
        if i+1 < len(res):
            fields = res[i+1]
            for j in range(0, len(fields), 2):
                if fields[j] == 'price':
                    prices.append(float(fields[j+1]))
    in_range = all(100 <= p <= 500 for p in prices)
    print('ok' if in_range and prices else 'bad')
" 2>/dev/null || echo "error")
check "Query 2: returned prices are within 100-500 range" \
  "$([ "$Q2_VERIFY" == "ok" ] && echo true || echo false)"

# -----------------------------------------------------------------------
# Test 3: Query 3 matches correct tag (case-sensitive Electronics)
# -----------------------------------------------------------------------
Q3_MATCHES=$(echo "$QUERY_OUTPUT" | grep -A2 "Products in Electronics" | grep -oP 'Results: \K\d+' || echo "0")
check "Query 3: tag filter returns >0 matches" \
  "$([ "$Q3_MATCHES" -gt 0 ] 2>/dev/null && echo true || echo false)"

# -----------------------------------------------------------------------
# Test 4: Query 4 returns 5 similar items (KNN vector search)
# -----------------------------------------------------------------------
Q4_MATCHES=$(echo "$QUERY_OUTPUT" | grep -A2 "Find 5 similar products by vector" | grep -oP 'Results: \K\d+' || echo "0")
check "Query 4: KNN vector search returns 5 matches" \
  "$([ "$Q4_MATCHES" -eq 5 ] 2>/dev/null && echo true || echo false)"

# -----------------------------------------------------------------------
# Test 5: Query 5 aggregate has both total and count per category
# -----------------------------------------------------------------------
Q5_HAS_TOTAL=$(echo "$QUERY_OUTPUT" | grep -c "total" || echo "0")
Q5_HAS_COUNT=$(echo "$QUERY_OUTPUT" | grep -c "count" || echo "0")
check "Query 5: aggregate output includes total and count" \
  "$([ "$Q5_HAS_TOTAL" -gt 0 ] && [ "$Q5_HAS_COUNT" -gt 0 ] && echo true || echo false)"

# -----------------------------------------------------------------------
# Test 6: FIXES.md exists with 5 explanations
# -----------------------------------------------------------------------
if [[ -f "FIXES.md" ]]; then
  SECTION_COUNT=$(grep -cP '^#{1,3}\s.*[Qq]uery\s*[1-5]' FIXES.md 2>/dev/null || echo "0")
  check "FIXES.md exists with 5 query sections" \
    "$([ "$SECTION_COUNT" -ge 5 ] && echo true || echo false)"
else
  check "FIXES.md exists with 5 query sections" "false"
fi

# -----------------------------------------------------------------------
# Test 7: No schema recreation (FT.DROPINDEX not called in queries.py)
# -----------------------------------------------------------------------
DROP_COUNT=$(grep -c "FT.DROPINDEX\|FT.DROP\|DROPINDEX\|FT.CREATE" "$WORK_DIR/queries.py" 2>/dev/null || echo "0")
check "No schema recreation in queries.py" \
  "$([ "$DROP_COUNT" -eq 0 ] && echo true || echo false)"

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed out of $((PASS + FAIL)) checks"
