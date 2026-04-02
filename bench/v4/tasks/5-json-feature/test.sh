#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 5: Add JSON.MERGE command to valkey-json
# Usage: test.sh <workspace_dir>
# Validates that JSON.MERGE is implemented, builds, and works correctly.

WORK_DIR="$(cd "${1:-.}" && pwd)"
JSON_DIR="$WORK_DIR/valkey-json"
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

echo "Building valkey-json module..."
cd "$JSON_DIR"
if [ -f "build.sh" ]; then
  BUILD_OUTPUT=$(bash build.sh 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
elif [ -f "CMakeLists.txt" ]; then
  mkdir -p build && cd build
  BUILD_OUTPUT=$(cmake .. 2>&1 && make -j4 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
  cd "$JSON_DIR"
else
  BUILD_OUTPUT=$(cargo build --release 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
fi

if [ "$BUILD_EXIT" = "0" ]; then
  check "build succeeds" 0
else
  echo "$BUILD_OUTPUT" | tail -10
  check "build succeeds" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# Check .so/.dylib file exists
SO_FILE=$(find "$JSON_DIR" -maxdepth 3 \( -name "*.so" -o -name "*.dylib" \) -path "*/build/*" -o \( -name "*.so" -o -name "*.dylib" \) -path "*/release/*" 2>/dev/null | head -1)
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
echo "Starting valkey-server with json module..."
DBDIR=$(mktemp -d)
valkey-server --port $PORT --loadmodule "$SO_FILE" \
  --daemonize yes --dir "$DBDIR" --dbfilename dump.rdb \
  --loglevel warning 2>&1 || true
sleep 1

# Verify server is up
if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server starts with json module" 0
else
  check "valkey-server starts with json module" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# =========================================
# JSON.MERGE FUNCTIONAL TESTS
# =========================================

echo ""
echo "Testing JSON.MERGE command..."

# Set up test document
valkey-cli -p $PORT JSON.SET doc '$' '{"name":"Alice","age":30,"address":{"city":"NYC","zip":"10001"}}' >/dev/null 2>&1

# Test 1: Merge to update and add fields
MERGE_RESULT=$(valkey-cli -p $PORT JSON.MERGE doc '$' '{"age":31,"email":"alice@example.com"}' 2>/dev/null)
if echo "$MERGE_RESULT" | grep -q "OK"; then
  check "JSON.MERGE returns OK on update+add" 0
else
  check "JSON.MERGE returns OK on update+add (got: $MERGE_RESULT)" 1
fi

# Test 2: age updated to 31
AGE_RESULT=$(valkey-cli -p $PORT JSON.GET doc '$.age' 2>/dev/null)
if echo "$AGE_RESULT" | grep -q "31"; then
  check "JSON.GET $.age returns 31 (updated)" 0
else
  check "JSON.GET $.age returns 31 (got: $AGE_RESULT)" 1
fi

# Test 3: email added
EMAIL_RESULT=$(valkey-cli -p $PORT JSON.GET doc '$.email' 2>/dev/null)
if echo "$EMAIL_RESULT" | grep -q "alice@example.com"; then
  check "JSON.GET $.email returns alice@example.com (added)" 0
else
  check "JSON.GET $.email returns alice@example.com (got: $EMAIL_RESULT)" 1
fi

# Test 4: name unchanged
NAME_RESULT=$(valkey-cli -p $PORT JSON.GET doc '$.name' 2>/dev/null)
if echo "$NAME_RESULT" | grep -q "Alice"; then
  check "JSON.GET $.name returns Alice (unchanged)" 0
else
  check "JSON.GET $.name returns Alice (got: $NAME_RESULT)" 1
fi

# Test 5: Merge with null to delete and add nested fields
MERGE2_RESULT=$(valkey-cli -p $PORT JSON.MERGE doc '$' '{"address":{"zip":null,"state":"NY"}}' 2>/dev/null)
if echo "$MERGE2_RESULT" | grep -q "OK"; then
  check "JSON.MERGE returns OK on null-delete+add nested" 0
else
  check "JSON.MERGE returns OK on null-delete+add nested (got: $MERGE2_RESULT)" 1
fi

# Test 6: zip deleted by null merge
ZIP_RESULT=$(valkey-cli -p $PORT JSON.GET doc '$.address.zip' 2>/dev/null)
if echo "$ZIP_RESULT" | grep -qE '^\[\]$|^$' || [ -z "$ZIP_RESULT" ]; then
  check "JSON.GET $.address.zip returns empty (deleted by null merge)" 0
else
  check "JSON.GET $.address.zip returns empty (got: $ZIP_RESULT)" 1
fi

# Test 7: state added
STATE_RESULT=$(valkey-cli -p $PORT JSON.GET doc '$.address.state' 2>/dev/null)
if echo "$STATE_RESULT" | grep -q "NY"; then
  check "JSON.GET $.address.state returns NY (added)" 0
else
  check "JSON.GET $.address.state returns NY (got: $STATE_RESULT)" 1
fi

# Test 8: city unchanged
CITY_RESULT=$(valkey-cli -p $PORT JSON.GET doc '$.address.city' 2>/dev/null)
if echo "$CITY_RESULT" | grep -q "NYC"; then
  check "JSON.GET $.address.city returns NYC (unchanged)" 0
else
  check "JSON.GET $.address.city returns NYC (got: $CITY_RESULT)" 1
fi

# =========================================
# SOURCE CODE CHECKS
# =========================================

echo ""
echo "Source code analysis..."

# Check MERGE appears in source
if grep -rqi "merge\|MERGE" "$JSON_DIR/src/" 2>/dev/null; then
  check "MERGE referenced in source code" 0
else
  check "MERGE referenced in source code" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
