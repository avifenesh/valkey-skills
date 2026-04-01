#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 2: Valkey App Patterns (GLIDE Node.js)
# Usage: ./test.sh <workspace-dir>
# Starts a 3-node Valkey cluster, builds the project, runs tests, and checks API usage.

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

cleanup() {
    echo "--- Cleanup ---"
    cd "$WORK_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# ---- Check 1: Docker cluster starts ----
echo "--- Check 1: Docker cluster ---"
cd "$WORK_DIR" && docker compose up -d 2>&1
# Wait for cluster-init to finish (it sleeps 3s then creates the cluster)
sleep 8

# Verify all 3 cluster nodes are running
RUNNING_NODES=0
for port in 7000 7001 7002; do
    if valkey-cli -p "$port" PING 2>/dev/null | grep -q PONG; then
        RUNNING_NODES=$((RUNNING_NODES + 1))
    fi
done

if [[ "$RUNNING_NODES" -eq 3 ]]; then
    check "Docker cluster: all 3 nodes responding" "0"
else
    check "Docker cluster: all 3 nodes responding ($RUNNING_NODES/3 up)" "1"
fi

# Verify cluster is formed (CLUSTER INFO shows cluster_state:ok)
CLUSTER_STATE=$(valkey-cli -p 7000 CLUSTER INFO 2>/dev/null | grep cluster_state | tr -d '\r')
if [[ "$CLUSTER_STATE" == "cluster_state:ok" ]]; then
    check "Docker cluster: cluster_state is ok" "0"
else
    check "Docker cluster: cluster_state is ok (got: $CLUSTER_STATE)" "1"
fi

# ---- Check 2: npm install succeeds ----
echo "--- Check 2: npm install ---"
cd "$WORK_DIR" && npm install 2>&1
check "npm install succeeds" "$?"

# ---- Check 3: TypeScript build succeeds (npm run build) ----
echo "--- Check 3: TypeScript build ---"
cd "$WORK_DIR" && npm run build 2>&1
check "npm run build (tsc) succeeds" "$?"

# ---- Check 4: All tests pass (vitest) ----
echo "--- Check 4: vitest ---"
cd "$WORK_DIR" && npm test 2>&1
check "npm test (vitest run) succeeds" "$?"

# ---- Check 5: Uses GlideClusterClient ----
echo "--- Check 5: API usage checks ---"
grep -rq "GlideClusterClient" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Uses GlideClusterClient" "$?"

# ---- Check 6: SCAN implementation (no KEYS command) ----
grep -rq "ClusterScanCursor\|\.scan(" "$WORK_DIR/src/app.ts" 2>/dev/null
SCAN_USED=$?
grep -rq 'KEYS\b' "$WORK_DIR/src/app.ts" 2>/dev/null
KEYS_USED=$?
if [[ "$SCAN_USED" == "0" && "$KEYS_USED" != "0" ]]; then
    check "SCAN implementation (no KEYS command)" "0"
else
    check "SCAN implementation (no KEYS command)" "1"
fi

# ---- Check 7: Lua script uses HEXPIRE for per-field TTL ----
grep -rqi "HEXPIRE\|hexpire" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Lua script uses HEXPIRE" "$?"

# ---- Check 8: Rate limiter uses HSETEX or HEXPIRE ----
grep -rqi "HSETEX\|hsetex\|HEXPIRE\|hexpire" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Rate limiter uses HSETEX or HEXPIRE" "$?"

# ---- Check 9: Sharded pub/sub ----
grep -rqi "Sharded\|SPUBLISH\|spublish\|sharded" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Sharded pub/sub uses SPUBLISH" "$?"

# ---- Check 10: No redis/ioredis imports ----
grep -rqE "from ['\"]redis['\"]|from ['\"]ioredis['\"]|require\(['\"]redis['\"]|require\(['\"]ioredis['\"]" "$WORK_DIR/src/" 2>/dev/null
if [[ $? -ne 0 ]]; then
    check "No redis/ioredis imports" "0"
else
    check "No redis/ioredis imports" "1"
fi

# ---- Check 11: Handles cluster topology ----
grep -rq "GlideClusterClient\|ClusterBatch\|ClusterScanCursor" "$WORK_DIR/src/app.ts" 2>/dev/null
check "Handles cluster topology (GlideClusterClient)" "$?"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed out of $((PASS + FAIL)) checks"
