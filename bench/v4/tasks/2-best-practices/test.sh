#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 2: Valkey Technical Assessment (hard version)
# Usage: test.sh <workspace_dir>
#
# Each question requires EXACT Valkey-specific terms that a Redis-trained
# model would not produce. No fuzzy matching - terms must appear verbatim.

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

# Helper: check if a term appears in the answers file (case-insensitive)
has_term() {
  grep -qiE "$1" "$ANSWERS" 2>/dev/null
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

# --- Per-question key term checks ---
# Each question requires specific Valkey-only terms.
# A model using Redis knowledge would NOT produce these terms.

# Q1: Must say COMMANDLOG (not just SLOWLOG) and include the type argument "slow"
# Redis trap: would say SLOWLOG GET 10 without type argument
if has_term "COMMANDLOG" && has_term "COMMANDLOG GET.*slow|COMMANDLOG.*GET.*slow"; then
  check "Q1: COMMANDLOG GET with slow type" 0
else
  check "Q1: COMMANDLOG GET with slow type" 1
fi

# Q2: Must include the IFEQ flag (Valkey 8.1+, does not exist in Redis)
# Redis trap: would suggest Lua EVAL or WATCH/MULTI
if has_term "IFEQ"; then
  check "Q2: SET IFEQ flag" 0
else
  check "Q2: SET IFEQ flag" 1
fi

# Q3: Must include all three commandlog config directive names
# Redis trap: would only know slowlog-log-slower-than
if has_term "commandlog-execution-slower-than" && has_term "commandlog-request-larger-than" && has_term "commandlog-reply-larger-than"; then
  check "Q3: all three commandlog config directives" 0
else
  check "Q3: all three commandlog config directives" 1
fi

# Q4: Must include HSETEX (Valkey 9.0 command) and FXX or FIELDS
# Redis trap: no HSETEX in Redis, no per-field TTL, no FXX flag
if has_term "HSETEX" && (has_term "FXX" || has_term "FIELDS"); then
  check "Q4: HSETEX with FXX/FIELDS" 0
else
  check "Q4: HSETEX with FXX/FIELDS" 1
fi

# Q5: Must state lazyfree-lazy-expire defaults to YES in Valkey
# Also require lazyfree-lazy-user-del to confirm they listed all five
# Redis trap: would say these default to no
if has_term "lazyfree-lazy-expire" && has_term "lazyfree-lazy-user-del" && has_term "default.*yes|yes.*default|all.*yes|yes.*all"; then
  check "Q5: lazyfree defaults all yes" 0
else
  check "Q5: lazyfree defaults all yes" 1
fi

# Q6: Must include DELIFEQ (Valkey 9.0 command, does not exist in Redis)
# Redis trap: would provide Lua EVAL script as the only option
if has_term "DELIFEQ"; then
  check "Q6: DELIFEQ command" 0
else
  check "Q6: DELIFEQ command" 1
fi

# Q7: Must include RDB version 80 AND VALKEY magic string
# Redis trap: would say REDIS magic string, not know version 80
if has_term "\b80\b|version 80|RDB 80" && has_term "VALKEY.*magic|magic.*VALKEY|VALKEY.*header|header.*VALKEY|magic string.*VALKEY|VALKEY.*string"; then
  check "Q7: RDB version 80 and VALKEY magic" 0
else
  # Fallback: check for both terms present anywhere
  if has_term "RDB.*80|version.*80" && has_term '"VALKEY"|VALKEY magic|magic.*(is|string|header).*VALKEY'; then
    check "Q7: RDB version 80 and VALKEY magic" 0
  else
    check "Q7: RDB version 80 and VALKEY magic" 1
  fi
fi

# Q8: Must include cluster-databases directive name AND its default of 1
# Redis trap: would say cluster mode cannot use multiple databases, period
if has_term "cluster-databases" && has_term "default.*1|defaults.*1|default value.*1|cluster-databases.*1|1.*default"; then
  check "Q8: cluster-databases default 1" 0
else
  check "Q8: cluster-databases default 1" 1
fi

# Q9: Must include BOTH io-threads-do-reads AND dynamic-hz AND identify them as deprecated
# Redis trap: would recommend enabling io-threads-do-reads as best practice
if has_term "io-threads-do-reads" && has_term "dynamic-hz" && has_term "deprecat"; then
  check "Q9: both deprecated directives" 0
else
  check "Q9: both deprecated directives" 1
fi

# Q10: Must include HGETEX (Valkey 9.0 command, does not exist in Redis)
# Redis trap: would say this is not possible in a single command
if has_term "HGETEX" && has_term "FIELDS"; then
  check "Q10: HGETEX with FIELDS" 0
else
  check "Q10: HGETEX with FIELDS" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
