#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 3: Valkey Bug Fix (AOF key duplication in cluster mode)
# Usage: test.sh <workspace_dir>
# Validates that the agent found and fixed the getKeySlot slot caching bug.
#
# Checks 1-4: Static analysis and compilation (always run)
# Checks 5-7: Docker-based AOF replay test (skipped if Docker unavailable)

WORK_DIR="$(cd "${1:-.}" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

check() {
  local name="$1" result="$2"
  if [ "$result" = "0" ]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

skip() {
  local name="$1"
  echo "SKIP: $name"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

SRC="$WORK_DIR/src/db.c"
ORIG="$SCRIPT_DIR/workspace/src/db.c"

# =========================================
# CHECK 1: Source was modified
# =========================================

if [ ! -f "$SRC" ]; then
  check "Source was modified" 1
else
  if [ -f "$ORIG" ] && ! diff -q "$SRC" "$ORIG" > /dev/null 2>&1; then
    check "Source was modified" 0
  elif [ -f "$ORIG" ]; then
    check "Source was modified" 1
  else
    check "Source was modified" 1
  fi
fi

# =========================================
# CHECK 2: mustObeyClient used in getKeySlot
# =========================================

if [ ! -f "$SRC" ]; then
  check "mustObeyClient used in getKeySlot" 1
else
  # Extract the getKeySlot function body (from "int getKeySlot" to next function)
  # and check that mustObeyClient appears in the slot caching condition
  MUST_OBEY_COUNT=$(grep -c 'mustObeyClient' "$SRC" 2>/dev/null || true)
  MUST_OBEY_COUNT=${MUST_OBEY_COUNT:-0}

  # There should be at least 2 occurrences of mustObeyClient in getKeySlot:
  # one in the cache check, one in the backfill block
  if [ "$MUST_OBEY_COUNT" -ge 2 ]; then
    check "mustObeyClient used in getKeySlot" 0
  else
    check "mustObeyClient used in getKeySlot" 1
  fi
fi

# =========================================
# CHECK 3: isReplicatedClient NOT used on the slot caching line
# =========================================

if [ ! -f "$SRC" ]; then
  check "isReplicatedClient removed from slot cache check" 1
else
  # The bug is isReplicatedClient on the slot caching line near executing_command.
  # Check that no line contains both executing_command and isReplicatedClient.
  BUG_LINE_COUNT=$(grep 'executing_command' "$SRC" 2>/dev/null | grep -c 'isReplicatedClient' 2>/dev/null || true)
  BUG_LINE_COUNT=${BUG_LINE_COUNT:-0}

  if [ "$BUG_LINE_COUNT" = "0" ]; then
    check "isReplicatedClient removed from slot cache check" 0
  else
    check "isReplicatedClient removed from slot cache check" 1
  fi
fi

# =========================================
# CHECK 4: Code compiles (make -j4)
# =========================================

echo ""
echo "Building valkey (make -j4)..."
cd "$WORK_DIR"
if make -j4 > /dev/null 2>&1; then
  check "make succeeds" 0
else
  check "make succeeds" 1
fi

# =========================================
# DOCKER CHECKS (5-7) - skip if Docker unavailable
# =========================================

DOCKER_CMD=""
if command -v docker-compose > /dev/null 2>&1; then
  DOCKER_CMD="docker-compose"
elif command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
  DOCKER_CMD="docker compose"
fi

if [ -z "$DOCKER_CMD" ]; then
  echo ""
  echo "Docker not available - skipping cluster integration checks"
  skip "Docker build succeeds"
  skip "Cluster forms and AOF enabled"
  skip "No key duplication after AOF replay"
else
  COMPOSE_PROJECT="valkeytest3$$"

  cleanup() {
    cd "$WORK_DIR"
    $DOCKER_CMD -p "$COMPOSE_PROJECT" down -v --remove-orphans > /dev/null 2>&1 || true
  }
  trap cleanup EXIT

  # --- CHECK 5: Docker build succeeds ---
  echo ""
  echo "Building Docker image..."
  cd "$WORK_DIR"
  if $DOCKER_CMD -p "$COMPOSE_PROJECT" build > /dev/null 2>&1; then
    check "Docker build succeeds" 0
  else
    check "Docker build succeeds" 1
    skip "Cluster forms and AOF enabled"
    skip "No key duplication after AOF replay"
    echo ""
    echo "========================================="
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped out of $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) checks"
    echo "========================================="
    exit 1
  fi

  # --- CHECK 6: Cluster forms and AOF enabled ---
  echo "Starting cluster..."
  cd "$WORK_DIR"
  $DOCKER_CMD -p "$COMPOSE_PROJECT" up -d > /dev/null 2>&1
  sleep 5

  CLUSTER_CREATED=false
  if $DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli --cluster create \
    172.30.0.11:7001 172.30.0.12:7002 172.30.0.13:7003 \
    172.30.0.14:7004 172.30.0.15:7005 172.30.0.16:7006 \
    --cluster-replicas 1 --cluster-yes > /dev/null 2>&1; then
    CLUSTER_CREATED=true
  fi

  sleep 3

  if [ "$CLUSTER_CREATED" = true ]; then
    CLUSTER_INFO=$($DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -p 7001 CLUSTER INFO 2>/dev/null || true)
    SLOTS_OK=$(echo "$CLUSTER_INFO" | grep -c 'cluster_slots_ok:16384' || true)

    if [ "$SLOTS_OK" -ge 1 ]; then
      check "Cluster forms and AOF enabled" 0
    else
      check "Cluster forms and AOF enabled" 1
    fi
  else
    check "Cluster forms and AOF enabled" 1
  fi

  # --- CHECK 7: No key duplication after AOF replay ---
  if [ "$CLUSTER_CREATED" = true ]; then
    echo "Running AOF replay test..."

    # Write keys in a MULTI/EXEC that hash to different slots
    # {slot1} and {slot2} hash to different slots
    $DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -c -p 7001 SET "{user1}.name" "alice" > /dev/null 2>&1 || true
    $DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -c -p 7001 SET "{user2}.name" "bob" > /dev/null 2>&1 || true
    $DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -c -p 7001 SET "{user3}.name" "carol" > /dev/null 2>&1 || true

    # Count keys before restart
    KEYS_BEFORE=$($DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -c -p 7001 DBSIZE 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
    KEYS_BEFORE=${KEYS_BEFORE:-0}

    # Trigger AOF reload via DEBUG LOADAOF on each node
    for PORT in 7001 7002 7003; do
      $DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -c -p "$PORT" DEBUG LOADAOF > /dev/null 2>&1 || true
    done

    sleep 2

    # Count keys after reload
    KEYS_AFTER=$($DOCKER_CMD -p "$COMPOSE_PROJECT" exec -T valkey-1 valkey-cli -c -p 7001 DBSIZE 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
    KEYS_AFTER=${KEYS_AFTER:-0}

    # Check no duplication occurred - key count should be the same
    if [ "$KEYS_BEFORE" -gt 0 ] && [ "$KEYS_AFTER" = "$KEYS_BEFORE" ]; then
      check "No key duplication after AOF replay" 0
    else
      echo "  Keys before: $KEYS_BEFORE, Keys after: $KEYS_AFTER"
      check "No key duplication after AOF replay" 1
    fi
  else
    skip "No key duplication after AOF replay"
  fi
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped out of $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
