#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 10: Ops Hardening
# Usage: test.sh <workspace_dir>
# Validates the fixed valkey.conf, answers.md, and AUDIT.md

WORK_DIR="$(cd "${1:-.}" && pwd)"
PORT=6510

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

FIXED_CONF="$WORK_DIR/valkey-fixed.conf"
ANSWERS="$WORK_DIR/answers.md"
AUDIT="$WORK_DIR/AUDIT.md"

# =========================================
# CHECK 1: valkey-fixed.conf exists
# =========================================
if [ ! -f "$FIXED_CONF" ]; then
  echo "FAIL: valkey-fixed.conf not found"
  echo ""
  echo "========================================="
  echo "Results: 0 passed, 1 failed out of 1 checks"
  echo "========================================="
  exit 1
fi
check "valkey-fixed.conf exists" 0

# =========================================
# CHECK 2: Server starts with fixed config
# =========================================
echo "Starting valkey-server with fixed config on port $PORT..."

# Override port, daemonize, and disable ACL auth for testing
valkey-server "$FIXED_CONF" --port $PORT --daemonize yes \
  --loglevel warning --save "" --appendonly no \
  --requirepass "" --protected-mode no \
  --aclfile "" --user "default on nopass ~* &* +@all" 2>&1 || true
sleep 2

if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server starts with fixed config" 0
else
  check "valkey-server starts with fixed config" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# =========================================
# CONFIG FILE CONTENT CHECKS
# =========================================
echo ""
echo "Checking fixed config file contents..."

# Helper: check if a pattern appears in the config file (case-insensitive)
config_has() {
  grep -qiE "$1" "$FIXED_CONF" 2>/dev/null
}

# Helper: check if a pattern does NOT appear in the config file
config_missing() {
  ! grep -qiE "$1" "$FIXED_CONF" 2>/dev/null
}

# CHECK 3: rename-command NOT in fixed config
if config_missing "^[^#]*rename-command"; then
  check "rename-command removed from config" 0
else
  check "rename-command removed from config" 1
fi

# CHECK 4: Uses commandlog parameter names (not slowlog)
if config_has "^[^#]*commandlog-execution-slower-than"; then
  check "uses commandlog-execution-slower-than (not slowlog)" 0
else
  check "uses commandlog-execution-slower-than (not slowlog)" 1
fi

# CHECK 5: appendonly is yes (sessions need durability)
if config_has "^[^#]*appendonly +yes"; then
  check "appendonly enabled for session durability" 0
else
  check "appendonly enabled for session durability" 1
fi

# CHECK 6: maxmemory-policy is NOT noeviction (wrong for session store)
if config_has "^[^#]*maxmemory-policy" && config_missing "^[^#]*maxmemory-policy +noeviction"; then
  check "maxmemory-policy is not noeviction" 0
else
  check "maxmemory-policy is not noeviction" 1
fi

# CHECK 7: io-threads is set and > 1
IO_THREADS=$(grep -iE "^[^#]*io-threads +[0-9]+" "$FIXED_CONF" 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "0")
if [ "$IO_THREADS" -gt 1 ] 2>/dev/null; then
  check "io-threads enabled (value: $IO_THREADS)" 0
else
  check "io-threads enabled (value: $IO_THREADS)" 1
fi

# CHECK 8: Authentication configured (requirepass or ACL user definitions)
if config_has "^[^#]*(requirepass|user .+ on >" || config_has "^[^#]*aclfile"; then
  check "authentication configured (requirepass or ACL)" 0
else
  check "authentication configured (requirepass or ACL)" 1
fi

# CHECK 9: active-defrag-enabled yes (or activedefrag yes)
if config_has "^[^#]*(active-defrag-enabled|activedefrag) +yes"; then
  check "active defragmentation enabled" 0
else
  check "active defragmentation enabled" 1
fi

# CHECK 10: lazyfree-lazy-expire yes
if config_has "^[^#]*lazyfree-lazy-expire +yes"; then
  check "lazyfree-lazy-expire set to yes" 0
else
  check "lazyfree-lazy-expire set to yes" 1
fi

# CHECK 11: dual-channel-replication-enabled yes
if config_has "^[^#]*dual-channel-replication-enabled +yes"; then
  check "dual-channel-replication-enabled yes" 0
else
  check "dual-channel-replication-enabled yes" 1
fi

# CHECK 12: latency-monitor-threshold > 0
LAT_THRESHOLD=$(grep -iE "^[^#]*latency-monitor-threshold +[0-9]+" "$FIXED_CONF" 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "0")
if [ "$LAT_THRESHOLD" -gt 0 ] 2>/dev/null; then
  check "latency-monitor-threshold enabled (value: $LAT_THRESHOLD)" 0
else
  check "latency-monitor-threshold enabled (value: $LAT_THRESHOLD)" 1
fi

# CHECK 13: commandlog max-len is reasonable (> 8)
CMDLOG_LEN=$(grep -iE "^[^#]*commandlog-slow-execution-max-len +[0-9]+" "$FIXED_CONF" 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "0")
if [ "$CMDLOG_LEN" -gt 8 ] 2>/dev/null; then
  check "commandlog max-len increased (value: $CMDLOG_LEN)" 0
else
  check "commandlog max-len increased (value: $CMDLOG_LEN)" 1
fi

# =========================================
# ANSWERS.MD CHECKS
# =========================================
echo ""
echo "Checking answers.md..."

if [ ! -f "$ANSWERS" ]; then
  check "answers.md exists" 1
else
  check "answers.md exists" 0

  # CHECK 14: Has 5 question sections
  SECTION_COUNT=$(grep -ciE '^#+ *(Q(uestion)? *[0-9]+|Q[0-9]*:)' "$ANSWERS" 2>/dev/null || true)
  SECTION_COUNT=${SECTION_COUNT:-0}
  if [ "$SECTION_COUNT" -ge 5 ]; then
    check "answers.md has 5 question sections ($SECTION_COUNT found)" 0
  else
    check "answers.md has 5 question sections ($SECTION_COUNT found)" 1
  fi

  # CHECK 15: Mentions COMMANDLOG (not just SLOWLOG)
  if grep -qiE "COMMANDLOG" "$ANSWERS" 2>/dev/null; then
    check "answers.md mentions COMMANDLOG" 0
  else
    check "answers.md mentions COMMANDLOG" 1
  fi

  # CHECK 16: Mentions the 3 commandlog types
  if grep -qiE "large-request|large.request" "$ANSWERS" 2>/dev/null && \
     grep -qiE "large-reply|large.reply" "$ANSWERS" 2>/dev/null; then
    check "answers.md mentions commandlog types (large-request, large-reply)" 0
  else
    check "answers.md mentions commandlog types (large-request, large-reply)" 1
  fi

  # CHECK 17: Mentions ACL for command restriction
  if grep -qiE "ACL" "$ANSWERS" 2>/dev/null && grep -qiE "@dangerous" "$ANSWERS" 2>/dev/null; then
    check "answers.md covers ACL and @dangerous category" 0
  else
    check "answers.md covers ACL and @dangerous category" 1
  fi

  # CHECK 18: Mentions events-per-io-thread
  if grep -qiE "events-per-io-thread|events.per.io.thread" "$ANSWERS" 2>/dev/null; then
    check "answers.md mentions events-per-io-thread" 0
  else
    check "answers.md mentions events-per-io-thread" 1
  fi

  # CHECK 19: Sufficient length
  WORD_COUNT=$(wc -w < "$ANSWERS" 2>/dev/null || echo "0")
  WORD_COUNT=$(echo "$WORD_COUNT" | tr -d '[:space:]')
  if [ "$WORD_COUNT" -ge 500 ]; then
    check "answers.md has sufficient detail ($WORD_COUNT words)" 0
  else
    check "answers.md has sufficient detail ($WORD_COUNT words, need 500)" 1
  fi
fi

# =========================================
# AUDIT.MD CHECKS
# =========================================
echo ""
echo "Checking AUDIT.md..."

if [ ! -f "$AUDIT" ]; then
  check "AUDIT.md exists" 1
else
  check "AUDIT.md exists" 0

  # CHECK 20: AUDIT.md has 15+ lines
  LINE_COUNT=$(wc -l < "$AUDIT" 2>/dev/null || echo "0")
  LINE_COUNT=$(echo "$LINE_COUNT" | tr -d '[:space:]')
  if [ "$LINE_COUNT" -ge 15 ]; then
    check "AUDIT.md has 15+ lines ($LINE_COUNT lines)" 0
  else
    check "AUDIT.md has 15+ lines ($LINE_COUNT lines, need 15)" 1
  fi

  # CHECK 21: AUDIT.md mentions key issues
  if grep -qiE "rename-command|ACL" "$AUDIT" 2>/dev/null && \
     grep -qiE "commandlog|slowlog" "$AUDIT" 2>/dev/null; then
    check "AUDIT.md covers rename-command and commandlog changes" 0
  else
    check "AUDIT.md covers rename-command and commandlog changes" 1
  fi
fi

# =========================================
# STOP SERVER
# =========================================
valkey-cli -p $PORT SHUTDOWN NOSAVE 2>/dev/null || true
trap - EXIT
sleep 1

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
