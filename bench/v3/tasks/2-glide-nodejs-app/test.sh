#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 2: Valkey App Patterns (GLIDE Node.js)
# Usage: ./test.sh <workspace-dir>

WORK_DIR="${1:-.}"
PASS=0
FAIL=0

check() {
    local name="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# 1. Build succeeds (TypeScript compiles without errors)
cd "$WORK_DIR" && npx tsc --noEmit > /dev/null 2>&1
check "TypeScript build succeeds" "$?"

# 2. Uses GlideClusterClient (not GlideClient for standalone)
grep -rq "GlideClusterClient" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Uses GlideClusterClient" "$?"

# 3. SCAN implementation - uses ClusterScanCursor, not KEYS command
grep -rq "ClusterScanCursor\|\.scan(" "$WORK_DIR/src/app.ts" 2>/dev/null
SCAN_USED=$?
grep -rq 'KEYS\b' "$WORK_DIR/src/app.ts" 2>/dev/null
KEYS_USED=$?
if [[ "$SCAN_USED" == "0" && "$KEYS_USED" != "0" ]]; then
    check "SCAN implementation (no KEYS command)" "0"
else
    check "SCAN implementation (no KEYS command)" "1"
fi

# 4. Lua script uses HEXPIRE for per-field TTL
grep -rqi "HEXPIRE\|hexpire" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Lua script uses HEXPIRE" "$?"

# 5. Rate limiter uses HSETEX or HEXPIRE for field TTL
grep -rqi "HSETEX\|hsetex\|HEXPIRE\|hexpire" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Rate limiter uses HSETEX or HEXPIRE" "$?"

# 6. Sharded pub/sub uses SPUBLISH (via sharded mode flag or direct command)
grep -rqi "Sharded\|SPUBLISH\|spublish\|sharded" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Sharded pub/sub uses SPUBLISH" "$?"

# 7. All tests pass
cd "$WORK_DIR" && npx vitest run --reporter=verbose 2>&1 | tail -20
VITEST_EXIT=${PIPESTATUS[0]}
check "All tests pass (npm test)" "$VITEST_EXIT"

# 8. No redis/ioredis imports
grep -rqE "from ['\"]redis['\"]|from ['\"]ioredis['\"]|require\(['\"]redis['\"]|require\(['\"]ioredis['\"]" "$WORK_DIR/src/" 2>/dev/null
if [[ $? -ne 0 ]]; then
    check "No redis/ioredis imports" "0"
else
    check "No redis/ioredis imports" "1"
fi

# 9. Handles cluster topology (uses GlideClusterClient which handles MOVED/ASK internally)
grep -rq "GlideClusterClient\|ClusterBatch\|ClusterScanCursor" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Handles cluster topology (GlideClusterClient)" "$?"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed out of $((PASS + FAIL)) checks"
