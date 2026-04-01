#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 5: Bloom Feature Addition (BF.COUNT)
# Usage: ./test.sh <work_dir>
# Real build + docker + valkey-cli validation

WORK_DIR="$(cd "${1:-.}" && pwd)"
BLOOM_DIR="$WORK_DIR/valkey-bloom"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" result="$2"
  if [[ "$result" == "0" ]]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

cleanup() {
  cd "$WORK_DIR"
  docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -d "$BLOOM_DIR" ]]; then
  for i in $(seq 1 9); do echo "FAIL: valkey-bloom directory not found"; done
  exit 0
fi

cd "$BLOOM_DIR"

# --- Check 1: cargo build --release succeeds ---
if cargo build --release 2>&1 | tail -5; then
  check "cargo build --release" 0
else
  check "cargo build --release" 1
  # Can't continue without a build
  for i in $(seq 1 8); do echo "FAIL: skipped (build failed)"; done
  exit 0
fi

# --- Check 2: built shared library exists ---
LIB_PATH=""
for ext in so dylib dll; do
  found=$(find target/release -maxdepth 1 -name "*.${ext}" -not -name "*.d" | head -1)
  [[ -n "$found" ]] && LIB_PATH="$found" && break
done

if [[ -n "$LIB_PATH" ]]; then
  check "shared library exists" 0
else
  check "shared library exists" 1
  for i in $(seq 1 7); do echo "FAIL: skipped (no library)"; done
  exit 0
fi

# --- Start Valkey with bloom module ---
# Create a docker-compose for testing
cat > "$WORK_DIR/docker-compose.yml" <<'DOCKER'
services:
  valkey:
    image: valkey/valkey:8.1
    ports:
      - "6399:6379"
    volumes:
      - bloom_lib:/modules
    command: ["valkey-server", "--loadmodule", "/modules/libvalkey_bloom.so"]
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 10
DOCKER

# Copy built library to a temp dir for docker volume
mkdir -p "$WORK_DIR/bloom_lib"
cp "$BLOOM_DIR/$LIB_PATH" "$WORK_DIR/bloom_lib/" 2>/dev/null || true

# Update docker-compose to use bind mount instead of named volume
cat > "$WORK_DIR/docker-compose.yml" <<DOCKER
services:
  valkey:
    image: valkey/valkey:8.1
    ports:
      - "6399:6379"
    volumes:
      - $WORK_DIR/bloom_lib:/modules:ro
    command: ["valkey-server", "--loadmodule", "/modules/$(basename "$LIB_PATH")"]
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 10
DOCKER

cd "$WORK_DIR"
docker compose up -d --wait 2>/dev/null || docker-compose up -d 2>/dev/null || true
sleep 3

CLI="valkey-cli -p 6399"

# --- Check 3: Module loads ---
if $CLI MODULE LIST 2>/dev/null | grep -qi "bloom\|bf"; then
  check "module loads into Valkey" 0
else
  check "module loads into Valkey" 1
  for i in $(seq 1 6); do echo "FAIL: skipped (module not loaded)"; done
  exit 0
fi

# --- Check 4: BF.COUNT on basic filter ---
$CLI BF.ADD testkey item1 > /dev/null 2>&1
$CLI BF.ADD testkey item2 > /dev/null 2>&1
$CLI BF.ADD testkey item3 > /dev/null 2>&1
COUNT_RESULT=$($CLI BF.COUNT testkey 2>&1 || echo "ERR")

if [[ "$COUNT_RESULT" == "3" ]]; then
  check "BF.COUNT returns 3 after 3 adds" 0
elif echo "$COUNT_RESULT" | grep -qE '^[0-9]+$' && [[ "$COUNT_RESULT" -ge 2 && "$COUNT_RESULT" -le 3 ]]; then
  # Allow 2-3 in case of hash collision
  check "BF.COUNT returns 3 after 3 adds" 0
else
  check "BF.COUNT returns 3 after 3 adds (got: $COUNT_RESULT)" 1
fi

# --- Check 5: BF.COUNT on non-existent key returns 0 ---
NOKEY_RESULT=$($CLI BF.COUNT nonexistent_key_xyz 2>&1 || echo "ERR")
if [[ "$NOKEY_RESULT" == "0" ]]; then
  check "BF.COUNT nonexistent key returns 0" 0
else
  check "BF.COUNT nonexistent key returns 0 (got: $NOKEY_RESULT)" 1
fi

# --- Check 6: BF.COUNT on wrong type returns WRONGTYPE ---
$CLI SET stringkey hello > /dev/null 2>&1
WRONG_RESULT=$($CLI BF.COUNT stringkey 2>&1 || echo "")
if echo "$WRONG_RESULT" | grep -qi "WRONGTYPE\|wrong"; then
  check "BF.COUNT wrong type returns WRONGTYPE error" 0
else
  check "BF.COUNT wrong type returns WRONGTYPE (got: $WRONG_RESULT)" 1
fi

# --- Check 7: BF.COUNT on scaled filter with many items ---
$CLI BF.RESERVE scaled 0.01 100 EXPANSION 2 > /dev/null 2>&1
for i in $(seq 1 150); do
  $CLI BF.ADD scaled "item_$i" > /dev/null 2>&1
done
SCALED_RESULT=$($CLI BF.COUNT scaled 2>&1 || echo "ERR")
if echo "$SCALED_RESULT" | grep -qE '^[0-9]+$' && [[ "$SCALED_RESULT" -ge 140 && "$SCALED_RESULT" -le 150 ]]; then
  check "BF.COUNT scaled filter returns ~150" 0
else
  check "BF.COUNT scaled filter returns ~150 (got: $SCALED_RESULT)" 1
fi

# --- Check 8: bf.count.json command metadata exists ---
if [[ -f "$BLOOM_DIR/src/commands/bf.count.json" ]]; then
  # Verify it's valid JSON with BF.COUNT
  if python3 -c "
import json
with open('$BLOOM_DIR/src/commands/bf.count.json') as f:
    d = json.load(f)
assert 'BF.COUNT' in str(d).upper(), 'No BF.COUNT reference'
print('valid')
" 2>/dev/null | grep -q "valid"; then
    check "bf.count.json exists and is valid" 0
  else
    check "bf.count.json exists but invalid" 1
  fi
else
  check "bf.count.json exists" 1
fi

# --- Check 9: Unit test added ---
if grep -rq "bf.count\|bf_count\|bloom_filter_count\|bloom_count" "$BLOOM_DIR/src/bloom/" --include="*.rs" 2>/dev/null; then
  # Check if there's a test annotation near the count function
  if grep -rq "#\[test\]\|#\[rstest\]" "$BLOOM_DIR/src/bloom/utils.rs" 2>/dev/null && grep -rq "count" "$BLOOM_DIR/src/bloom/utils.rs" 2>/dev/null; then
    check "unit test references count functionality" 0
  else
    check "unit test references count functionality" 1
  fi
else
  check "count handler exists in source" 1
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
