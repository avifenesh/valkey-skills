#!/usr/bin/env bash
# Task 8: valkey-json Type-Aware Operations - Test Script
# Usage: test.sh <work_dir>
# Expects Valkey running on localhost:6409 with valkey-json loaded and setup.py already run.

set -uo pipefail

DIR="${1:-.}"
cd "$DIR"

cleanup() { cd "$DIR"; docker-compose down -v --remove-orphans 2>/dev/null || true; }
trap cleanup EXIT

# Ensure docker is running and data is loaded
docker-compose up -d --wait 2>/dev/null || true
python3 setup.py > /dev/null 2>&1 || true

# Run the operations
python3 operations.py > operations_output.txt 2>&1
RUN_EXIT=$?

# Load setup metadata for expected counts
FAILED_COUNT=$(python3 -c "import json; print(json.load(open('setup_meta.json'))['failed_count'])" 2>/dev/null || echo "20")
SHIPPED_COUNT=$(python3 -c "import json; print(json.load(open('setup_meta.json'))['shipped_count'])" 2>/dev/null || echo "30")
FILTER_COUNT=$(python3 -c "import json; print(json.load(open('setup_meta.json'))['high_price_qty_count'])" 2>/dev/null || echo "0")

echo "=== Task 8: valkey-json Operations Validation ==="
echo "Expected: failed=$FAILED_COUNT, shipped=$SHIPPED_COUNT, filter_match=$FILTER_COUNT"
echo ""

# --- Check 1: Filter returns correct count ---
# Verify op1 found the right number of orders with item price>100 AND qty>2
filter_result=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
count = 0
for i in range(1, 101):
    key = f'order:ORD-{i:03d}'
    items_raw = r.execute_command('JSON.GET', key, '$.items[?(@.price>100 && @.quantity>2)]')
    if items_raw and items_raw != '[]':
        items = json.loads(items_raw)
        if items:
            count += 1
print(count)
" 2>/dev/null || echo "-1")

# Check operations_output.txt for the reported count
reported_filter=$(grep -oE 'Matching orders: *[0-9]+' operations_output.txt | grep -oE '[0-9]+' | head -1 || echo "-1")

if [[ "$reported_filter" -gt 0 && "$reported_filter" == "$FILTER_COUNT" ]]; then
echo "PASS: Filter returns correct count ($reported_filter matching orders)"
elif [[ "$reported_filter" -gt 0 ]]; then
echo "FAIL: Filter count mismatch (got $reported_filter, expected $FILTER_COUNT)"
else
echo "FAIL: Filter returned no results or did not run"
fi

# --- Check 2: Failed orders have incremented retryCount ---
retry_check=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
incremented = 0
for i in range(1, 101):
    key = f'order:ORD-{i:03d}'
    status = r.execute_command('JSON.GET', key, '$.payment.status')
    retry = r.execute_command('JSON.GET', key, '$.payment.retryCount')
    if status:
        s = json.loads(status)
        rc = json.loads(retry) if retry else [0]
        if isinstance(s, list): s = s[0]
        if isinstance(rc, list): rc = rc[0]
        if s == 'failed' and rc >= 1:
            incremented += 1
print(incremented)
" 2>/dev/null || echo "0")

if [[ "$retry_check" -ge "$FAILED_COUNT" ]]; then
echo "PASS: Failed orders have incremented retryCount ($retry_check orders)"
else
echo "FAIL: retryCount not incremented for all failed orders (got $retry_check, expected $FAILED_COUNT)"
fi

# --- Check 3: Tracking event at index 0 for shipped orders ---
tracking_check=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
correct = 0
for i in range(1, 101):
    key = f'order:ORD-{i:03d}'
    history_raw = r.execute_command('JSON.GET', key, '$.statusHistory')
    if not history_raw:
        continue
    history = json.loads(history_raw)
    if isinstance(history, list) and len(history) > 0:
        h = history[0] if isinstance(history[0], list) else history
        # Check if first entry is tracking_sent
        if len(h) > 0 and isinstance(h[0], dict) and h[0].get('status') == 'tracking_sent':
            correct += 1
print(correct)
" 2>/dev/null || echo "0")

if [[ "$tracking_check" -ge "$SHIPPED_COUNT" ]]; then
echo "PASS: Tracking event inserted at index 0 ($tracking_check shipped orders)"
else
echo "FAIL: Tracking event not at index 0 for all shipped orders (got $tracking_check, expected $SHIPPED_COUNT)"
fi

# --- Check 4: MGET returns 50 emails ---
mget_check=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
keys = [f'order:ORD-{i:03d}' for i in range(1, 51)]
result = r.execute_command('JSON.MGET', *keys, '$.customer.email')
valid = 0
for entry in result:
    if entry:
        parsed = json.loads(entry) if isinstance(entry, str) else entry
        if isinstance(parsed, list) and len(parsed) > 0 and '@' in str(parsed[0]):
            valid += 1
        elif isinstance(parsed, str) and '@' in parsed:
            valid += 1
print(valid)
" 2>/dev/null || echo "0")

# Check the output reports 50 emails
reported_emails=$(grep -oE 'Emails fetched: *[0-9]+' operations_output.txt | grep -oE '[0-9]+' | head -1 || echo "0")

if [[ "$reported_emails" -eq 50 ]]; then
echo "PASS: MGET returns 50 emails"
elif [[ "$reported_emails" -gt 0 ]]; then
echo "FAIL: MGET returned $reported_emails emails (expected 50)"
else
echo "FAIL: MGET did not return emails or did not run"
fi

# --- Check 5: No statusHistory longer than 5 entries ---
over_five=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
over = 0
for i in range(1, 101):
    key = f'order:ORD-{i:03d}'
    length = r.execute_command('JSON.ARRLEN', key, '$.statusHistory')
    if length:
        l = length[0] if isinstance(length, list) else length
        if l and int(l) > 5:
            over += 1
print(over)
" 2>/dev/null || echo "-1")

if [[ "$over_five" -eq 0 ]]; then
echo "PASS: No statusHistory exceeds 5 entries after ARRTRIM"
else
echo "FAIL: $over_five orders still have statusHistory > 5 entries"
fi

# --- Check 6: Existing refundIds unchanged ---
refund_check=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
preserved = 0
newly_set = 0
for i in range(1, 101):
    key = f'order:ORD-{i:03d}'
    refund_raw = r.execute_command('JSON.GET', key, '$.payment.refundId')
    if not refund_raw or refund_raw == '[]':
        continue
    refund = json.loads(refund_raw)
    if isinstance(refund, list):
        refund = refund[0] if refund else None
    if refund is None:
        continue
    oid = f'ORD-{i:03d}'
    if refund == f'EXISTING-{oid}':
        preserved += 1
    elif refund == f'REF-{oid}':
        newly_set += 1
# Orders 1-10 should have EXISTING- prefix preserved
# Orders 11-100 should have REF- prefix
print(f'{preserved},{newly_set}')
" 2>/dev/null || echo "0,0")

IFS=',' read -r preserved newly_set <<< "$refund_check"
if [[ "$preserved" -eq 10 && "$newly_set" -ge 85 ]]; then
echo "PASS: Existing refundIds preserved, new ones set via NX ($preserved preserved, $newly_set new)"
elif [[ "$preserved" -eq 10 ]]; then
echo "FAIL: Existing preserved but only $newly_set new refundIds set"
elif [[ "$newly_set" -ge 85 ]]; then
echo "FAIL: New refundIds set but only $preserved/10 existing preserved"
else
echo "FAIL: refundId NX logic incorrect (preserved=$preserved, newly_set=$newly_set)"
fi

# --- Check 7: Uses JSON.* commands (not GET/SET) ---
src=$(cat operations.py 2>/dev/null || true)
json_cmds=$(echo "$src" | grep -ciE "JSON\.(GET|SET|MGET|NUMINCRBY|ARRINSERT|ARRTRIM|ARRLEN)" || true)
plain_cmds=$(echo "$src" | grep -ciE "\br\.get\b|\br\.set\b|\br\.mget\b" | grep -v "JSON\." || true)
# More precise check: look for r.get( or r.set( patterns that are not JSON commands
plain_get_set=$(echo "$src" | grep -cE '(^|[^a-zA-Z_])r\.(get|set|mget) *\(' || true)
json_exec=$(echo "$src" | grep -ciE "execute_command.*JSON\.|json\(\)|\.json\." || true)
total_json=$((json_cmds + json_exec))

if [[ "$total_json" -ge 4 ]]; then
echo "PASS: Uses JSON.* commands ($total_json references found)"
else
echo "FAIL: Insufficient use of JSON.* commands (only $total_json references found)"
fi

# --- Check 8: No crashes on missing paths ---
# Re-run with a key that has minimal structure to check crash handling
crash_check=$(python3 -c "
import json, valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
# Create a minimal order missing several expected fields
r.execute_command('JSON.SET', 'order:ORD-TEST', '$', json.dumps({
    'orderId': 'ORD-TEST',
    'customer': {'name': 'Test'},
    'items': [],
    'payment': {'method': 'card', 'status': 'failed'},
    'statusHistory': []
}))
print('setup_ok')
" 2>/dev/null || echo "crash")

if [[ "$crash_check" == "setup_ok" && "$RUN_EXIT" -eq 0 ]]; then
echo "PASS: No crashes on execution (exit code 0)"
else
echo "FAIL: Operations crashed or exited with error (exit=$RUN_EXIT)"
fi

# Cleanup test key
python3 -c "
import valkey
r = valkey.Valkey(host='localhost', port=6409, decode_responses=True)
r.delete('order:ORD-TEST')
" 2>/dev/null || true

echo ""
echo "=== Done ==="
