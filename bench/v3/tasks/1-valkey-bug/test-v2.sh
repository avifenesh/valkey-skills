#!/usr/bin/env bash
set -uo pipefail

# Test for Task 1 v2: Cluster split-brain bug
# The bug: clusterShouldDeferEpochBump() prevents epoch collision resolution.
# Test: does it build, and does the fix resolve the split-brain?

WORK_DIR="$(cd "${1:-.}" && pwd)"

PASS=0
FAIL=0

check() {
  if [[ "$2" == "0" ]]; then
    echo "PASS: $1"; PASS=$((PASS + 1))
  else
    echo "FAIL: $1"; FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  cd "$WORK_DIR"
  docker-compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

cd "$WORK_DIR"

# -----------------------------------------------------------------------
# Check 1: Source was modified (agent actually changed something)
# -----------------------------------------------------------------------
CLUSTER_SRC="$WORK_DIR/src/cluster_legacy.c"
if [[ ! -f "$CLUSTER_SRC" ]]; then
  check "cluster_legacy.c exists" 1
  echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
  exit 0
fi

# Compare against the original buggy defer function
# The original has: if (clusterShouldDeferEpochBump()) return;
# A fix should remove/neuter that call or the function
ORIG_DEFER_CALL=$(grep -c "clusterShouldDeferEpochBump" "$CLUSTER_SRC" 2>/dev/null || echo 0)
ORIG_DEFER_ACTIVE=$(grep -c 'if (clusterShouldDeferEpochBump())' "$CLUSTER_SRC" 2>/dev/null || echo 0)

# Either function removed entirely, or the call is commented/removed/negated
if [[ "$ORIG_DEFER_ACTIVE" -eq 0 ]]; then
  check "Defer mechanism was modified" 0
elif grep -qE '//.*clusterShouldDeferEpochBump|/\*.*clusterShouldDeferEpochBump|!clusterShouldDeferEpochBump' "$CLUSTER_SRC" 2>/dev/null; then
  check "Defer mechanism was modified" 0
else
  # Check if function body now returns 0
  FUNC_RETURNS_0=$(sed -n '/int clusterShouldDeferEpochBump/,/^}/p' "$CLUSTER_SRC" 2>/dev/null | grep -c 'return 0' || echo 0)
  if [[ "$FUNC_RETURNS_0" -gt 0 ]]; then
    check "Defer mechanism was modified" 0
  else
    check "Defer mechanism was modified" 1
  fi
fi

# -----------------------------------------------------------------------
# Check 2: clusterHandleConfigEpochCollision still has the epoch bump
# (agent didn't break the collision handler itself)
# -----------------------------------------------------------------------
if grep -A20 'void clusterHandleConfigEpochCollision' "$CLUSTER_SRC" 2>/dev/null | grep -q 'currentEpoch++'; then
  check "Epoch collision handler preserved" 0
else
  check "Epoch collision handler preserved" 1
fi

# -----------------------------------------------------------------------
# Check 3: Docker build succeeds (the fix compiles)
# -----------------------------------------------------------------------
BUILD_OUT=$(docker-compose build 2>&1)
BUILD_RC=$?
check "Docker build succeeds" "$BUILD_RC"

if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "Build failed, skipping runtime checks"
  echo ""
  echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
  exit 0
fi

# -----------------------------------------------------------------------
# Check 4: Cluster starts and forms
# -----------------------------------------------------------------------
docker-compose up -d 2>/dev/null
sleep 5

# Create cluster
docker-compose exec -T valkey-1 valkey-cli --cluster create \
  172.30.0.11:7001 172.30.0.12:7002 172.30.0.13:7003 \
  172.30.0.14:7004 172.30.0.15:7005 172.30.0.16:7006 \
  --cluster-replicas 1 --cluster-yes 2>/dev/null

sleep 3

CLUSTER_STATE=$(docker-compose exec -T valkey-1 valkey-cli -p 7001 CLUSTER INFO 2>/dev/null | grep cluster_state | tr -d '\r')
if echo "$CLUSTER_STATE" | grep -q "cluster_state:ok"; then
  check "Cluster forms successfully" 0
else
  check "Cluster forms successfully" 1
  echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
  exit 0
fi

# -----------------------------------------------------------------------
# Check 5: Write data
# -----------------------------------------------------------------------
WRITE_OK=0
for i in $(seq 1 50); do
  docker-compose exec -T valkey-1 valkey-cli -p 7001 -c SET "key:$i" "val:$i" 2>/dev/null && WRITE_OK=$((WRITE_OK + 1))
done
check "Writes succeed (>40 of 50)" "$([ "$WRITE_OK" -gt 40 ] && echo 0 || echo 1)"

# -----------------------------------------------------------------------
# Check 6-7: Partition test - the real test
# Disconnect a primary, wait for failover, reconnect, check no split-brain
# -----------------------------------------------------------------------

# Find primary for slot 0
NODES_BEFORE=$(docker-compose exec -T valkey-2 valkey-cli -p 7002 CLUSTER NODES 2>/dev/null)

# Disconnect valkey-1
CONTAINER=$(docker-compose ps -q valkey-1)
NETWORK=$(docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)

if [[ -n "$CONTAINER" && -n "$NETWORK" ]]; then
  docker network disconnect "$NETWORK" "$CONTAINER" 2>/dev/null

  # Wait for failover
  sleep 15

  # Reconnect
  docker network connect "$NETWORK" "$CONTAINER" 2>/dev/null

  # Wait for convergence
  sleep 15

  # Check for split-brain: count masters claiming overlapping slots
  NODES_AFTER=$(docker-compose exec -T valkey-2 valkey-cli -p 7002 CLUSTER NODES 2>/dev/null)

  # Count how many nodes are master
  MASTER_COUNT=$(echo "$NODES_AFTER" | grep -c "master" || echo 0)
  check "Exactly 3 masters after partition heal" "$([ "$MASTER_COUNT" -eq 3 ] && echo 0 || echo 1)"

  # Check no two masters claim the same slot range
  # Extract slot ranges for masters, check for duplicates
  SLOT_RANGES=$(echo "$NODES_AFTER" | grep "master" | grep -oE '[0-9]+-[0-9]+' | sort)
  UNIQUE_RANGES=$(echo "$SLOT_RANGES" | sort -u)
  if [[ "$SLOT_RANGES" == "$UNIQUE_RANGES" && -n "$SLOT_RANGES" ]]; then
    check "No overlapping slot ranges (no split-brain)" 0
  else
    check "No overlapping slot ranges (no split-brain)" 1
  fi
else
  check "Exactly 3 masters after partition heal" 1
  check "No overlapping slot ranges (no split-brain)" 1
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
