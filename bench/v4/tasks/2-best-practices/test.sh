#!/usr/bin/env bash
set -uo pipefail

WORK_DIR="$(cd "${1:-.}" && pwd)"
ANSWERS="$WORK_DIR/answers.md"

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

if [ ! -f "$ANSWERS" ]; then
  echo "FAIL: answers.md not found at $ANSWERS"
  echo ""
  echo "========================================="
  echo "Results: 0 passed, 1 failed out of 1 checks"
  echo "========================================="
  exit 1
fi
check "answers.md exists" 0

CONTENT=$(cat "$ANSWERS" | tr '[:upper:]' '[:lower:]')

# Q1: COMMANDLOG with large-reply/large-request (not just SLOWLOG)
echo "$CONTENT" | grep -q 'commandlog'
check "Q1: mentions COMMANDLOG" "$?"
echo "$CONTENT" | grep -qE 'large.reply|large.request'
check "Q1: mentions large-reply or large-request types" "$?"

# Q2: SET IFEQ for conditional update
echo "$CONTENT" | grep -q 'ifeq'
check "Q2: mentions SET IFEQ" "$?"

# Q3: Hash field TTL (HSETEX/HEXPIRE/HTTL)
echo "$CONTENT" | grep -qE 'hsetex|hexpire|httl|hgetex|hash.field.*ttl|field.*expir'
check "Q3: mentions hash field TTL commands" "$?"

# Q4: DELIFEQ for lock release without Lua
echo "$CONTENT" | grep -q 'delifeq'
check "Q4: mentions DELIFEQ" "$?"

# Q5: Lazyfree defaults are yes in Valkey
echo "$CONTENT" | grep -qE 'lazyfree.*yes|default.*yes'
check "Q5: mentions lazyfree defaults are yes" "$?"

# Q6: HGETEX for atomic read + TTL refresh
echo "$CONTENT" | grep -q 'hgetex'
check "Q6: mentions HGETEX" "$?"

# Q7: Replication backlog + dual-channel or diskless
echo "$CONTENT" | grep -qE 'repl.backlog|backlog.size'
check "Q7: mentions repl-backlog-size" "$?"
echo "$CONTENT" | grep -qE 'dual.channel|diskless'
check "Q7: mentions dual-channel or diskless replication" "$?"

# Q8: io-threads-do-reads deprecated
echo "$CONTENT" | grep -qE 'io.threads.do.reads.*(deprecat|not.need|remov|always|unnecessary)|deprecat.*io.threads.do.reads'
check "Q8: mentions io-threads-do-reads deprecated" "$?"

# Q9: cluster-databases directive
echo "$CONTENT" | grep -qE 'cluster.database'
check "Q9: mentions cluster-databases" "$?"

# Q10: CLUSTERSCAN
echo "$CONTENT" | grep -q 'clusterscan'
check "Q10: mentions CLUSTERSCAN" "$?"

# Length
WORD_COUNT=$(wc -w < "$ANSWERS" 2>/dev/null | tr -d '[:space:]')
if [ "$WORD_COUNT" -ge 300 ]; then
  check "sufficient detail ($WORD_COUNT words)" 0
else
  check "sufficient detail ($WORD_COUNT words, need 300)" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="
