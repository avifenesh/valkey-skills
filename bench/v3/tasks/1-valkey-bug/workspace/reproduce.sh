#!/usr/bin/env bash
set -euo pipefail

# Reproduce hash field TTL bug in Valkey 9.0.3
# Requires: valkey-cli available, server running on localhost:6379

CLI="valkey-cli -h 127.0.0.1 -p 6379"

echo "=== Hash Field TTL Bug Reproduction ==="
echo ""

# Clean up from previous runs
$CLI DEL user:1 > /dev/null 2>&1 || true

# Step 1: Create a hash with two fields
echo "Step 1: Create hash with two fields"
$CLI HSET user:1 name "Alice" email "alice@test.com"
echo "  HGETALL user:1:"
$CLI HGETALL user:1
echo ""

# Step 2: Delete the email field
echo "Step 2: Delete the email field"
$CLI HDEL user:1 email
echo "  HGETALL user:1 (email should be gone):"
$CLI HGETALL user:1
echo ""

# Step 3: Set TTL on the deleted field - this should return 0, but returns 1
echo "Step 3: HEXPIRE on deleted field (expect 0 for missing field, bug returns 1)"
RESULT=$($CLI HEXPIRE user:1 3600 FIELDS 1 email)
echo "  HEXPIRE result: $RESULT"
echo ""

# Step 4: Check TTL on the deleted field - should return -2, but shows a future timestamp
echo "Step 4: HEXPIRETIME on deleted field (expect -2, bug shows future timestamp)"
TTL_RESULT=$($CLI HEXPIRETIME user:1 FIELDS 1 email)
echo "  HEXPIRETIME result: $TTL_RESULT"
echo ""

# Step 5: Confirm the field still does not exist in the hash
echo "Step 5: Confirm field is not in hash data"
echo "  HGETALL user:1:"
$CLI HGETALL user:1
echo "  HEXISTS user:1 email:"
$CLI HEXISTS user:1 email
echo ""

# Step 6: Check HTTL as another way to see the ghost TTL
echo "Step 6: HTTL on deleted field (should return -2, bug shows positive TTL)"
HTTL_RESULT=$($CLI HTTL user:1 FIELDS 1 email)
echo "  HTTL result: $HTTL_RESULT"
echo ""

# Summary
echo "=== Summary ==="
echo "HEXPIRE on deleted field returned: $RESULT (expected: 0)"
echo "HEXPIRETIME on deleted field returned: $TTL_RESULT (expected: -2)"
echo "HTTL on deleted field returned: $HTTL_RESULT (expected: -2)"
echo "The field does not exist in HGETALL but has TTL metadata - this is the bug."
