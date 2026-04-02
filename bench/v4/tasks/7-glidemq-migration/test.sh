#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 7: BullMQ to glide-mq Migration
# Usage: test.sh <workspace_dir>
# Validates that the BullMQ application has been correctly migrated to glide-mq.

WORK_DIR="$(cd "${1:-.}" && pwd)"
PORT=6507

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

file_has() {
  grep -qE "$1" "$2" 2>/dev/null
}

file_lacks() {
  ! grep -qE "$1" "$2" 2>/dev/null
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

# =========================================
# INSTALL DEPENDENCIES
# =========================================

echo ""
echo "Installing dependencies..."
cd "$WORK_DIR"
npm install 2>&1 || true

# =========================================
# PACKAGE.JSON CHECKS
# =========================================

echo ""
echo "Checking package.json..."

PKG="$WORK_DIR/package.json"

# Check 1: No bullmq in dependencies
if [ -f "$PKG" ] && file_lacks '"bullmq"' "$PKG"; then
  check "package.json: no bullmq dependency" 0
else
  check "package.json: no bullmq dependency" 1
fi

# Check 2: glide-mq in dependencies
if [ -f "$PKG" ] && file_has '"glide-mq"' "$PKG"; then
  check "package.json: has glide-mq dependency" 0
else
  check "package.json: has glide-mq dependency" 1
fi

# Check 3: No ioredis in dependencies
if [ -f "$PKG" ] && file_lacks '"ioredis"' "$PKG"; then
  check "package.json: no ioredis dependency" 0
else
  check "package.json: no ioredis dependency" 1
fi

# =========================================
# SOURCE CODE CHECKS
# =========================================

echo ""
echo "Checking source code..."

# Find all TypeScript source files (exclude test files and node_modules)
SRC_FILES=$(find "$WORK_DIR/src" -name "*.ts" ! -name "*.test.ts" 2>/dev/null)

if [ -z "$SRC_FILES" ]; then
  check "TypeScript source files exist" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# Check 4: No bullmq imports in source
HAS_BULLMQ=false
for f in $SRC_FILES; do
  if file_has "from ['\"]bullmq['\"]|require\(['\"]bullmq['\"]" "$f"; then
    HAS_BULLMQ=true
    break
  fi
done
if [ "$HAS_BULLMQ" = "false" ]; then
  check "source: no bullmq imports" 0
else
  check "source: no bullmq imports" 1
fi

# Check 5: No ioredis imports in source
HAS_IOREDIS=false
for f in $SRC_FILES; do
  if file_has "from ['\"]ioredis['\"]|require\(['\"]ioredis['\"]|new IORedis" "$f"; then
    HAS_IOREDIS=true
    break
  fi
done
if [ "$HAS_IOREDIS" = "false" ]; then
  check "source: no ioredis imports" 0
else
  check "source: no ioredis imports" 1
fi

# Check 6: Uses glide-mq imports
HAS_GLIDEMQ=false
for f in $SRC_FILES; do
  if file_has "from ['\"]glide-mq['\"]" "$f"; then
    HAS_GLIDEMQ=true
    break
  fi
done
if [ "$HAS_GLIDEMQ" = "true" ]; then
  check "source: imports from glide-mq" 0
else
  check "source: imports from glide-mq" 1
fi

# Check 7: Uses addresses connection format
HAS_ADDRESSES=false
for f in $SRC_FILES; do
  if file_has "addresses\s*:" "$f"; then
    HAS_ADDRESSES=true
    break
  fi
done
if [ "$HAS_ADDRESSES" = "true" ]; then
  check "source: uses addresses connection format" 0
else
  check "source: uses addresses connection format" 1
fi

# Check 8: Uses upsertJobScheduler (not repeat)
HAS_SCHEDULER=false
for f in $SRC_FILES; do
  if file_has "upsertJobScheduler" "$f"; then
    HAS_SCHEDULER=true
    break
  fi
done
if [ "$HAS_SCHEDULER" = "true" ]; then
  check "source: uses upsertJobScheduler" 0
else
  check "source: uses upsertJobScheduler" 1
fi

# Check 9: No repeat: { every: pattern
HAS_REPEAT=false
for f in $SRC_FILES; do
  if file_has "repeat\s*:\s*\{" "$f"; then
    HAS_REPEAT=true
    break
  fi
done
if [ "$HAS_REPEAT" = "false" ]; then
  check "source: no repeat option (uses scheduler)" 0
else
  check "source: no repeat option (uses scheduler)" 1
fi

# Check 10: No defaultJobOptions
HAS_DEFAULT_OPTS=false
for f in $SRC_FILES; do
  if file_has "defaultJobOptions" "$f"; then
    HAS_DEFAULT_OPTS=true
    break
  fi
done
if [ "$HAS_DEFAULT_OPTS" = "false" ]; then
  check "source: no defaultJobOptions (removed in glide-mq)" 0
else
  check "source: no defaultJobOptions (removed in glide-mq)" 1
fi

# Check 11: Uses backoffStrategies (not settings.backoffStrategy)
HAS_BACKOFF_STRATEGIES=false
for f in $SRC_FILES; do
  if file_has "backoffStrategies" "$f"; then
    HAS_BACKOFF_STRATEGIES=true
    break
  fi
done
if [ "$HAS_BACKOFF_STRATEGIES" = "true" ]; then
  check "source: uses backoffStrategies map" 0
else
  check "source: uses backoffStrategies map" 1
fi

# Check 12: No settings.backoffStrategy
HAS_OLD_BACKOFF=false
for f in $SRC_FILES; do
  if file_has "settings\s*:.*backoffStrategy|backoffStrategy\s*:" "$f"; then
    HAS_OLD_BACKOFF=true
    break
  fi
done
if [ "$HAS_OLD_BACKOFF" = "false" ]; then
  check "source: no settings.backoffStrategy" 0
else
  check "source: no settings.backoffStrategy" 1
fi

# Check 13: waitUntilFinished does not take queueEvents as first arg
HAS_OLD_WAIT=false
for f in $SRC_FILES; do
  if file_has "waitUntilFinished\s*\(\s*queueEvents" "$f"; then
    HAS_OLD_WAIT=true
    break
  fi
done
if [ "$HAS_OLD_WAIT" = "false" ]; then
  check "source: waitUntilFinished uses new signature" 0
else
  check "source: waitUntilFinished uses new signature" 1
fi

# =========================================
# BUILD CHECK
# =========================================

echo ""
echo "Checking TypeScript build..."
cd "$WORK_DIR"
if npm run build 2>&1; then
  check "npm run build succeeds" 0
else
  check "npm run build succeeds" 1
fi

# =========================================
# TEST EXECUTION
# =========================================

echo ""
echo "Running tests..."
cd "$WORK_DIR"
TEST_OUTPUT=$(npm test 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?

echo "$TEST_OUTPUT"

if [ "$TEST_EXIT" = "0" ]; then
  check "npm test passes" 0
else
  check "npm test passes" 1
fi

# Count passed/failed tests from vitest output
TESTS_PASSED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+" || echo "0")
TESTS_FAILED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" || echo "0")

if [ "$TESTS_PASSED" -ge 6 ] 2>/dev/null; then
  check "6+ vitest tests pass" 0
else
  check "6+ vitest tests pass ($TESTS_PASSED passed)" 1
fi

if [ "$TESTS_FAILED" = "0" ] && [ "$TESTS_PASSED" -gt 0 ] 2>/dev/null; then
  check "vitest: zero failures" 0
else
  check "vitest: zero failures ($TESTS_FAILED failed)" 1
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
