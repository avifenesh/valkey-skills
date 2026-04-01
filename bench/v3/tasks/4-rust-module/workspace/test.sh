#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 4: Rust COUNTER module
# Run from the workspace directory (passed as $1 or cwd)
WORK_DIR="${1:-.}"
cd "$WORK_DIR"

PRIMARY_PORT=6400
REPLICA_PORT=6401
PASS=0
FAIL=0

pcli() {
  valkey-cli -p "$PRIMARY_PORT" "$@" 2>/dev/null | tail -1
}

rcli() {
  valkey-cli -p "$REPLICA_PORT" "$@" 2>/dev/null | tail -1
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  docker compose down -v --remove-orphans 2>/dev/null || true
}

trap cleanup EXIT

# ---- Check 1: cargo build --release succeeds ----
echo "--- Check 1: cargo build ---"
if cargo build --release 2>&1; then
  echo "PASS: cargo build --release succeeds"
  PASS=$((PASS + 1))
else
  echo "FAIL: cargo build --release succeeds"
  FAIL=$((FAIL + 1))
  echo "Build failed, cannot continue."
  echo ""
  echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL))"
  exit 0
fi

# Start containers
docker compose up -d --wait --wait-timeout 30

# Wait for primary to accept commands
for i in $(seq 1 20); do
  pcli PING | grep -q PONG && break
  sleep 1
done

# ---- Check 2: MODULE LOAD succeeds (module is loaded via docker-compose) ----
echo "--- Check 2: module loaded ---"
MODULE_LIST=$(pcli MODULE LIST)
if echo "$MODULE_LIST" | grep -qi "counter"; then
  echo "PASS: MODULE LOAD succeeds"
  PASS=$((PASS + 1))
else
  echo "FAIL: MODULE LOAD succeeds (module not found in MODULE LIST)"
  FAIL=$((FAIL + 1))
fi

# Clear any previous state
pcli DEL mykey >/dev/null 2>&1 || true

# ---- Check 3: COUNTER.INCR mykey returns 1 ----
echo "--- Check 3: COUNTER.INCR mykey ---"
RESULT=$(pcli COUNTER.INCR mykey)
check "COUNTER.INCR mykey returns 1" "1" "$RESULT"

# ---- Check 4: COUNTER.INCR mykey 5 returns 6 ----
echo "--- Check 4: COUNTER.INCR mykey 5 ---"
RESULT=$(pcli COUNTER.INCR mykey 5)
check "COUNTER.INCR mykey 5 returns 6" "6" "$RESULT"

# ---- Check 5: COUNTER.GET mykey returns 6 ----
echo "--- Check 5: COUNTER.GET mykey ---"
RESULT=$(pcli COUNTER.GET mykey)
check "COUNTER.GET mykey returns 6" "6" "$RESULT"

# ---- Check 6: COUNTER.RESET mykey returns 6, then GET returns 0 ----
echo "--- Check 6: COUNTER.RESET + GET ---"
RESET_RESULT=$(pcli COUNTER.RESET mykey)
GET_RESULT=$(pcli COUNTER.GET mykey)
if [[ "$RESET_RESULT" == "6" && "$GET_RESULT" == "0" ]]; then
  echo "PASS: COUNTER.RESET mykey returns 6, then GET returns 0"
  PASS=$((PASS + 1))
else
  echo "FAIL: COUNTER.RESET mykey returns 6, then GET returns 0 (reset='$RESET_RESULT', get='$GET_RESULT')"
  FAIL=$((FAIL + 1))
fi

# ---- Check 7: BGSAVE + restart, GET returns 0 (persisted) ----
echo "--- Check 7: persistence ---"
# Set a known value then persist
pcli COUNTER.INCR mykey 42 >/dev/null
pcli BGSAVE >/dev/null
sleep 2

# Restart primary container
docker compose restart valkey-primary
for i in $(seq 1 20); do
  pcli PING 2>/dev/null | grep -q PONG && break
  sleep 1
done
sleep 1

RESULT=$(pcli COUNTER.GET mykey)
check "BGSAVE + restart, GET mykey returns 42 (persisted)" "42" "$RESULT"

# ---- Check 8: Replica has same value ----
echo "--- Check 8: replication ---"
# Wait for replica to sync
sleep 3
for i in $(seq 1 10); do
  ROLE_INFO=$(valkey-cli -p "$REPLICA_PORT" INFO replication 2>/dev/null || true)
  echo "$ROLE_INFO" | grep -q "master_link_status:up" && break
  sleep 1
done

REPLICA_RESULT=$(rcli COUNTER.GET mykey)
check "Replica has same value" "42" "$REPLICA_RESULT"

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL))"
