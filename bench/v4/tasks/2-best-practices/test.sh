#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 2: Valkey Best Practices Assessment
# Usage: test.sh <workspace_dir>
# Validates that answers.md exists, has 10 sections, and contains key terms.

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

# --- Check 0: answers.md exists ---
if [ ! -f "$ANSWERS" ]; then
  echo "FAIL: answers.md not found at $ANSWERS"
  echo ""
  echo "========================================="
  echo "Results: 0 passed, 1 failed out of 1 checks"
  echo "========================================="
  exit 1
fi
check "answers.md exists" 0

# --- Check 1: Has 10 question sections ---
SECTION_COUNT=$(grep -ciE '^#+ *Q(uestion)? *[0-9]+' "$ANSWERS" 2>/dev/null || true)
SECTION_COUNT=${SECTION_COUNT:-0}
if [ "$SECTION_COUNT" -ge 10 ]; then
  check "has 10 question sections" 0
else
  check "has 10 question sections ($SECTION_COUNT found)" 1
fi

# --- Check 2: Minimum length (at least 1000 words total, ~100 per answer) ---
WORD_COUNT=$(wc -w < "$ANSWERS" 2>/dev/null || echo "0")
WORD_COUNT=$(echo "$WORD_COUNT" | tr -d '[:space:]')
if [ "$WORD_COUNT" -ge 1000 ]; then
  check "minimum length ($WORD_COUNT words)" 0
else
  check "minimum length ($WORD_COUNT words, need 1000)" 1
fi

# --- Per-question key term checks ---

# Helper: check if a term appears in the answers file (case-insensitive)
has_term() {
  grep -qiE "$1" "$ANSWERS" 2>/dev/null
}

# Q1: COMMANDLOG
if has_term "COMMANDLOG" && has_term "large-request|large.request" && has_term "large-reply|large.reply"; then
  check "Q1: COMMANDLOG types" 0
else
  check "Q1: COMMANDLOG types" 1
fi

# Q2: Hash field TTL
if has_term "HSETEX" && has_term "FIELDS" && has_term "HGETEX"; then
  check "Q2: hash field TTL commands" 0
else
  check "Q2: hash field TTL commands" 1
fi

# Q3: IFEQ and DELIFEQ
if has_term "DELIFEQ" && has_term "IFEQ"; then
  check "Q3: conditional operations" 0
else
  check "Q3: conditional operations" 1
fi

# Q4: I/O threads
if has_term "io-threads-do-reads|io.threads.do.reads" && has_term "deprecated|removed|no longer"; then
  check "Q4: io-threads-do-reads deprecated" 0
else
  check "Q4: io-threads-do-reads deprecated" 1
fi

# Q5: Lazyfree defaults
if has_term "lazyfree-lazy-user-del|lazyfree.lazy.user.del" && has_term "yes"; then
  check "Q5: lazyfree defaults" 0
else
  check "Q5: lazyfree defaults" 1
fi

# Q6: rename-command vs ACL
if has_term "@dangerous|dangerous" && has_term "ACL" && has_term "per.user|per user"; then
  check "Q6: ACL alternative" 0
else
  check "Q6: ACL alternative" 1
fi

# Q7: Client-side caching
if has_term "__redis__:invalidate|invalidate" && has_term "tracking-table-max-keys|tracking.table.max.keys|tracking_table_max_keys"; then
  check "Q7: client-side caching" 0
else
  check "Q7: client-side caching" 1
fi

# Q8: Cluster enhancements
if has_term "cluster-databases|cluster.databases" && has_term "atomic.*slot|slot.*atomic"; then
  check "Q8: cluster enhancements" 0
else
  check "Q8: cluster enhancements" 1
fi

# Q9: AOF and hybrid persistence
if has_term "aof-use-rdb-preamble|aof.use.rdb.preamble" && has_term "2 second|two second|2s"; then
  check "Q9: AOF hybrid and data loss" 0
else
  check "Q9: AOF hybrid and data loss" 1
fi

# Q10: GEOSEARCH BYPOLYGON
if has_term "BYPOLYGON" && has_term "num.vertices|num_vertices|number of vertices"; then
  check "Q10: BYPOLYGON" 0
else
  check "Q10: BYPOLYGON" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
