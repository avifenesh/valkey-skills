#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 7: Optimized Message Queue with Distributed Locking
# Usage: test.sh <workspace_dir>
# Validates correctness, safety patterns, and proper Valkey usage.

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
# INSTALL AND BUILD
# =========================================

echo ""
echo "Installing dependencies..."
cd "$WORK_DIR"
npm install 2>&1 || true

echo ""
echo "Building TypeScript..."
cd "$WORK_DIR"
if npm run build 2>&1; then
  check "npm run build succeeds" 0
else
  check "npm run build succeeds" 1
fi

# =========================================
# DEPENDENCY CHECKS
# =========================================

echo ""
echo "Checking dependencies..."

PKG="$WORK_DIR/package.json"
SRC="$WORK_DIR/src/mq.ts"

# Must use @valkey/valkey-glide
if [ -f "$PKG" ] && file_has '"@valkey/valkey-glide"' "$PKG"; then
  check "package.json: has @valkey/valkey-glide" 0
else
  check "package.json: has @valkey/valkey-glide" 1
fi

# Must NOT use ioredis
if [ -f "$PKG" ] && file_lacks '"ioredis"' "$PKG"; then
  check "package.json: no ioredis" 0
else
  check "package.json: no ioredis" 1
fi

# Must NOT use redis
if [ -f "$PKG" ] && file_lacks '"redis"' "$PKG"; then
  check "package.json: no redis package" 0
else
  check "package.json: no redis package" 1
fi

# =========================================
# SOURCE CODE CHECKS
# =========================================

echo ""
echo "Checking source code patterns..."

if [ ! -f "$SRC" ]; then
  check "src/mq.ts exists" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

check "src/mq.ts exists" 0

# Uses GlideClient or GlideClusterClient
if file_has "GlideClient|GlideClusterClient" "$SRC"; then
  check "source: uses GlideClient" 0
else
  check "source: uses GlideClient" 1
fi

# Lock release uses Lua script (Script class, invokeScript, or EVAL)
if file_has "Script|invokeScript|invoke_script|EVAL|evalsha" "$SRC"; then
  check "source: lock release uses Lua script" 0
else
  check "source: lock release uses Lua script" 1
fi

# Lock acquire uses SET with NX (SetOptions or conditional set)
if file_has "NX|conditionalSet|ConditionalChange|nx:" "$SRC"; then
  check "source: lock uses SET NX" 0
else
  check "source: lock uses SET NX" 1
fi

# Queue uses stream commands (xadd or xreadgroup)
if file_has "xadd|xreadgroup|xgroupCreate" "$SRC"; then
  check "source: queue uses stream commands" 0
else
  check "source: queue uses stream commands" 1
fi

# Queue uses xack
if file_has "xack" "$SRC"; then
  check "source: queue uses XACK" 0
else
  check "source: queue uses XACK" 1
fi

# Rate limiter uses sorted set commands
if file_has "zadd|zremrangebyscore|zrangebyscore|ZADD|ZREMRANGEBYSCORE" "$SRC"; then
  check "source: rate limiter uses sorted set commands" 0
else
  check "source: rate limiter uses sorted set commands" 1
fi

# Rate limiter uses ZCARD or count
if file_has "zcard|ZCARD|zcount|ZCOUNT" "$SRC"; then
  check "source: rate limiter counts entries" 0
else
  check "source: rate limiter counts entries" 1
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

if [ "$TESTS_PASSED" -ge 9 ] 2>/dev/null; then
  check "9+ vitest tests pass" 0
else
  check "9+ vitest tests pass ($TESTS_PASSED passed)" 1
fi

if [ "$TESTS_FAILED" = "0" ] && [ "$TESTS_PASSED" -gt 0 ] 2>/dev/null; then
  check "vitest: zero failures" 0
else
  check "vitest: zero failures ($TESTS_FAILED failed)" 1
fi

# =========================================
# PERFORMANCE BENCHMARK
# =========================================

echo ""
echo "Running performance benchmark..."
cd "$WORK_DIR"

# Run bench.ts if it exists, or a simple inline perf test
BENCH_JS=""
if [ -f "dist/bench.js" ]; then
  BENCH_JS="dist/bench.js"
elif [ -f "build/bench.js" ]; then
  BENCH_JS="build/bench.js"
elif [ -f "src/bench.js" ]; then
  BENCH_JS="src/bench.js"
fi

if [ -n "$BENCH_JS" ]; then
  BENCH_OUTPUT=$(node "$BENCH_JS" 2>&1) && BENCH_EXIT=0 || BENCH_EXIT=$?
elif [ -f "src/bench.ts" ]; then
  BENCH_OUTPUT=$(npx tsx src/bench.ts 2>&1) && BENCH_EXIT=0 || BENCH_EXIT=$?
  echo "$BENCH_OUTPUT"

  # Extract ops/sec from output (look for patterns like "1234 ops/sec" or "ops/s: 1234")
  OPS_SEC=$(echo "$BENCH_OUTPUT" | grep -oE '[0-9]+\.?[0-9]* ops' | head -1 | grep -oE '[0-9]+\.?[0-9]*' || echo "0")

  if [ "$(echo "$OPS_SEC > 100" | bc 2>/dev/null || echo 0)" = "1" ]; then
    check "performance: queue achieves >100 ops/sec ($OPS_SEC)" 0
  else
    # Fallback: just check bench ran without crash
    if [ "$BENCH_EXIT" = "0" ]; then
      check "performance: benchmark completed without crash" 0
    else
      check "performance: benchmark completed without crash" 1
    fi
  fi
else
  # No bench file - run inline perf test
  PERF_SCRIPT=$(mktemp /tmp/perf_XXXXXX.py)
  cat > "$PERF_SCRIPT" <<'PYEOF'
import subprocess, time
# Simple perf test: 1000 SET/GET operations via valkey-cli
PORT = "6507"
start = time.time()
for i in range(500):
    subprocess.run(["valkey-cli", "-p", PORT, "SET", f"perf:{i}", f"val:{i}"], capture_output=True)
    subprocess.run(["valkey-cli", "-p", PORT, "GET", f"perf:{i}"], capture_output=True)
elapsed = time.time() - start
ops = 1000 / elapsed
print(f"{ops:.0f} ops/sec ({elapsed:.2f}s for 1000 ops)")
PYEOF
  PERF_OUT=$(python3 "$PERF_SCRIPT" 2>&1)
  rm -f "$PERF_SCRIPT"
  echo "$PERF_OUT"
  check "performance: baseline benchmark ran" 0
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
