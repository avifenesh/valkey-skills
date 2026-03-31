#!/bin/bash
# Validates Task 4 (Valkey usage review) answers
# Questions marked [VALKEY-SPECIFIC] require Valkey knowledge beyond Redis
# Input: $1 = directory containing ANSWERS.md

DIR="$1"
PASS=0
FAIL=0
TOTAL=12

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" -eq 1 ]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Task 4: Valkey Usage Review Validation ==="

ANSWER=""
if [ -f "$DIR/ANSWERS.md" ]; then
  ANSWER=$(cat "$DIR/ANSWERS.md")
elif [ -f "$DIR/answers.md" ]; then
  ANSWER=$(cat "$DIR/answers.md")
else
  ANSWER=$(find "$DIR" -maxdepth 1 -name "*.md" ! -name "questions.md" ! -name "README.md" ! -name "CLAUDE.md" -exec cat {} + 2>/dev/null)
fi

if [ -z "$ANSWER" ]; then
  echo "  [ERROR] No answers file found"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Q1 [VALKEY-SPECIFIC] Sessions: KEYS bad + TTL with EXPIRETIME/PERSIST for extension
q1_keys=$(echo "$ANSWER" | grep -ci "KEYS.*bad\|don.*use KEYS\|SCAN.*instead\|avoid.*KEYS" || true)
q1_ttl=$(echo "$ANSWER" | grep -ci "EXPIRETIME\|PERSIST\|TTL.*extend\|extend.*TTL" || true)
check "Q1 Sessions: KEYS problem + EXPIRETIME/PERSIST [VALKEY]" "$([ "$q1_keys" -gt 0 ] && [ "$q1_ttl" -gt 0 ] && echo 1 || echo 0)"

# Q2 Cache: DEL -> UNLINK
q2=$(echo "$ANSWER" | grep -ci "UNLINK\|unlink\|non.blocking\|async.*delet" || true)
check "Q2 Cache: DEL -> UNLINK" "$([ "$q2" -gt 0 ] && echo 1 || echo 0)"

# Q3 [VALKEY-SPECIFIC] Hash field TTL: use HEXPIRE/HPEXPIRE (Valkey 8+)
q3=$(echo "$ANSWER" | grep -ci "HEXPIRE\|HPEXPIRE\|HTTL\|hash.*field.*expir\|field.*level.*TTL\|per.field.*expir" || true)
check "Q3 Hash field TTL: HEXPIRE/HPEXPIRE [VALKEY]" "$([ "$q3" -gt 0 ] && echo 1 || echo 0)"

# Q4 Rate limiting: memory waste from unique members
q4=$(echo "$ANSWER" | grep -ci "memory.*member\|unique.*ID.*waste\|token.bucket\|fixed.window\|member.*redundant" || true)
check "Q4 Rate limit: identify memory waste" "$([ "$q4" -gt 0 ] && echo 1 || echo 0)"

# Q5 [VALKEY-SPECIFIC] Lock: GET-then-DEL race -> SET IFEQ (Valkey) or Lua
q5_ifeq=$(echo "$ANSWER" | grep -ci "IFEQ\|SET.*IFEQ\|IFEQ.*conditional" || true)
q5_lua=$(echo "$ANSWER" | grep -ci "lua\|EVAL\|atomic.*script" || true)
check "Q5 Lock: SET IFEQ or Lua for atomic release [VALKEY]" "$([ "$q5_ifeq" -gt 0 ] && echo 1 || echo 0)"
# Note: Lua also valid but IFEQ is the Valkey-specific answer

# Q6 Inventory: KEYS+GET -> Hash (HSET/HGETALL) or MGET
q6_hash=$(echo "$ANSWER" | grep -ci "HSET\|HGETALL\|HINCRBY\|hash\|Hash" || true)
q6_mget=$(echo "$ANSWER" | grep -ci "MGET\|SCAN" || true)
check "Q6 Inventory: Hash or MGET instead of KEYS+GET" "$([ "$q6_hash" -gt 0 ] || [ "$q6_mget" -gt 0 ] && echo 1 || echo 0)"

# Q7 Job queue: LIST -> Streams
q7=$(echo "$ANSWER" | grep -ci "stream\|XADD\|XREADGROUP\|XACK\|consumer.group\|Stream" || true)
check "Q7 Job queue: Streams over LIST" "$([ "$q7" -gt 0 ] && echo 1 || echo 0)"

# Q8 [VALKEY-SPECIFIC] Conditional updates: WATCH/MULTI -> SET IFEQ/IFGT
q8_ifeq=$(echo "$ANSWER" | grep -ci "IFEQ\|IFGT\|SET.*IFEQ\|SET.*IFGT\|conditional.*set" || true)
q8_lua=$(echo "$ANSWER" | grep -ci "lua\|EVAL\|CAS.*script" || true)
check "Q8 Conditional updates: SET IFEQ/IFGT [VALKEY]" "$([ "$q8_ifeq" -gt 0 ] && echo 1 || echo 0)"

# Q9 Search: app-side -> valkey-search module
q9=$(echo "$ANSWER" | grep -ci "FT\.CREATE\|FT\.SEARCH\|valkey.search\|RediSearch\|search.*module\|full.text.*index" || true)
check "Q9 Search: valkey-search module" "$([ "$q9" -gt 0 ] && echo 1 || echo 0)"

# Q10 Pub/Sub: missed messages -> Streams
q10=$(echo "$ANSWER" | grep -ci "stream\|XADD\|XREADGROUP\|persistent\|durable\|at.least.once" || true)
check "Q10 Pub/Sub: Streams for persistence" "$([ "$q10" -gt 0 ] && echo 1 || echo 0)"

# Q11 [VALKEY-SPECIFIC] Monitoring: SLOWLOG -> COMMANDLOG (Valkey 8.1+)
q11=$(echo "$ANSWER" | grep -ci "COMMANDLOG\|command.log\|COMMAND.*LOG" || true)
check "Q11 Monitoring: COMMANDLOG replaces SLOWLOG [VALKEY]" "$([ "$q11" -gt 0 ] && echo 1 || echo 0)"

# Q12 Leaderboard TTL: you CAN set TTL on sorted sets (EXPIRE works on any key type)
q12=$(echo "$ANSWER" | grep -ci "EXPIRE.*sorted\|EXPIRE.*zset\|EXPIRE.*leaderboard\|TTL.*work.*any\|TTL.*any.*key\|can.*set.*TTL\|EXPIRE.*key" || true)
check "Q12 Leaderboard: EXPIRE works on sorted sets" "$([ "$q12" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
