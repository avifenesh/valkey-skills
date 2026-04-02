#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 4: Rust COUNTER module
# Usage: test.sh <work_dir>
# Builds the module, starts primary+replica, loads module, runs all command checks,
# verifies persistence and replication.

WORK_DIR="${1:-.}"
PRIMARY_PORT=6404
REPLICA_PORT=6405
PASS=0
FAIL=0

if [[ ! -d "$WORK_DIR" ]]; then
    echo "FAIL: work directory does not exist: $WORK_DIR"
    exit 0
fi

cd "$WORK_DIR"

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

pcli() {
    valkey-cli -p "$PRIMARY_PORT" "$@" 2>/dev/null | tail -1
}

rcli() {
    valkey-cli -p "$REPLICA_PORT" "$@" 2>/dev/null | tail -1
}

cleanup() {
    echo "--- Cleanup ---"
    docker-compose down -v --remove-orphans 2>/dev/null || true
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
    echo "Build failed - cannot continue with runtime checks."
    echo ""
    echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
    exit 0
fi

# Verify the .so was produced
if [[ -f "target/release/libcounter_module.so" ]]; then
    echo "PASS: libcounter_module.so exists"
    PASS=$((PASS + 1))
else
    echo "FAIL: libcounter_module.so not found in target/release/"
    FAIL=$((FAIL + 1))
    echo "No module binary - cannot continue with runtime checks."
    echo ""
    echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
    exit 0
fi

# ---- Start containers ----
echo "--- Starting docker-compose ---"
docker-compose up -d --wait --wait-timeout 30 2>&1

# Wait for primary to accept commands
for i in $(seq 1 20); do
    pcli PING | grep -q PONG && break
    sleep 1
done

# ---- Check 2: Module is loaded ----
echo "--- Check 2: module loaded ---"
MODULE_LIST=$(pcli MODULE LIST)
if echo "$MODULE_LIST" | grep -qi "counter"; then
    echo "PASS: module loaded (counter in MODULE LIST)"
    PASS=$((PASS + 1))
else
    echo "FAIL: module loaded (counter not found in MODULE LIST)"
    FAIL=$((FAIL + 1))
    echo "Module not loaded - cannot continue with command checks."
    echo ""
    echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
    exit 0
fi

# Clear any previous state
pcli DEL mykey >/dev/null 2>&1 || true

# ---- Check 3: COUNTER.INCR mykey returns 1 (new key, default increment) ----
echo "--- Check 3: COUNTER.INCR mykey ---"
RESULT=$(pcli COUNTER.INCR mykey)
check "COUNTER.INCR mykey returns 1" "1" "$RESULT"

# ---- Check 4: COUNTER.INCR mykey 5 returns 6 (increment by 5) ----
echo "--- Check 4: COUNTER.INCR mykey 5 ---"
RESULT=$(pcli COUNTER.INCR mykey 5)
check "COUNTER.INCR mykey 5 returns 6" "6" "$RESULT"

# ---- Check 5: COUNTER.GET mykey returns 6 ----
echo "--- Check 5: COUNTER.GET mykey ---"
RESULT=$(pcli COUNTER.GET mykey)
check "COUNTER.GET mykey returns 6" "6" "$RESULT"

# ---- Check 6: COUNTER.GET nonexistent returns 0 ----
echo "--- Check 6: COUNTER.GET nonexistent ---"
pcli DEL nosuchkey >/dev/null 2>&1 || true
RESULT=$(pcli COUNTER.GET nosuchkey)
check "COUNTER.GET nonexistent key returns 0" "0" "$RESULT"

# ---- Check 7: COUNTER.RESET mykey returns old value (6), then GET returns 0 ----
echo "--- Check 7: COUNTER.RESET + GET ---"
RESET_RESULT=$(pcli COUNTER.RESET mykey)
GET_RESULT=$(pcli COUNTER.GET mykey)
if [[ "$RESET_RESULT" == "6" && "$GET_RESULT" == "0" ]]; then
    echo "PASS: COUNTER.RESET returns 6, then GET returns 0"
    PASS=$((PASS + 1))
else
    echo "FAIL: COUNTER.RESET returns 6, then GET returns 0 (reset='$RESET_RESULT', get='$GET_RESULT')"
    FAIL=$((FAIL + 1))
fi

# ---- Check 8: COUNTER.RESET nonexistent returns 0 ----
echo "--- Check 8: COUNTER.RESET nonexistent ---"
pcli DEL nosuchkey >/dev/null 2>&1 || true
RESULT=$(pcli COUNTER.RESET nosuchkey)
check "COUNTER.RESET nonexistent key returns 0" "0" "$RESULT"

# ---- Check 9: BGSAVE + restart, value persists ----
echo "--- Check 9: persistence (BGSAVE + restart) ---"
pcli COUNTER.INCR mykey 42 >/dev/null
pcli BGSAVE >/dev/null
sleep 2

# Restart primary container
docker-compose restart valkey-primary 2>&1
for i in $(seq 1 20); do
    pcli PING 2>/dev/null | grep -q PONG && break
    sleep 1
done
sleep 1

RESULT=$(pcli COUNTER.GET mykey)
check "BGSAVE + restart, GET mykey returns 42 (persisted)" "42" "$RESULT"

# ---- Check 10: Replica has the same value ----
echo "--- Check 10: replication ---"
# Wait for replica to sync
sleep 3
for i in $(seq 1 10); do
    ROLE_INFO=$(valkey-cli -p "$REPLICA_PORT" INFO replication 2>/dev/null || true)
    echo "$ROLE_INFO" | grep -q "master_link_status:up" && break
    sleep 1
done

REPLICA_RESULT=$(rcli COUNTER.GET mykey)
check "Replica has same value (42)" "42" "$REPLICA_RESULT"

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
