#!/usr/bin/env bash
set -uo pipefail

# Test for Task 1 v2: Cluster split-brain bug
# The bug: clusterShouldDeferEpochBump() prevents epoch collision resolution.
# Checks: source fix correct, builds, cluster works after fix.

WORK_DIR="$(cd "${1:-.}" && pwd)"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "0" ]; then
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

CLUSTER_SRC="$WORK_DIR/src/cluster_legacy.c"
if [ ! -f "$CLUSTER_SRC" ]; then
  check "cluster_legacy.c exists" 1
  echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
  exit 0
fi

# -----------------------------------------------------------------------
# Check 1: Defer mechanism was modified
# The original bug: if (clusterShouldDeferEpochBump()) return;
# Valid fixes: remove the call, remove the function, negate it, return 0
# -----------------------------------------------------------------------
HAS_ACTIVE_CALL=$(grep -c 'if (clusterShouldDeferEpochBump())' "$CLUSTER_SRC" 2>/dev/null)
HAS_ACTIVE_CALL=${HAS_ACTIVE_CALL:-0}

if [ "$HAS_ACTIVE_CALL" -eq 0 ]; then
  # Call removed or function removed entirely
  check "Defer mechanism was modified" 0
elif grep -qE '//.*clusterShouldDeferEpochBump|/\*.*clusterShouldDeferEpochBump|!.*clusterShouldDeferEpochBump' "$CLUSTER_SRC" 2>/dev/null; then
  # Call commented out or negated
  check "Defer mechanism was modified" 0
else
  # Check if function body returns 0 always
  BODY=$(sed -n '/^static int clusterShouldDeferEpochBump/,/^}/p' "$CLUSTER_SRC" 2>/dev/null)
  if echo "$BODY" | grep -q 'return 0'; then
    check "Defer mechanism was modified" 0
  else
    check "Defer mechanism was modified" 1
  fi
fi

# -----------------------------------------------------------------------
# Check 2: Epoch collision handler preserved (currentEpoch++ still there)
# -----------------------------------------------------------------------
HANDLER=$(sed -n '/void clusterHandleConfigEpochCollision/,/^}/p' "$CLUSTER_SRC" 2>/dev/null)
if echo "$HANDLER" | grep -q 'currentEpoch++'; then
  check "Epoch collision handler preserved" 0
else
  check "Epoch collision handler preserved" 1
fi

# -----------------------------------------------------------------------
# Check 3: Docker build succeeds (the fix compiles)
# -----------------------------------------------------------------------
docker-compose down -v 2>/dev/null || true
BUILD_OUT=$(docker-compose build 2>&1)
BUILD_RC=$?
check "Docker build succeeds" "$BUILD_RC"

if [ "$BUILD_RC" -ne 0 ]; then
  echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
  exit 0
fi

# -----------------------------------------------------------------------
# Check 4: Cluster starts and forms
# -----------------------------------------------------------------------
docker-compose up -d 2>/dev/null
sleep 5

docker-compose exec -T valkey-1 valkey-cli --cluster create \
  172.30.0.11:7001 172.30.0.12:7002 172.30.0.13:7003 \
  172.30.0.14:7004 172.30.0.15:7005 172.30.0.16:7006 \
  --cluster-replicas 1 --cluster-yes >/dev/null 2>&1

sleep 5

CLUSTER_STATE=$(docker-compose exec -T valkey-1 valkey-cli -p 7001 CLUSTER INFO 2>/dev/null | tr -d '\r' | grep cluster_state)
if echo "$CLUSTER_STATE" | grep -q "ok"; then
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
  docker-compose exec -T valkey-1 valkey-cli -p 7001 -c SET "key:$i" "val:$i" >/dev/null 2>&1 && WRITE_OK=$((WRITE_OK + 1))
done
check "Writes succeed (>40 of 50)" "$([ "$WRITE_OK" -gt 40 ] && echo 0 || echo 1)"

# -----------------------------------------------------------------------
# Check 6-7: Partition test
# -----------------------------------------------------------------------
CONTAINER=$(docker-compose ps -q valkey-1 2>/dev/null)
NETWORK=$(docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)

if [ -n "$CONTAINER" ] && [ -n "$NETWORK" ]; then
  docker network disconnect "$NETWORK" "$CONTAINER" 2>/dev/null
  sleep 15
  docker network connect "$NETWORK" "$CONTAINER" 2>/dev/null
  sleep 15

  NODES_AFTER=$(docker-compose exec -T valkey-2 valkey-cli -p 7002 CLUSTER NODES 2>/dev/null)
  MASTER_COUNT=$(echo "$NODES_AFTER" | grep -c "master" || echo 0)
  check "Exactly 3 masters after partition heal" "$([ "$MASTER_COUNT" -eq 3 ] && echo 0 || echo 1)"

  SLOT_RANGES=$(echo "$NODES_AFTER" | grep "master" | grep -oE '[0-9]+-[0-9]+' | sort)
  UNIQUE_RANGES=$(echo "$SLOT_RANGES" | sort -u)
  if [ "$SLOT_RANGES" = "$UNIQUE_RANGES" ] && [ -n "$SLOT_RANGES" ]; then
    check "No split-brain (no overlapping slots)" 0
  else
    check "No split-brain (no overlapping slots)" 1
  fi
else
  check "Exactly 3 masters after partition heal" 1
  check "No split-brain (no overlapping slots)" 1
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
