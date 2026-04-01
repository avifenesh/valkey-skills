#!/usr/bin/env bash
set -uo pipefail

# Benchmark validation for Task 6: redis-py to GLIDE Python Migration
# Usage: ./test.sh <work_dir>

WORK="${1:-.}"
PASS=0
FAIL=0

check() {
  local name="$1" result="$2"
  if [[ "$result" == "0" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# 1. No redis-py imports remain in app.py
if grep -qE '^\s*(import redis|from redis)' "$WORK/app.py" 2>/dev/null; then
  check "No redis-py imports" 1
else
  check "No redis-py imports" 0
fi

# 2. Uses glide import
if grep -qE '(from glide|import glide)' "$WORK/app.py" 2>/dev/null; then
  check "Uses glide import" 0
else
  check "Uses glide import" 1
fi

# 3. GlideClient or GlideClusterClient used
if grep -qE '(GlideClient|GlideClusterClient)' "$WORK/app.py" "$WORK/conftest.py" 2>/dev/null; then
  check "GlideClient used" 0
else
  check "GlideClient used" 1
fi

# 4. Pipeline migrated to GLIDE Batch
if grep -qE '(Batch\(|ClusterBatch\()' "$WORK/app.py" 2>/dev/null; then
  check "Pipeline uses GLIDE Batch" 0
else
  check "Pipeline uses GLIDE Batch" 1
fi

# 5. Pub/Sub uses GLIDE API (subscribe method or PubSubSubscriptions config)
if grep -qE '(\.subscribe\(|PubSubSubscriptions|get_pubsub_message|try_get_pubsub_message|pubsub_subscriptions)' "$WORK/app.py" 2>/dev/null; then
  check "PubSub uses GLIDE API" 0
else
  check "PubSub uses GLIDE API" 1
fi

# 6. Lua script uses GLIDE invoke_script method
if grep -qE '(invoke_script|Script\()' "$WORK/app.py" 2>/dev/null; then
  check "Lua script uses GLIDE method" 0
else
  check "Lua script uses GLIDE method" 1
fi

# 7. All 8 tests pass
cd "$WORK" || exit 1
pip install -q -r requirements.txt > /dev/null 2>&1
pip_ok=$?
test_output=$(python -m pytest tests/test_app.py -v --tb=short 2>&1)
passed=$(echo "$test_output" | grep -oP '\d+ passed' | grep -oP '\d+')
if [[ "${passed:-0}" -ge 8 ]]; then
  check "All 8 tests pass" 0
else
  check "All 8 tests pass" 1
  echo "  pytest output (last 20 lines):"
  echo "$test_output" | tail -20 | sed 's/^/    /'
fi

# 8. pip install succeeds (valkey-glide installs without error)
if [[ "$pip_ok" -eq 0 ]]; then
  check "pip install succeeds" 0
else
  check "pip install succeeds" 1
fi

# 9. Sorted set uses correct GLIDE methods
if grep -qE '(zadd|zrange_withscores|zrange|zscore|RangeByIndex|RangeByScore|ScoreBoundary)' "$WORK/app.py" 2>/dev/null; then
  check "Sorted set correct methods" 0
else
  check "Sorted set correct methods" 1
fi

# 10. async/await preserved
async_count=$(grep -cE '^\s*async def ' "$WORK/app.py" 2>/dev/null || echo 0)
await_count=$(grep -cE 'await ' "$WORK/app.py" 2>/dev/null || echo 0)
if [[ "$async_count" -ge 5 && "$await_count" -ge 5 ]]; then
  check "async/await preserved" 0
else
  check "async/await preserved" 1
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
