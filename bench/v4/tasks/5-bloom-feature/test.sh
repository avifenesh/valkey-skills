#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 5: Add BF.DUMP command to valkey-bloom
# Usage: test.sh <workspace_dir>
# Validates that BF.DUMP is implemented, builds, and works correctly.

WORK_DIR="$(cd "${1:-.}" && pwd)"
BLOOM_DIR="$WORK_DIR/valkey-bloom"
PORT=6505

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

echo "Building valkey-bloom module..."
cd "$BLOOM_DIR"
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

# Check .so/.dylib file exists
SO_FILE=$(find "$BLOOM_DIR/target/release/" -maxdepth 1 \( -name "*.so" -o -name "*.dylib" \) | head -1)
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
echo "Starting valkey-server with bloom module..."
DBDIR=$(mktemp -d)
valkey-server --port $PORT --loadmodule "$SO_FILE" \
  --daemonize yes --dir "$DBDIR" --dbfilename dump.rdb \
  --loglevel warning 2>&1 || true
sleep 1

# Verify server is up
if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server starts with bloom module" 0
else
  check "valkey-server starts with bloom module" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# =========================================
# BF.DUMP FUNCTIONAL TESTS
# =========================================

echo ""
echo "Testing BF.DUMP command..."

# Add items to a bloom filter
valkey-cli -p $PORT BF.ADD test item1 >/dev/null 2>&1
valkey-cli -p $PORT BF.ADD test item2 >/dev/null 2>&1

# BF.DUMP on existing bloom filter should return non-nil, non-error
DUMP_RESULT=$(valkey-cli -p $PORT BF.DUMP test 2>/dev/null)
if [ -n "$DUMP_RESULT" ] && ! echo "$DUMP_RESULT" | grep -qi "error\|ERR\|nil"; then
  check "BF.DUMP test returns non-nil non-error response" 0
else
  check "BF.DUMP test returns non-nil non-error response (got: $DUMP_RESULT)" 1
fi

# BF.DUMP on non-existent key should return nil
DUMP_MISSING=$(valkey-cli -p $PORT BF.DUMP nonexistent 2>/dev/null)
if echo "$DUMP_MISSING" | grep -qi "nil"; then
  check "BF.DUMP nonexistent returns nil" 0
else
  check "BF.DUMP nonexistent returns nil (got: $DUMP_MISSING)" 1
fi

# BF.DUMP on wrong type should return WRONGTYPE error
valkey-cli -p $PORT SET strkey value >/dev/null 2>&1
DUMP_WRONGTYPE=$(valkey-cli -p $PORT BF.DUMP strkey 2>/dev/null)
if echo "$DUMP_WRONGTYPE" | grep -qi "WRONGTYPE"; then
  check "BF.DUMP strkey returns WRONGTYPE error" 0
else
  check "BF.DUMP strkey returns WRONGTYPE error (got: $DUMP_WRONGTYPE)" 1
fi

# BF.DUMP result should be non-empty bytes (meaningful length)
DUMP_LEN=${#DUMP_RESULT}
if [ "$DUMP_LEN" -gt 10 ]; then
  check "BF.DUMP returns substantial data (len=$DUMP_LEN)" 0
else
  check "BF.DUMP returns substantial data (len=$DUMP_LEN)" 1
fi

# =========================================
# SOURCE CODE CHECKS
# =========================================

echo ""
echo "Source code analysis..."

# Check BF.DUMP appears in Rust source
if grep -rq "BF.DUMP\|BF\.DUMP\|bf\.dump\|bf_dump\|bloom_dump\|bloom_filter_dump" "$BLOOM_DIR/src/" 2>/dev/null; then
  check "BF.DUMP referenced in source code" 0
else
  check "BF.DUMP referenced in source code" 1
fi

# Check that a test exists for BF.DUMP
TESTS_FOUND=0
# Check Rust unit tests
if grep -rq "dump\|DUMP" "$BLOOM_DIR/src/" --include="*.rs" 2>/dev/null | grep -qi "test\|#\[test\]"; then
  TESTS_FOUND=1
fi
# Check Python integration tests
if grep -rq "BF.DUMP\|bf.dump\|dump" "$BLOOM_DIR/tests/" --include="*.py" 2>/dev/null; then
  TESTS_FOUND=1
fi
# Check any test file that references dump
if find "$BLOOM_DIR" -name "*.rs" -o -name "*.py" | xargs grep -li "dump" 2>/dev/null | grep -qi "test"; then
  TESTS_FOUND=1
fi

if [ "$TESTS_FOUND" = "1" ]; then
  check "test file exists for BF.DUMP" 0
else
  check "test file exists for BF.DUMP" 1
fi

# Check command metadata JSON exists
if find "$BLOOM_DIR/src/commands/" -name "*dump*" 2>/dev/null | grep -q .; then
  check "command metadata JSON exists for BF.DUMP" 0
else
  check "command metadata JSON exists for BF.DUMP" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
