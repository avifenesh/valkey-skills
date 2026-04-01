#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 1: Valkey Bug Investigation
# Usage: test.sh <workspace_dir>
# Validates analysis, patch, and verification script

WORK_DIR="$(cd "${1:-.}" && pwd)"

cleanup() { cd "$WORK_DIR"; docker compose down -v --remove-orphans 2>/dev/null || true; }
trap cleanup EXIT

ANALYSIS="$WORK_DIR/ANALYSIS.md"
PATCH="$WORK_DIR/fix.patch"
VERIFY="$WORK_DIR/verify.sh"

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

# --- Part 1: Analysis quality (3 checks) ---

if [[ ! -f "$ANALYSIS" ]]; then
  check "ANALYSIS.md exists" 1
  check "identifies t_hash.c" 1
  check "explains field existence check" 1
else
  check "ANALYSIS.md exists" 0
  CONTENT=$(cat "$ANALYSIS" | tr '[:upper:]' '[:lower:]')

  echo "$CONTENT" | grep -qE 't_hash\.c'
  check "identifies t_hash.c as the source file" "$?"

  echo "$CONTENT" | grep -qE 'hashtypeexists|hashtypefind|field.?exist|existence.?check|check.*(exists|presence|field)|(should|must).*(check|verify).*(exist|present).*(before|prior)'
  check "explains field existence check mechanism" "$?"
fi

# --- Part 2: Patch quality (4 checks) ---

if [[ ! -f "$PATCH" ]]; then
  check "fix.patch exists" 1
  check "patch targets t_hash.c" 1
  check "patch is valid unified diff" 1
  check "patch adds field existence check" 1
else
  check "fix.patch exists" 0

  # Patch targets t_hash.c
  grep -qE '^\-\-\-.*t_hash\.c|^\+\+\+.*t_hash\.c|^diff.*t_hash\.c' "$PATCH" 2>/dev/null
  check "patch targets t_hash.c" "$?"

  # Patch is valid unified diff format
  grep -qE '^\-\-\- |^\+\+\+ |^@@' "$PATCH" 2>/dev/null
  check "patch is valid unified diff" "$?"

  # Patch adds a field existence check (looks for added lines with existence logic)
  PATCH_ADDS=$(grep '^+' "$PATCH" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  if echo "$PATCH_ADDS" | grep -qE 'hashtypeexists|hashtypefind|hashtypenext|field.*exist|exist.*field|lookup|!.*found|== null|== 0|not.*found|no.*field'; then
    check "patch adds field existence check" 0
  else
    check "patch adds field existence check" 1
  fi
fi

# --- Part 3: Verification script (3 checks) ---

if [[ ! -f "$VERIFY" ]]; then
  check "verify.sh exists" 1
  check "verify.sh tests HEXPIRE on deleted field" 1
  check "verify.sh tests normal HEXPIRE still works" 1
else
  check "verify.sh exists" 0

  VERIFY_CONTENT=$(cat "$VERIFY" | tr '[:upper:]' '[:lower:]')

  # Tests HEXPIRE on a deleted field
  if echo "$VERIFY_CONTENT" | grep -qE 'hdel|deleted' && echo "$VERIFY_CONTENT" | grep -qE 'hexpire'; then
    check "verify.sh tests HEXPIRE on deleted field" 0
  else
    check "verify.sh tests HEXPIRE on deleted field" 1
  fi

  # Tests that normal HEXPIRE still works on existing fields
  if echo "$VERIFY_CONTENT" | grep -qE 'hset|existing|normal|valid' && echo "$VERIFY_CONTENT" | grep -qE 'hexpire'; then
    check "verify.sh tests normal HEXPIRE still works" 0
  else
    check "verify.sh tests normal HEXPIRE still works" 1
  fi
fi

# --- Part 4: Docker validation - actually run verify.sh (2 checks) ---

# Start the Docker container
cd "$WORK_DIR"
docker compose up -d --wait 2>/dev/null || docker-compose up -d 2>/dev/null || true
sleep 2

# Check Valkey is running
if valkey-cli -p 6401 PING 2>/dev/null | grep -q PONG; then

  # Run the reproduce script to confirm bug exists
  if [[ -f "$WORK_DIR/reproduce.sh" ]]; then
    REPRO_OUT=$(bash "$WORK_DIR/reproduce.sh" 2>&1 || true)
    # Bug should show HEXPIRE returning 1 for deleted field
    if echo "$REPRO_OUT" | grep -qE '1|OK|success'; then
      check "docker: bug is reproducible" 0
    else
      check "docker: bug is reproducible" 1
    fi
  else
    check "docker: bug is reproducible" 1
  fi

  # Run verify.sh if it exists and is executable
  if [[ -f "$VERIFY" ]]; then
    chmod +x "$VERIFY" 2>/dev/null || true
    VERIFY_OUT=$(bash "$VERIFY" 2>&1 || true)
    VERIFY_EXIT=$?

    # Verify script should demonstrate understanding by testing the right things
    if echo "$VERIFY_OUT" | grep -qiE 'hexpire|hexpiretime|pass|success|correct|fixed|expected'; then
      check "docker: verify.sh runs and tests hash TTL commands" 0
    else
      check "docker: verify.sh runs and tests hash TTL commands" 1
    fi
  else
    check "docker: verify.sh runs and tests hash TTL commands" 1
  fi
else
  check "docker: bug is reproducible" 1
  check "docker: verify.sh runs and tests hash TTL commands" 1
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
