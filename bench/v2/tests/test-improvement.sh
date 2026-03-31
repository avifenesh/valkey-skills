#!/bin/bash
# Validates Task 4 (Valkey usage review) answers
# Each scenario has a specific correct improvement
# Input: $1 = directory containing ANSWERS.md

DIR="$1"
PASS=0
FAIL=0
TOTAL=10

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

# Q1 Session: KEYS is bad, use TTL with EXPIRETIME/PERSIST for retroactive extension
q1_keys=$(echo "$ANSWER" | grep -ci "KEYS.*bad\|don.*use KEYS\|SCAN.*instead\|KEYS.*anti.pattern\|avoid.*KEYS" || true)
q1_ttl=$(echo "$ANSWER" | grep -ci "TTL\|EXPIRE\|EXPIRETIME\|PERSIST\|EX\b" || true)
check "Q1 Sessions: identify KEYS problem + TTL with PERSIST/EXPIRETIME" "$([ "$q1_keys" -gt 0 ] && [ "$q1_ttl" -gt 0 ] && echo 1 || echo 0)"

# Q2 Cache invalidation: DEL -> UNLINK for non-blocking delete
q2=$(echo "$ANSWER" | grep -ci "UNLINK\|unlink\|non.blocking\|async.*delet" || true)
check "Q2 Cache: DEL -> UNLINK for non-blocking delete" "$([ "$q2" -gt 0 ] && echo 1 || echo 0)"

# Q3 Inventory: KEYS+GET -> use Hash (HSET/HGETALL) or MGET, not KEYS per page load
q3_hash=$(echo "$ANSWER" | grep -ci "HSET\|HGETALL\|HINCRBY\|hash\|Hash" || true)
q3_mget=$(echo "$ANSWER" | grep -ci "MGET\|SCAN" || true)
check "Q3 Inventory: Hash or MGET instead of KEYS+GET per page" "$([ "$q3_hash" -gt 0 ] || [ "$q3_mget" -gt 0 ] && echo 1 || echo 0)"

# Q4 Rate limiting: member should be timestamp-based or use simpler counter, trim window
# Good answer: remove unique request ID member (wastes memory), use timestamp+counter or token bucket
q4=$(echo "$ANSWER" | grep -ci "memory.*member\|unique.*ID.*waste\|token.bucket\|fixed.window\|member.*redundant\|ZRANGEBYSCORE\|trim\|memory" || true)
check "Q4 Rate limit: identify memory waste from unique members" "$([ "$q4" -gt 0 ] && echo 1 || echo 0)"

# Q5 Leaderboard: dual sorted set is fine, or use ZRANGEBYLEX / single set with composite scores
q5=$(echo "$ANSWER" | grep -ci "fine\|correct\|acceptable\|good approach\|reasonable\|works.*well\|dual.*set.*ok\|composite.*score\|ZUNIONSTORE\|ZINTERSTORE" || true)
check "Q5 Leaderboard: recognize dual sets is valid or suggest composite" "$([ "$q5" -gt 0 ] && echo 1 || echo 0)"

# Q6 Job queue: LIST -> Streams (XADD/XREADGROUP) for reliable ordering + exactly-once
q6=$(echo "$ANSWER" | grep -ci "stream\|XADD\|XREADGROUP\|XACK\|consumer.group\|Stream" || true)
check "Q6 Job queue: recommend Streams over LIST" "$([ "$q6" -gt 0 ] && echo 1 || echo 0)"

# Q7 Lock: GET-then-DEL race -> use Lua script or SET IFEQ (Valkey 8+) for atomic release
q7_lua=$(echo "$ANSWER" | grep -ci "lua\|EVAL\|atomic\|script\|compare.and.delete" || true)
q7_ifeq=$(echo "$ANSWER" | grep -ci "IFEQ\|SET.*IFEQ\|conditional" || true)
check "Q7 Lock: atomic release via Lua or SET IFEQ" "$([ "$q7_lua" -gt 0 ] || [ "$q7_ifeq" -gt 0 ] && echo 1 || echo 0)"

# Q8 Analytics: KEYS for collection -> SCAN, or better: use Hash per day (HINCRBY)
q8_scan=$(echo "$ANSWER" | grep -ci "SCAN\|HSCAN" || true)
q8_hash=$(echo "$ANSWER" | grep -ci "HINCRBY\|hash.*per.*day\|Hash\|HGETALL" || true)
check "Q8 Analytics: SCAN or Hash-per-day instead of KEYS" "$([ "$q8_scan" -gt 0 ] || [ "$q8_hash" -gt 0 ] && echo 1 || echo 0)"

# Q9 Search: app-side search -> use valkey-search module (FT.CREATE/FT.SEARCH)
q9=$(echo "$ANSWER" | grep -ci "FT\.CREATE\|FT\.SEARCH\|valkey.search\|RediSearch\|search.*module\|full.text.*index" || true)
check "Q9 Search: recommend valkey-search module" "$([ "$q9" -gt 0 ] && echo 1 || echo 0)"

# Q10 Pub/Sub: missed messages -> Streams for persistent messaging, or Pub/Sub + Stream hybrid
q10=$(echo "$ANSWER" | grep -ci "stream\|XADD\|XREADGROUP\|persistent\|Stream.*instead\|durable\|at.least.once" || true)
check "Q10 Pub/Sub: Streams for persistent messaging" "$([ "$q10" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
