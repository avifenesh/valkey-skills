#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 5: Bloom Feature Addition (BF.COUNT)
# Usage: ./test.sh <work_dir>
# Outputs PASS:/FAIL: lines consumed by the benchmark runner.

WORK_DIR="${1:-.}"
BLOOM_DIR="$WORK_DIR/valkey-bloom"

if [[ ! -d "$BLOOM_DIR" ]]; then
  echo "FAIL: valkey-bloom directory not found at $BLOOM_DIR"
  echo "FAIL: test_module_loads"
  echo "FAIL: test_bf_count_basic"
  echo "FAIL: test_bf_count_nonexistent"
  echo "FAIL: test_bf_count_wrongtype"
  echo "FAIL: test_bf_count_scaled"
  echo "FAIL: test_bf_count_json"
  exit 0
fi

cd "$BLOOM_DIR"

# ---------------------------------------------------------------
# Check 1: cargo build --release succeeds
# ---------------------------------------------------------------
if cargo build --release 2>&1; then
  echo "PASS: cargo_build_release"
else
  echo "FAIL: cargo_build_release"
  echo "FAIL: test_module_loads"
  echo "FAIL: test_bf_count_basic"
  echo "FAIL: test_bf_count_nonexistent"
  echo "FAIL: test_bf_count_wrongtype"
  echo "FAIL: test_bf_count_scaled"
  echo "FAIL: test_bf_count_json"
  exit 0
fi

# Locate the built shared library
SO_FILE=""
for candidate in \
  target/release/libvalkey_bloom.so \
  target/release/libvalkey_bloom.dylib \
  target/release/valkey_bloom.dll; do
  if [[ -f "$candidate" ]]; then
    SO_FILE="$candidate"
    break
  fi
done

# ---------------------------------------------------------------
# Check 2: Module loads (shared library exists)
# ---------------------------------------------------------------
if [[ -n "$SO_FILE" ]]; then
  echo "PASS: test_module_loads"
else
  echo "FAIL: test_module_loads"
fi

# ---------------------------------------------------------------
# Source code analysis checks (grep-based)
# We verify the command is registered and implemented correctly
# by inspecting the source, since we cannot run a live Valkey
# server in the benchmark sandbox.
# ---------------------------------------------------------------

LIB_RS="src/lib.rs"
CMD_HANDLER="src/bloom/command_handler.rs"

# ---------------------------------------------------------------
# Check 3: BF.ADD + BF.COUNT - command is registered and handler
#           calls a function that sums num_items
# ---------------------------------------------------------------
bf_count_registered=false
bf_count_handler_exists=false

# Check registration in lib.rs
if grep -q '"BF.COUNT"' "$LIB_RS" 2>/dev/null; then
  bf_count_registered=true
fi

# Check that a handler function exists that deals with BF.COUNT
# It should be in command_handler.rs or lib.rs
if grep -qE 'bloom_filter_count|bloom_count' "$CMD_HANDLER" 2>/dev/null || \
   grep -qE 'bloom_filter_count|bloom_count' "$LIB_RS" 2>/dev/null; then
  bf_count_handler_exists=true
fi

if $bf_count_registered && $bf_count_handler_exists; then
  echo "PASS: test_bf_count_basic"
else
  echo "FAIL: test_bf_count_basic (registered=$bf_count_registered, handler=$bf_count_handler_exists)"
fi

# ---------------------------------------------------------------
# Check 4: BF.COUNT nonexistent returns 0
#           Verify the handler returns Integer(0) for None/missing key
# ---------------------------------------------------------------
# Look for the pattern: None => ... Integer(0) in the count handler
# or a function that matches the BF.CARD pattern for the None case
count_returns_zero=false

# The handler should have a None arm returning 0, similar to bloom_filter_card
if grep -qE 'None\s*=>' "$CMD_HANDLER" 2>/dev/null; then
  # Check that somewhere near a count-related function there is Integer(0)
  if grep -A2 'bloom_filter_count\|bloom_count' "$CMD_HANDLER" 2>/dev/null | head -50 | grep -q 'Integer(0)\|Integer( 0 )' 2>/dev/null; then
    count_returns_zero=true
  fi
  # Fallback: check if the count function body contains None => Ok(ValkeyValue::Integer(0))
  if ! $count_returns_zero; then
    # Extract the count function and check for the None => Integer(0) pattern
    if python3 -c "
import re, sys
with open('$CMD_HANDLER') as f:
    content = f.read()
# Find any function with 'count' in the name
matches = re.findall(r'pub fn bloom_filter_count.*?^}', content, re.DOTALL | re.MULTILINE)
if not matches:
    matches = re.findall(r'pub fn bloom_count.*?^}', content, re.DOTALL | re.MULTILINE)
for m in matches:
    if 'None' in m and 'Integer(0)' in m:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
      count_returns_zero=true
    fi
  fi
fi

if $count_returns_zero; then
  echo "PASS: test_bf_count_nonexistent"
else
  echo "FAIL: test_bf_count_nonexistent"
fi

# ---------------------------------------------------------------
# Check 5: WRONGTYPE for non-bloom keys
#           The handler should return WrongType error
# ---------------------------------------------------------------
wrongtype_handled=false

if python3 -c "
import re, sys
with open('$CMD_HANDLER') as f:
    content = f.read()
matches = re.findall(r'pub fn bloom_filter_count.*?^}', content, re.DOTALL | re.MULTILINE)
if not matches:
    matches = re.findall(r'pub fn bloom_count.*?^}', content, re.DOTALL | re.MULTILINE)
for m in matches:
    if 'WrongType' in m:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  wrongtype_handled=true
fi

if $wrongtype_handled; then
  echo "PASS: test_bf_count_wrongtype"
else
  echo "FAIL: test_bf_count_wrongtype"
fi

# ---------------------------------------------------------------
# Check 6: Scaled filter - handler sums num_items across filters
#           Verify it iterates over filters or calls cardinality()
# ---------------------------------------------------------------
sums_across_filters=false

if python3 -c "
import re, sys
with open('$CMD_HANDLER') as f:
    content = f.read()
matches = re.findall(r'pub fn bloom_filter_count.*?^}', content, re.DOTALL | re.MULTILINE)
if not matches:
    matches = re.findall(r'pub fn bloom_count.*?^}', content, re.DOTALL | re.MULTILINE)
for m in matches:
    # Should call cardinality() or iterate filters summing num_items
    if 'cardinality()' in m or 'num_items' in m:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  sums_across_filters=true
fi

if $sums_across_filters; then
  echo "PASS: test_bf_count_scaled"
else
  echo "FAIL: test_bf_count_scaled"
fi

# ---------------------------------------------------------------
# Check 7: bf.count.json exists and is valid JSON
# ---------------------------------------------------------------
JSON_FILE="src/commands/bf.count.json"

if [[ -f "$JSON_FILE" ]]; then
  if python3 -c "
import json, sys
with open('$JSON_FILE') as f:
    data = json.load(f)
# Verify it has the expected top-level key
if 'BF.COUNT' in data:
    entry = data['BF.COUNT']
    # Check required fields
    required = ['summary', 'group', 'arity', 'acl_categories']
    for r in required:
        if r not in entry:
            print(f'Missing field: {r}', file=sys.stderr)
            sys.exit(1)
    if entry['arity'] != 2:
        print(f'Wrong arity: {entry[\"arity\"]}', file=sys.stderr)
        sys.exit(1)
    if 'BLOOM' not in [c.upper() for c in entry['acl_categories']]:
        print('Missing BLOOM acl category', file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
else:
    print('Missing BF.COUNT key', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
    echo "PASS: test_bf_count_json"
  else
    echo "FAIL: test_bf_count_json (invalid structure)"
  fi
else
  echo "FAIL: test_bf_count_json (file not found)"
fi
