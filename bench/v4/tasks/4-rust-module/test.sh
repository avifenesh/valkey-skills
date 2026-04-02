#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 4: Rust Valkey Module (TOPK data structure)
# Usage: test.sh <workspace_dir>
# Validates that the TOPK module builds, loads into valkey-server,
# and all commands work correctly including RDB persistence.

WORK_DIR="$(cd "${1:-.}" && pwd)"
PORT=6504

PASS_COUNT=0
FAIL_COUNT=0

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

cleanup() {
  valkey-cli -p $PORT SHUTDOWN NOSAVE 2>/dev/null || true
  sleep 1
}
trap cleanup EXIT

# =========================================
# BUILD CHECKS
# =========================================

echo "Building module..."
cd "$WORK_DIR"
BUILD_OUTPUT=$(cargo build --release 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?

if [ "$BUILD_EXIT" = "0" ]; then
  check "cargo build --release succeeds" 0
else
  echo "$BUILD_OUTPUT"
  check "cargo build --release succeeds" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# Check .so file exists
SO_FILE=$(find "$WORK_DIR/target/release/" -maxdepth 1 \( -name "*.so" -o -name "*.dylib" \) | head -1)
if [ -n "$SO_FILE" ]; then
  check ".so/.dylib file exists" 0
else
  check ".so/.dylib file exists" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# =========================================
# SERVER LOAD CHECK
# =========================================

echo ""
echo "Starting valkey-server with module..."
DBDIR=$(mktemp -d)
valkey-server --port $PORT --loadmodule "$SO_FILE" \
  --daemonize yes --dir "$DBDIR" --dbfilename dump.rdb \
  --loglevel warning 2>&1 || true
sleep 1

# Verify server is up
if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server starts with module" 0
else
  check "valkey-server starts with module" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# Check module is listed
MODULE_LIST=$(valkey-cli -p $PORT MODULE LIST 2>/dev/null)
if echo "$MODULE_LIST" | grep -qi "topk"; then
  check "MODULE LIST contains topk" 0
else
  check "MODULE LIST contains topk" 1
fi

# =========================================
# COMMAND TESTS
# =========================================

echo ""
echo "Testing TOPK commands..."

# TOPK.ADD basic - first add returns 1
ADD_RESULT=$(valkey-cli -p $PORT TOPK.ADD mykey item1 2>/dev/null)
if echo "$ADD_RESULT" | grep -qE "^(\(integer\) )?1$"; then
  check "TOPK.ADD mykey item1 returns 1" 0
else
  check "TOPK.ADD mykey item1 returns 1 (got: $ADD_RESULT)" 1
fi

# TOPK.ADD again - second add returns 2
ADD_RESULT2=$(valkey-cli -p $PORT TOPK.ADD mykey item1 2>/dev/null)
if echo "$ADD_RESULT2" | grep -qE "^(\(integer\) )?2$"; then
  check "TOPK.ADD mykey item1 again returns 2" 0
else
  check "TOPK.ADD mykey item1 again returns 2 (got: $ADD_RESULT2)" 1
fi

# TOPK.ADD with explicit increment
ADD_RESULT3=$(valkey-cli -p $PORT TOPK.ADD mykey item2 5 2>/dev/null)
if echo "$ADD_RESULT3" | grep -qE "^(\(integer\) )?5$"; then
  check "TOPK.ADD mykey item2 5 returns 5" 0
else
  check "TOPK.ADD mykey item2 5 returns 5 (got: $ADD_RESULT3)" 1
fi

# TOPK.COUNT for item1 should be 2
COUNT_RESULT=$(valkey-cli -p $PORT TOPK.COUNT mykey item1 2>/dev/null)
if echo "$COUNT_RESULT" | grep -qE "^(\(integer\) )?2$"; then
  check "TOPK.COUNT mykey item1 returns 2" 0
else
  check "TOPK.COUNT mykey item1 returns 2 (got: $COUNT_RESULT)" 1
fi

# TOPK.COUNT for item2 should be 5
COUNT_RESULT2=$(valkey-cli -p $PORT TOPK.COUNT mykey item2 2>/dev/null)
if echo "$COUNT_RESULT2" | grep -qE "^(\(integer\) )?5$"; then
  check "TOPK.COUNT mykey item2 returns 5" 0
else
  check "TOPK.COUNT mykey item2 returns 5 (got: $COUNT_RESULT2)" 1
fi

# TOPK.LIST returns items (item2 should be first with count 5)
LIST_RESULT=$(valkey-cli -p $PORT TOPK.LIST mykey 2>/dev/null)
if echo "$LIST_RESULT" | grep -q "item2"; then
  check "TOPK.LIST mykey contains item2" 0
else
  check "TOPK.LIST mykey contains item2 (got: $LIST_RESULT)" 1
fi

if echo "$LIST_RESULT" | grep -q "item1"; then
  check "TOPK.LIST mykey contains item1" 0
else
  check "TOPK.LIST mykey contains item1 (got: $LIST_RESULT)" 1
fi

# TOPK.COUNT for non-existent item returns 0
COUNT_NONE=$(valkey-cli -p $PORT TOPK.COUNT mykey nosuchitem 2>/dev/null)
if echo "$COUNT_NONE" | grep -qE "^(\(integer\) )?0$"; then
  check "TOPK.COUNT non-existent item returns 0" 0
else
  check "TOPK.COUNT non-existent item returns 0 (got: $COUNT_NONE)" 1
fi

# =========================================
# RESET TEST
# =========================================

echo ""
echo "Testing TOPK.RESET..."

RESET_RESULT=$(valkey-cli -p $PORT TOPK.RESET mykey 2>/dev/null)
if echo "$RESET_RESULT" | grep -qi "OK"; then
  check "TOPK.RESET mykey returns OK" 0
else
  check "TOPK.RESET mykey returns OK (got: $RESET_RESULT)" 1
fi

COUNT_AFTER_RESET=$(valkey-cli -p $PORT TOPK.COUNT mykey item1 2>/dev/null)
if echo "$COUNT_AFTER_RESET" | grep -qE "^(\(integer\) )?0$"; then
  check "TOPK.COUNT after reset returns 0" 0
else
  check "TOPK.COUNT after reset returns 0 (got: $COUNT_AFTER_RESET)" 1
fi

# =========================================
# RDB PERSISTENCE TEST
# =========================================

echo ""
echo "Testing RDB persistence..."

# Add data that should survive restart
valkey-cli -p $PORT TOPK.ADD persist_key alpha 10 >/dev/null 2>&1
valkey-cli -p $PORT TOPK.ADD persist_key beta 3 >/dev/null 2>&1

# Trigger BGSAVE and wait for it
valkey-cli -p $PORT BGSAVE >/dev/null 2>&1
sleep 2

# Verify data before restart
PRE_COUNT=$(valkey-cli -p $PORT TOPK.COUNT persist_key alpha 2>/dev/null)
if echo "$PRE_COUNT" | grep -qE "^(\(integer\) )?10$"; then
  check "pre-restart: TOPK.COUNT persist_key alpha is 10" 0
else
  check "pre-restart: TOPK.COUNT persist_key alpha is 10 (got: $PRE_COUNT)" 1
fi

# Shutdown and restart
valkey-cli -p $PORT SHUTDOWN SAVE 2>/dev/null || true
sleep 1

valkey-server --port $PORT --loadmodule "$SO_FILE" \
  --daemonize yes --dir "$DBDIR" --dbfilename dump.rdb \
  --loglevel warning 2>&1 || true
sleep 1

# Verify server restarted
if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server restarts after RDB save" 0
else
  check "valkey-server restarts after RDB save" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# Verify data survived restart
POST_COUNT_ALPHA=$(valkey-cli -p $PORT TOPK.COUNT persist_key alpha 2>/dev/null)
if echo "$POST_COUNT_ALPHA" | grep -qE "^(\(integer\) )?10$"; then
  check "post-restart: TOPK.COUNT persist_key alpha is 10" 0
else
  check "post-restart: TOPK.COUNT persist_key alpha is 10 (got: $POST_COUNT_ALPHA)" 1
fi

POST_COUNT_BETA=$(valkey-cli -p $PORT TOPK.COUNT persist_key beta 2>/dev/null)
if echo "$POST_COUNT_BETA" | grep -qE "^(\(integer\) )?3$"; then
  check "post-restart: TOPK.COUNT persist_key beta is 3" 0
else
  check "post-restart: TOPK.COUNT persist_key beta is 3 (got: $POST_COUNT_BETA)" 1
fi

# =========================================
# STATIC ANALYSIS CHECKS
# =========================================

echo ""
echo "Static analysis..."

LIB_RS="$WORK_DIR/src/lib.rs"

# Check replicate_verbatim is called
if grep -qE "replicate_verbatim" "$LIB_RS" 2>/dev/null; then
  check "src/lib.rs calls replicate_verbatim" 0
else
  check "src/lib.rs calls replicate_verbatim" 1
fi

# Check ValkeyType is used for custom data type
if grep -qE "ValkeyType" "$LIB_RS" 2>/dev/null; then
  check "src/lib.rs uses ValkeyType" 0
else
  check "src/lib.rs uses ValkeyType" 1
fi

# Check data_types array is populated (not empty)
if grep -qE 'data_types:\s*\[' "$LIB_RS" 2>/dev/null; then
  # Ensure it's not just an empty array
  DATA_TYPES_CONTENT=$(sed -n '/data_types:\s*\[/,/\]/p' "$LIB_RS" 2>/dev/null)
  if echo "$DATA_TYPES_CONTENT" | grep -qv '^\s*\]\s*$' && echo "$DATA_TYPES_CONTENT" | grep -qE '[A-Z_]'; then
    check "data_types array is populated" 0
  else
    check "data_types array is populated" 1
  fi
else
  check "data_types array is populated" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
