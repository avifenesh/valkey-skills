#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 8: Session Store with Per-Field Independent Expiration
# Usage: test.sh <workspace_dir>
# Validates that session_manager.py uses Valkey 9.0 hash field TTL commands
# (HSETEX, HGETEX, HEXPIRE, HTTL) instead of key-level EXPIRE or separate keys.

WORK_DIR="$(cd "${1:-.}" && pwd)"
PORT=6508

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
# ENVIRONMENT SETUP
# =========================================

echo "Starting valkey-server on port $PORT..."
valkey-server --port $PORT --daemonize yes --loglevel warning --save "" 2>&1 || true
sleep 1

if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server started" 0
else
  check "valkey-server started" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

echo ""
echo "Installing dependencies..."
cd "$WORK_DIR"
pip install -r requirements.txt -q 2>&1 || true

# =========================================
# STATIC ANALYSIS CHECKS
# =========================================

echo ""
echo "Static analysis of session_manager.py..."

SM_FILE="$WORK_DIR/session_manager.py"

if [ ! -f "$SM_FILE" ]; then
  echo "FAIL: session_manager.py not found"
  echo ""
  echo "========================================="
  echo "Results: 0 passed, 1 failed out of 1 checks"
  echo "========================================="
  exit 1
fi
check "session_manager.py exists" 0

# Check 1: Does NOT use key-level EXPIRE (the whole-key version)
# Allow HEXPIRE but reject bare EXPIRE used on the session key
# We look for EXPIRE that is NOT preceded by H (to catch execute_command("EXPIRE", ...))
if grep -E "(execute_command|sendcommand|send_command)\s*\(\s*['\"]EXPIRE['\"]" "$SM_FILE" 2>/dev/null | grep -qvE "HEXPIRE|HPEXPIRE"; then
  check "does NOT use key-level EXPIRE command" 1
else
  check "does NOT use key-level EXPIRE command" 0
fi

# Also check for client.expire() method calls
if grep -qE "\.expire\s*\(" "$SM_FILE" 2>/dev/null; then
  check "does NOT use client.expire() method" 1
else
  check "does NOT use client.expire() method" 0
fi

# Check 2: Uses hash field TTL commands (HSETEX, HGETEX, HEXPIRE, or HTTL)
HAS_HASH_TTL=false
if grep -qiE "HSETEX|HGETEX|HEXPIRE|HTTL|HPEXPIRE|HPTTL" "$SM_FILE" 2>/dev/null; then
  HAS_HASH_TTL=true
fi
if [ "$HAS_HASH_TTL" = "true" ]; then
  check "uses hash field TTL commands (HSETEX/HGETEX/HEXPIRE/HTTL)" 0
else
  check "uses hash field TTL commands (HSETEX/HGETEX/HEXPIRE/HTTL)" 1
fi

# Check 3: Uses HSETEX specifically (the set-with-TTL command)
if grep -qiE "HSETEX" "$SM_FILE" 2>/dev/null; then
  check "uses HSETEX command" 0
else
  check "uses HSETEX command" 1
fi

# Check 4: Uses HGETEX (get-and-refresh-TTL command)
if grep -qiE "HGETEX" "$SM_FILE" 2>/dev/null; then
  check "uses HGETEX command" 0
else
  check "uses HGETEX command" 1
fi

# Check 5: Uses HTTL or HPTTL (check remaining TTL on fields)
if grep -qiE "HTTL|HPTTL" "$SM_FILE" 2>/dev/null; then
  check "uses HTTL/HPTTL command" 0
else
  check "uses HTTL/HPTTL command" 1
fi

# Check 6: Does NOT create separate keys per field
# Look for patterns like f"session:{sid}:{field}" or key + ":" + field
if grep -qE 'session.*:.*\{field|session.*:.*field_name|f"[^"]*:[^"]*\{[^}]*\}:[^"]*\{' "$SM_FILE" 2>/dev/null; then
  check "does NOT create separate keys per field" 1
else
  check "does NOT create separate keys per field" 0
fi

# Check 7: Uses the FIELDS keyword in commands (correct Valkey 9.0 syntax)
if grep -qiE "'FIELDS'|\"FIELDS\"" "$SM_FILE" 2>/dev/null; then
  check "uses FIELDS keyword (correct Valkey 9.0 syntax)" 0
else
  check "uses FIELDS keyword (correct Valkey 9.0 syntax)" 1
fi

# Check 8: Uses FXX flag for conditional updates (rotate_token)
if grep -qiE "FXX|'XX'" "$SM_FILE" 2>/dev/null; then
  check "uses FXX or XX flag for conditional field updates" 0
else
  check "uses FXX or XX flag for conditional field updates" 1
fi

# =========================================
# PYTEST EXECUTION
# =========================================

echo ""
echo "Running pytest..."

cd "$WORK_DIR"
PYTEST_OUTPUT=$(python -m pytest test_session.py -v 2>&1) && PYTEST_EXIT=0 || PYTEST_EXIT=$?

echo "$PYTEST_OUTPUT"

# Count passed tests
TESTS_PASSED=$(echo "$PYTEST_OUTPUT" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+" || echo "0")
TESTS_FAILED=$(echo "$PYTEST_OUTPUT" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" || echo "0")
TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED))

echo ""
echo "Pytest results: $TESTS_PASSED passed, $TESTS_FAILED failed out of $TESTS_TOTAL tests"

if [ "$TESTS_PASSED" -ge 8 ]; then
  check "pytest: 8+ tests pass" 0
else
  check "pytest: 8+ tests pass ($TESTS_PASSED passed)" 1
fi

if [ "$TESTS_FAILED" -eq 0 ] && [ "$TESTS_PASSED" -gt 0 ]; then
  check "pytest: zero failures" 0
else
  check "pytest: zero failures ($TESTS_FAILED failed)" 1
fi

# =========================================
# SUMMARY
# =========================================

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
